module QueryShape exposing
    ( clampsOutOfRangeNumbers
    , collapsesDuplicateClauses
    , defaultShapesRoundtrip
    , derivesQueryText
    , rejectsNonsense
    , roundtripsArbitraryShapes
    )

{-| What has to hold for `Search.QueryShape` to be safe to search over.

`benchmark/evolve` builds shapes in JavaScript, posts them into Elm as JSON, and
trusts what comes back to be the query it scored. Three things make that trust
warranted, and each is a test here:

  - a shape survives the round trip through JSON unchanged, so what the search
    scored is what the search reported;
  - a number outside its domain is clamped rather than encoded, so a mutation
    cannot produce a boost Elasticsearch reads as an error;
  - a structurally invalid shape is rejected loudly, so a bug in the JavaScript
    grammar surfaces as a decode failure rather than as a query that quietly
    means something else.

-}

import Expect
import Fuzz exposing (Fuzzer)
import Json.Decode
import Json.Encode
import Search.Query
import Search.QueryShape as QueryShape
    exposing
        ( Analyzer(..)
        , Clause(..)
        , ClauseName(..)
        , Context
        , DocValueField(..)
        , EdgeSub(..)
        , EdgedField(..)
        , FieldRef(..)
        , Fuzziness(..)
        , Glue(..)
        , KeywordTarget(..)
        , MinimumShouldMatch(..)
        , MultiMatchKind(..)
        , Nonempty(..)
        , Operator(..)
        , PathField(..)
        , PathKwSub(..)
        , PathSub(..)
        , PlainField(..)
        , RankFeatureField(..)
        , RankFeatureFn(..)
        , RescoreFn(..)
        , Shape
        , Term(..)
        , Wrap(..)
        )
import Test exposing (Test)


{-| The two shapes that actually ship survive the round trip.

They are the ones every search starts from, so if anything is going to be lost
in transit it will be lost here first.

-}
defaultShapesRoundtrip : Test
defaultShapesRoundtrip =
    Test.describe "the shipped shapes survive JSON"
        (List.map
            (\( name, shape ) ->
                Test.test name (\_ -> expectRoundtrip shape)
            )
            [ ( "packages", Search.Query.defaultPackagesShape )
            , ( "options", Search.Query.defaultOptionsShape )
            ]
        )


{-| Any shape the fuzzer can build survives the round trip.

The default shapes exercise the constructors we happen to use today; the search
will reach the rest, which is what this covers.

-}
roundtripsArbitraryShapes : Test
roundtripsArbitraryShapes =
    Test.fuzz shapeFuzzer "an arbitrary shape survives JSON" expectRoundtrip


{-| A round trip is only meaningful in terms of the query it produces, since
that is the whole of what the shape is for. Comparing the re-encoded JSON also
sidesteps `Boost` and friends being opaque.
-}
expectRoundtrip : Shape -> Expect.Expectation
expectRoundtrip shape =
    case Json.Decode.decodeValue QueryShape.decoder (QueryShape.toJson shape) of
        Ok decoded ->
            Expect.all
                [ \_ ->
                    Json.Encode.encode 0 (QueryShape.toJson decoded)
                        |> Expect.equal (Json.Encode.encode 0 (QueryShape.toJson shape))
                , \_ ->
                    encodeWith sampleContext decoded
                        |> Expect.equal (encodeWith sampleContext shape)
                ]
                ()

        Err error ->
            Expect.fail (Json.Decode.errorToString error)


{-| Out-of-range numbers are pulled back into range instead of reaching
Elasticsearch.

A mutation operator that overshoots should cost the search one dull candidate,
not a failed request in the middle of an overnight run.

-}
clampsOutOfRangeNumbers : Test
clampsOutOfRangeNumbers =
    Test.describe "numeric domains are enforced by construction"
        [ Test.fuzz (Fuzz.floatRange -1000 20000) "a boost stays positive and bounded" <|
            \value ->
                QueryShape.boostValue (QueryShape.boost value)
                    |> Expect.all
                        [ Expect.greaterThan 0
                        , Expect.atMost 10000
                        ]
        , Test.fuzz (Fuzz.floatRange -10 10) "a unit stays within 0..1" <|
            \value ->
                QueryShape.unitValue (QueryShape.unit value)
                    |> Expect.all
                        [ Expect.atLeast 0
                        , Expect.atMost 1
                        ]
        , Test.fuzz (Fuzz.floatRange -1000 1000) "a pivot stays strictly positive" <|
            \value ->
                QueryShape.positiveValue (QueryShape.positive value)
                    |> Expect.greaterThan 0
        , Test.test "a value already in range is left alone" <|
            \_ ->
                QueryShape.boostValue (QueryShape.boost 5.4)
                    |> Expect.within (Expect.Absolute 0) 5.4
        ]


{-| The structures the types cannot rule out are rejected on the way in.
-}
rejectsNonsense : Test
rejectsNonsense =
    Test.describe "validate rejects what the types cannot"
        [ Test.test "a bool with nothing to match on" <|
            \_ ->
                expectInvalid
                    (shapeOf
                        (Bool_
                            { must = []
                            , should = []
                            , mustNot = []
                            , minimumShouldMatch = Nothing
                            , boost = Nothing
                            }
                        )
                    )
        , Test.test "a multi_match over no fields" <|
            \_ ->
                expectInvalid (shapeOf (multiMatch []))
        , Test.test "a minimum_should_match percentage above 100" <|
            \_ ->
                expectInvalid
                    { must = Nonempty (multiMatch sampleFields) []
                    , should = []
                    , minimumShouldMatch = Just (MsmPercent 140)
                    , rescore = Nothing
                    }
        , Test.test "a rescore window that returns nothing" <|
            \_ ->
                expectInvalid
                    { must = Nonempty (multiMatch sampleFields) []
                    , should = []
                    , minimumShouldMatch = Nothing
                    , rescore =
                        Just
                            { windowSize = 0
                            , weight = QueryShape.boost 20.0
                            , fn = InverseFieldLength DocPackageAttrName
                            }
                    }
        , Test.test "an empty must list is not even representable in JSON" <|
            \_ ->
                Json.Decode.decodeValue QueryShape.decoder
                    (Json.Encode.object [ ( "must", Json.Encode.list identity [] ) ])
                    |> Expect.err
        , Test.test "a field outside the mapping" <|
            \_ ->
                Json.Decode.decodeString QueryShape.decoder
                    """
                    { "must":
                        [ { "kind": "term"
                          , "target": "option_name_query"
                          , "term": { "kind": "whole" }
                          }
                        ]
                    }
                    """
                    |> Expect.err
        ]


expectInvalid : Shape -> Expect.Expectation
expectInvalid shape =
    case QueryShape.validate shape of
        Ok _ ->
            Expect.fail "expected the shape to be rejected"

        Err _ ->
            Expect.pass


{-| The query text a clause searches for is derived from what the user typed.

These are the derivations the shipped shapes rely on, spelled out: the glue that
turns two words back into one attribute name, the path that reaches a module's
entry point, and the wildcard spellings that find a name written with the other
separator.

-}
derivesQueryText : Test
derivesQueryText =
    let
        valuesOf : Context -> Term -> List String
        valuesOf context term =
            encodeClauses context
                [ TermQ
                    { target = KwAttrName KwBase
                    , term = term
                    , boost = Nothing
                    , caseInsensitive = Nothing
                    , name = Unnamed
                    }
                ]
                |> List.filterMap
                    (Json.Decode.decodeString
                        (Json.Decode.at [ "term", "package_attr_name", "value" ] Json.Decode.string)
                        >> Result.toMaybe
                    )

        typed : Context
        typed =
            { positiveWords = [ "nginx", "virtual-hosts" ], negativeWords = [] }

        blank : Context
        blank =
            { positiveWords = [ "" ], negativeWords = [] }
    in
    Test.describe "query text derivations"
        [ Test.test "glue joins the words three ways" <|
            \_ ->
                List.concatMap (valuesOf typed) (List.map Glued [ Concat, Dash, Underscore ])
                    |> Expect.equal
                        [ "nginxvirtual-hosts", "nginx-virtual-hosts", "nginx_virtual-hosts" ]
        , Test.test "a path reaches the module entry point" <|
            \_ ->
                valuesOf typed (DottedPlus ".enable")
                    |> Expect.equal [ "nginx.virtual-hosts.enable" ]
        , Test.test "per-word spells each word both ways, wrapped" <|
            \_ ->
                valuesOf typed (PerWord { variants = True, wrap = Surround })
                    |> Expect.equal
                        [ "*nginx*", "*virtual-hosts*", "*virtual_hosts*" ]
        , Test.test "a one-word query has no phrase to search for" <|
            \_ ->
                valuesOf { positiveWords = [ "nginx" ], negativeWords = [] } MultiWordWhole
                    |> Expect.equal []
        , Test.test "an empty search box derives nothing that was not typed" <|
            \_ ->
                List.concatMap (valuesOf blank)
                    [ Dotted, DottedPlus ".enable", Fixed "enable", LastWord, AllButLast ]
                    |> Expect.equal []
        , Test.test "an empty search box still passes the empty query through" <|
            \_ ->
                valuesOf blank Whole |> Expect.equal [ "" ]
        ]


{-| Two clauses that come out identical are one clause.

A single-word query glues to the same string all three ways, and a word with no
separator in it has one spelling rather than three. Emitting the duplicates
would count the same match twice, which no shape ever means.

-}
collapsesDuplicateClauses : Test
collapsesDuplicateClauses =
    Test.test "identical clauses are emitted once" <|
        \_ ->
            encodeClauses { positiveWords = [ "nginx" ], negativeWords = [] }
                (List.map
                    (\glue ->
                        TermQ
                            { target = KwAttrName KwBase
                            , term = Glued glue
                            , boost = Just (QueryShape.boost 100.0)
                            , caseInsensitive = Nothing
                            , name = Unnamed
                            }
                    )
                    [ Concat, Dash, Underscore ]
                )
                |> Expect.equal
                    [ """{"term":{"package_attr_name":{"value":"nginx","boost":100}}}""" ]



-- HELPERS


sampleContext : Context
sampleContext =
    { positiveWords = [ "postgres", "enable" ], negativeWords = [ "lib" ] }


sampleFields : List ( FieldRef, QueryShape.Boost )
sampleFields =
    [ ( Path PackageAttrName PathBase, QueryShape.boost 9.0 ) ]


multiMatch : List ( FieldRef, QueryShape.Boost ) -> Clause
multiMatch fields =
    MultiMatch
        { kind = CrossFields
        , term = Whole
        , analyzer = Nothing
        , autoGenerateSynonymsPhraseQuery = Nothing
        , fuzziness = Nothing
        , prefixLength = Nothing
        , operator = Nothing
        , minimumShouldMatch = Nothing
        , name = Unnamed
        , fields = fields
        , boost = Nothing
        }


shapeOf : Clause -> Shape
shapeOf clause =
    { must = Nonempty clause []
    , should = []
    , minimumShouldMatch = Nothing
    , rescore = Nothing
    }


encodeWith : Context -> Shape -> String
encodeWith context shape =
    Json.Encode.encode 0 (Json.Encode.object (QueryShape.encode context shape))


{-| The JSON clauses a `should` list renders to, one string each.
-}
encodeClauses : Context -> List Clause -> List String
encodeClauses context clauses =
    Json.Encode.encode 0
        (Json.Encode.object
            (QueryShape.encode context
                { must = Nonempty (multiMatch sampleFields) []
                , should = clauses
                , minimumShouldMatch = Nothing
                , rescore = Nothing
                }
            )
        )
        |> Json.Decode.decodeString
            (Json.Decode.field "should" (Json.Decode.list Json.Decode.value))
        |> Result.map (List.map (Json.Encode.encode 0))
        |> Result.withDefault []



-- FUZZERS


shapeFuzzer : Fuzzer Shape
shapeFuzzer =
    Fuzz.map4 Shape
        (nonemptyFuzzer (clauseFuzzer 2))
        (Fuzz.listOfLengthBetween 0 3 (clauseFuzzer 2))
        (Fuzz.maybe msmFuzzer)
        (Fuzz.maybe rescoreFuzzer)


{-| Compound clauses nest, so the fuzzer needs a depth budget: at zero it can
only produce leaves, which is what stops it recursing forever.
-}
clauseFuzzer : Int -> Fuzzer Clause
clauseFuzzer depth =
    if depth <= 0 then
        Fuzz.oneOf leafFuzzers

    else
        Fuzz.oneOf
            (leafFuzzers
                ++ [ Fuzz.map Bool_ (boolSpecFuzzer (depth - 1))
                   , Fuzz.map3
                        (\tieBreaker queries boost ->
                            DisMax { tieBreaker = tieBreaker, queries = queries, boost = boost }
                        )
                        (Fuzz.maybe (Fuzz.map QueryShape.unit (Fuzz.floatRange 0 1)))
                        (nonemptyFuzzer (clauseFuzzer (depth - 1)))
                        (Fuzz.maybe boostFuzzer)
                   , Fuzz.map2
                        (\filter boost -> ConstantScore { filter = filter, boost = boost })
                        (clauseFuzzer (depth - 1))
                        boostFuzzer
                   ]
            )


leafFuzzers : List (Fuzzer Clause)
leafFuzzers =
    [ Fuzz.map MultiMatch multiMatchSpecFuzzer
    , Fuzz.map MatchQ matchSpecFuzzer
    , Fuzz.map TermQ termSpecFuzzer
    , Fuzz.map PrefixQ termSpecFuzzer
    , Fuzz.map WildcardQ termSpecFuzzer
    , Fuzz.map RankFeatureQ rankFeatureSpecFuzzer
    ]


{-| A `bool` needs somewhere to put at least one clause, so the fuzzer picks the
list first and fills that one.
-}
boolSpecFuzzer : Int -> Fuzzer QueryShape.BoolSpec
boolSpecFuzzer depth =
    Fuzz.map3
        (\filled others msm ->
            let
                empty : QueryShape.BoolSpec
                empty =
                    { must = []
                    , should = []
                    , mustNot = []
                    , minimumShouldMatch = msm
                    , boost = Nothing
                    }
            in
            case filled of
                0 ->
                    { empty | must = others }

                1 ->
                    { empty | should = others }

                _ ->
                    { empty | mustNot = others }
        )
        (Fuzz.intRange 0 2)
        (Fuzz.listOfLengthBetween 1 2 (clauseFuzzer depth))
        (Fuzz.maybe msmFuzzer)


multiMatchSpecFuzzer : Fuzzer QueryShape.MultiMatchSpec
multiMatchSpecFuzzer =
    Fuzz.map QueryShape.MultiMatchSpec
        (Fuzz.oneOfValues [ BestFields, MostFields, CrossFields, Phrase, PhrasePrefix, BoolPrefix ])
        |> andMap termFuzzer
        |> andMap (Fuzz.maybe analyzerFuzzer)
        |> andMap (Fuzz.maybe Fuzz.bool)
        |> andMap (Fuzz.maybe fuzzinessFuzzer)
        |> andMap (Fuzz.maybe (Fuzz.intRange 0 3))
        |> andMap (Fuzz.maybe (Fuzz.oneOfValues [ And, Or ]))
        |> andMap (Fuzz.maybe msmFuzzer)
        |> andMap nameFuzzer
        |> andMap (Fuzz.listOfLengthBetween 1 4 weightedFieldFuzzer)
        |> andMap (Fuzz.maybe boostFuzzer)


matchSpecFuzzer : Fuzzer QueryShape.MatchSpec
matchSpecFuzzer =
    Fuzz.map QueryShape.MatchSpec fieldRefFuzzer
        |> andMap termFuzzer
        |> andMap (Fuzz.maybe analyzerFuzzer)
        |> andMap (Fuzz.maybe fuzzinessFuzzer)
        |> andMap (Fuzz.maybe (Fuzz.intRange 0 3))
        |> andMap (Fuzz.maybe (Fuzz.oneOfValues [ And, Or ]))
        |> andMap (Fuzz.maybe msmFuzzer)
        |> andMap nameFuzzer
        |> andMap (Fuzz.maybe boostFuzzer)


termSpecFuzzer : Fuzzer QueryShape.TermSpec
termSpecFuzzer =
    Fuzz.map QueryShape.TermSpec keywordTargetFuzzer
        |> andMap termFuzzer
        |> andMap (Fuzz.maybe boostFuzzer)
        |> andMap (Fuzz.maybe Fuzz.bool)
        |> andMap nameFuzzer


rankFeatureSpecFuzzer : Fuzzer QueryShape.RankFeatureSpec
rankFeatureSpecFuzzer =
    Fuzz.map4 QueryShape.RankFeatureSpec
        (Fuzz.oneOfValues [ PackageDepCount, PackageRepologyRepos ])
        (Fuzz.maybe boostFuzzer)
        nameFuzzer
        (Fuzz.oneOf
            [ Fuzz.map Saturation positiveFuzzer
            , Fuzz.map Log positiveFuzzer
            , Fuzz.map2 Sigmoid positiveFuzzer (Fuzz.map QueryShape.unit (Fuzz.floatRange 0 1))
            , Fuzz.constant Linear
            ]
        )


rescoreFuzzer : Fuzzer QueryShape.Rescore
rescoreFuzzer =
    Fuzz.map3 QueryShape.Rescore
        (Fuzz.intRange 1 500)
        boostFuzzer
        (Fuzz.map InverseFieldLength
            (Fuzz.oneOfValues
                [ DocPackageAttrName
                , DocOptionName
                , DocPackagePname
                , DocPackagePrograms
                , DocPackageMainProgram
                , DocPackageAttrSet
                , DocServicePackage
                , DocServicePackages
                ]
            )
        )


termFuzzer : Fuzzer Term
termFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant Whole
        , Fuzz.constant MultiWordWhole
        , Fuzz.map Glued (Fuzz.oneOfValues [ Concat, Dash, Underscore ])
        , Fuzz.constant Dotted
        , Fuzz.map DottedPlus (Fuzz.oneOfValues [ ".enable", ".package" ])
        , Fuzz.constant LastWord
        , Fuzz.constant AllButLast
        , Fuzz.map Fixed (Fuzz.oneOfValues [ "enable", "package" ])
        , Fuzz.map2 (\variants wrap -> PerWord { variants = variants, wrap = wrap })
            Fuzz.bool
            (Fuzz.oneOfValues [ PlainWord, Surround ])
        ]


fieldRefFuzzer : Fuzzer FieldRef
fieldRefFuzzer =
    Fuzz.oneOf
        [ Fuzz.map2 Path
            (Fuzz.oneOfValues [ PackageAttrName, OptionName ])
            (Fuzz.oneOfValues [ PathBase, PathEdge, AttrPath, AttrPathReverse, PathAll ])
        , Fuzz.map2 Edged
            (Fuzz.oneOfValues
                [ PackagePname
                , PackagePrograms
                , PackageMainProgram
                , PackageAttrSet
                , PackageDescription
                , PackageLongDescription
                , OptionDescription
                , ServicePackage
                , ServicePackages
                ]
            )
            (Fuzz.oneOfValues [ EdgeBase, Edge, EdgeAll ])
        , Fuzz.map Plain (Fuzz.oneOfValues [ FlakeName, FlakeDescription ])
        ]


keywordTargetFuzzer : Fuzzer KeywordTarget
keywordTargetFuzzer =
    let
        subs : Fuzzer PathKwSub
        subs =
            Fuzz.oneOfValues [ KwBase, KwAttrPath, KwAttrPathReverse, KwEdge ]
    in
    Fuzz.oneOf
        [ Fuzz.map KwAttrName subs
        , Fuzz.map KwOptionName subs
        , Fuzz.oneOfValues
            [ KwPname, KwPrograms, KwMainProgram, KwAttrSet, KwServicePackage, KwServicePackages ]
        ]


weightedFieldFuzzer : Fuzzer ( FieldRef, QueryShape.Boost )
weightedFieldFuzzer =
    Fuzz.pair fieldRefFuzzer boostFuzzer


nameFuzzer : Fuzzer ClauseName
nameFuzzer =
    Fuzz.oneOf
        [ Fuzz.constant Unnamed
        , Fuzz.map Named (Fuzz.oneOfValues [ "entry_point", "popularity" ])
        , Fuzz.map NamedWithWords (Fuzz.oneOfValues [ "fuzzy_", "multi_match_" ])
        ]


analyzerFuzzer : Fuzzer Analyzer
analyzerFuzzer =
    Fuzz.oneOfValues [ Whitespace, Standard, Simple, KeywordAnalyzer, LowercaseAnalyzer ]


fuzzinessFuzzer : Fuzzer Fuzziness
fuzzinessFuzzer =
    Fuzz.oneOf [ Fuzz.constant Auto, Fuzz.map Edits (Fuzz.intRange 0 2) ]


msmFuzzer : Fuzzer MinimumShouldMatch
msmFuzzer =
    Fuzz.oneOf
        [ Fuzz.map MsmCount (Fuzz.intRange 0 4)
        , Fuzz.map MsmPercent (Fuzz.intRange 0 100)
        ]


boostFuzzer : Fuzzer QueryShape.Boost
boostFuzzer =
    Fuzz.map QueryShape.boost (Fuzz.floatRange 0.01 100)


positiveFuzzer : Fuzzer QueryShape.Positive
positiveFuzzer =
    Fuzz.map QueryShape.positive (Fuzz.floatRange 0.01 2000)


nonemptyFuzzer : Fuzzer a -> Fuzzer (QueryShape.Nonempty a)
nonemptyFuzzer itemFuzzer =
    Fuzz.map2 Nonempty itemFuzzer (Fuzz.listOfLengthBetween 0 2 itemFuzzer)


{-| `Fuzz.map` only reaches eight arguments, and the clause records go further.
-}
andMap : Fuzzer a -> Fuzzer (a -> b) -> Fuzzer b
andMap =
    Fuzz.map2 (|>)
