module Search.QueryShape exposing
    ( Shape, Context, Clause(..)
    , BoolSpec, DisMaxSpec, ConstantScoreSpec, MultiMatchSpec, MatchSpec, TermSpec, RankFeatureSpec
    , Rescore, RescoreFn(..)
    , FieldRef(..), PathField(..), PathSub(..), EdgedField(..), EdgeSub(..), PlainField(..)
    , KeywordTarget(..), PathKwSub(..), DocValueField(..)
    , RankFeatureField(..), RankFeatureFn(..)
    , Term(..), Glue(..), Wrap(..), ClauseName(..)
    , MultiMatchKind(..), Analyzer(..), Fuzziness(..), Operator(..), MinimumShouldMatch(..)
    , Boost, boost, boostValue, Unit, unit, unitValue, Positive, positive, positiveValue
    , Nonempty(..)
    , encode, encodeRescore, negatedWordClauses
    , rankFeatureFieldName
    , decoder, toJson, validate
    )

{-| The shape of the ranking half of the Elasticsearch query, as a type.

`Search.Query` used to spell the query out as ~25 hand-picked numbers wired into
one hand-picked structure. This module turns that into data: a small AST that a
program can vary without producing nonsense, so the benchmark can search for a
better point rather than only scoring the one we guessed.

The type is what keeps the search honest. Validity is carried by the types, not
by runtime checks:

  - **Fields are enums drawn from the live mapping**, and a subfield is attached
    to the field that has it. Only `package_attr_name` and `option_name` carry
    `.attr_path` and `.attr_path_reverse`; the rest carry at most `.edge`; and
    `flake_name` carries none, so there is no way to write the `flake_name.*`
    pattern that resolves to nothing.
  - **The query text is a hole, not a string.** A clause names a `Term` - a
    derivation of what the user typed - rather than a literal, so no clause can
    be handed text the user did not type except through `Fixed`.
  - **Numeric domains are newtypes with clamping constructors**, so an
    out-of-range boost is not constructible.
  - **Compounds cannot be empty**: `DisMax.queries` is a `Nonempty`, and
    `validate` rejects a `Bool_` with nothing to match on or a `multi_match`
    over no fields.

What is _not_ here is the envelope: `from`, `size`, `sort`, the aggregations,
the type and bucket filters and the negated-word `must_not` all stay in
`Search.Query`. That matches the split that module already states - this half
decides ranking, the other half decides membership.


# The shape

@docs Shape, Context, Clause
@docs BoolSpec, DisMaxSpec, ConstantScoreSpec, MultiMatchSpec, MatchSpec, TermSpec, RankFeatureSpec
@docs Rescore, RescoreFn


# Fields

@docs FieldRef, PathField, PathSub, EdgedField, EdgeSub, PlainField
@docs KeywordTarget, PathKwSub, DocValueField
@docs RankFeatureField, RankFeatureFn


# Query text

@docs Term, Glue, Wrap, ClauseName


# Clause parameters

@docs MultiMatchKind, Analyzer, Fuzziness, Operator, MinimumShouldMatch


# Bounded numbers

@docs Boost, boost, boostValue, Unit, unit, unitValue, Positive, positive, positiveValue
@docs Nonempty


# Rendering

@docs encode, encodeRescore, negatedWordClauses
@docs rankFeatureFieldName


# Carrying a shape as data

@docs decoder, toJson, validate

-}

import Json.Decode
import Json.Decode.Pipeline
import Json.Encode
import List.Extra
import Set



-- THE SHAPE


{-| The scoring half of the body's top-level `bool`, plus an optional `rescore`.

The `bool` is shared: `filter` and `must_not` are the envelope's - type and
bucket filters, negated words - and `must` and `should` are the shape's. So the
root of a shape is that bool's scoring half rather than a free-standing clause.

`must` decides what is on the page and `should` decides how it is ordered, so
`must` is a `Nonempty`: a shape with nothing to match on returns the whole
index.

-}
type alias Shape =
    { must : Nonempty Clause
    , should : List Clause
    , minimumShouldMatch : Maybe MinimumShouldMatch
    , rescore : Maybe Rescore
    }


{-| What the user typed, split into the words to search for and the words to
exclude. Every `Term` is a derivation of `positiveWords`; `negativeWords` feeds
the envelope's `must_not` through `negatedWordClauses`.
-}
type alias Context =
    { positiveWords : List String
    , negativeWords : List String
    }


{-| One Elasticsearch query clause.

A clause may render to more than one JSON clause - that is what a per-word
`Term` means - so the compound clauses hold lists and the leaves expand into
them.

-}
type Clause
    = Bool_ BoolSpec
    | DisMax DisMaxSpec
    | ConstantScore ConstantScoreSpec
    | MultiMatch MultiMatchSpec
    | MatchQ MatchSpec
    | TermQ TermSpec
    | PrefixQ TermSpec
    | WildcardQ TermSpec
    | RankFeatureQ RankFeatureSpec


{-| A `bool` query. At least one of `must` and `should` has to be non-empty, or
the clause matches everything; `validate` is what says so.
-}
type alias BoolSpec =
    { must : List Clause
    , should : List Clause
    , mustNot : List Clause
    , minimumShouldMatch : Maybe MinimumShouldMatch
    , boost : Maybe Boost
    }


{-| A `dis_max` query: score by the best-matching branch, plus `tieBreaker`
times each of the others.
-}
type alias DisMaxSpec =
    { tieBreaker : Maybe Unit
    , queries : Nonempty Clause
    , boost : Maybe Boost
    }


{-| A `constant_score` query: matching at all is worth `boost`, and how well is
worth nothing.

`filter` is one clause. A per-word `Term` underneath it therefore renders as a
`bool` of `should`s, which is the same match set - it is only the scoring that
`constant_score` was going to discard anyway.

-}
type alias ConstantScoreSpec =
    { filter : Clause
    , boost : Boost
    }


{-| A `multi_match` query over a weighted field list.
-}
type alias MultiMatchSpec =
    { kind : MultiMatchKind
    , term : Term
    , analyzer : Maybe Analyzer
    , autoGenerateSynonymsPhraseQuery : Maybe Bool
    , fuzziness : Maybe Fuzziness
    , prefixLength : Maybe Int
    , operator : Maybe Operator
    , minimumShouldMatch : Maybe MinimumShouldMatch
    , name : ClauseName
    , fields : List ( FieldRef, Boost )
    , boost : Maybe Boost
    }


{-| A `match` query against a single field.
-}
type alias MatchSpec =
    { field : FieldRef
    , term : Term
    , analyzer : Maybe Analyzer
    , fuzziness : Maybe Fuzziness
    , prefixLength : Maybe Int
    , operator : Maybe Operator
    , minimumShouldMatch : Maybe MinimumShouldMatch
    , name : ClauseName
    , boost : Maybe Boost
    }


{-| A `term`, `prefix` or `wildcard` query. All three take the same parameters
and differ only in how Elasticsearch reads the value.
-}
type alias TermSpec =
    { target : KeywordTarget
    , term : Term
    , boost : Maybe Boost
    , caseInsensitive : Maybe Bool
    , name : ClauseName
    }


{-| A `rank_feature` query: a popularity signal, scored by a saturating
function of the stored feature value rather than by anything the user typed.
-}
type alias RankFeatureSpec =
    { field : RankFeatureField
    , boost : Maybe Boost
    , name : ClauseName
    , fn : RankFeatureFn
    }


{-| A second pass over the top `windowSize` hits of the first.
-}
type alias Rescore =
    { windowSize : Int
    , weight : Boost
    , fn : RescoreFn
    }


{-| What the rescore pass scores by.

`InverseFieldLength` is `1 / length`, which prefers the shorter of two
otherwise-equal names - `git` over `gitFull`, `services.nginx.enable` over
`services.nginx.virtualHosts.<name>.enableACME`.

-}
type RescoreFn
    = InverseFieldLength DocValueField



-- FIELDS


{-| A field to search, narrowed to one of its subfields where it has any.
-}
type FieldRef
    = Path PathField PathSub
    | Edged EdgedField EdgeSub
    | Plain PlainField


{-| The two attribute-path fields. Both are keywords carrying the full
`.attr_path` / `.attr_path_reverse` / `.edge` set.
-}
type PathField
    = PackageAttrName
    | OptionName


{-| Which analysis of an attribute-path field to search.

  - `PathBase` is the keyword itself: an exact, whole-value match.
  - `PathEdge` is the `edge_ngram` analysis, so a prefix of the value matches.
  - `AttrPath` tokenizes `a.b.c` into `a`, `a.b`, `a.b.c` - a path and every
    prefix of it.
  - `AttrPathReverse` does the same from the other end: `c`, `b.c`, `a.b.c`.
  - `PathAll` is the `.*` pattern, every subfield at once.

-}
type PathSub
    = PathBase
    | PathEdge
    | AttrPath
    | AttrPathReverse
    | PathAll


{-| The fields that carry an `.edge` subfield and nothing else.
-}
type EdgedField
    = PackagePname
    | PackagePrograms
    | PackageMainProgram
    | PackageAttrSet
    | PackageDescription
    | PackageLongDescription
    | OptionDescription
    | ServicePackage
    | ServicePackages


{-| Which analysis of an edge-ngram field to search: the field itself, its
`.edge` subfield, or the `.*` pattern covering both.
-}
type EdgeSub
    = EdgeBase
    | Edge
    | EdgeAll


{-| The fields the mapping gives no subfields, so there is no subfield to pick.
-}
type PlainField
    = FlakeName
    | FlakeDescription


{-| A field a `term`, `prefix` or `wildcard` clause can address: the keyword
fields, plus the path and edge subfields whose analyzers emit whole path
segments rather than words.

An analysed `text` field is deliberately absent. A `term` query does not analyze
its input, so against `package_description` it asks for a stemmed token and
finds one only by accident.

-}
type KeywordTarget
    = KwAttrName PathKwSub
    | KwOptionName PathKwSub
    | KwPname
    | KwPrograms
    | KwMainProgram
    | KwAttrSet
    | KwServicePackage
    | KwServicePackages


{-| Which analysis of an attribute-path field a term-family clause addresses.
The `.*` pattern is not among them: a term-family clause takes one field.
-}
type PathKwSub
    = KwBase
    | KwAttrPath
    | KwAttrPathReverse
    | KwEdge


{-| A field a rescore script can read through `doc[...]`, which needs doc
values, so keyword fields only.
-}
type DocValueField
    = DocPackageAttrName
    | DocOptionName
    | DocPackagePname
    | DocPackagePrograms
    | DocPackageMainProgram
    | DocPackageAttrSet
    | DocServicePackage
    | DocServicePackages


{-| The two `rank_feature` fields in the mapping.
-}
type RankFeatureField
    = PackageDepCount
    | PackageRepologyRepos


{-| How a `rank_feature` clause turns a stored feature value into a score.
-}
type RankFeatureFn
    = Saturation Positive
    | Log Positive
    | Sigmoid Positive Unit
    | Linear



-- QUERY TEXT


{-| A derivation of what the user typed.

Every one of these yields a _list_ of strings, because some of them - `PerWord`
above all - stand for several clauses. An empty list means the clause does not
appear at all, which is how a derivation that has nothing to say about this
query gets out of the way.

The dividing line is whether the derivation passes the user's text through or
builds something out of it. `Whole`, `Glued` and `PerWord` pass it through, so
they survive an empty search box - the same empty `multi_match` the frontend has
always sent. The rest construct: a phrase needs two words, a path needs
segments, `Fixed` is a literal that only makes sense next to a derived clause.
None of those may invent a clause out of an empty query, so they yield nothing
for one.

  - `Whole` is the words joined by spaces.
  - `MultiWordWhole` is `Whole`, but only where there is more than one word. A
    one-word phrase is just the word, so a phrase clause has nothing to add.
  - `Glued` joins the words with no separator, a `-` or a `_`. A keyword field
    only ever matches a whole value, and package names split words with `-` or
    `_` about as often as they concatenate, so a multi-word query reaches an
    attribute name only once the words are glued back together.
  - `Dotted` joins them with `.`, spelling a multi-word query as an attribute
    path, and `DottedPlus` appends a literal - `.enable` turns `postgresql` into
    the module entry point `services.postgresql.enable` reaches through
    `attr_path_reverse`.
  - `LastWord` and `AllButLast` split a query like `nginx virtual hosts` into
    the leaf and the path leading to it.
  - `Fixed` is a literal the shape carries rather than one the user typed. It
    exists to accompany a derived clause - `enable` alongside
    `DottedPlus ".enable"` - rather than to fire on its own.
  - `PerWord` is one clause per word: optionally per dash/underscore spelling of
    each word, and optionally wrapped in `*`.

-}
type Term
    = Whole
    | MultiWordWhole
    | Glued Glue
    | Dotted
    | DottedPlus String
    | LastWord
    | AllButLast
    | Fixed String
    | PerWord { variants : Bool, wrap : Wrap }


{-| What `Glued` joins the words with.
-}
type Glue
    = Concat
    | Dash
    | Underscore


{-| Whether a per-word clause searches for the word or for `*word*`.
-}
type Wrap
    = PlainWord
    | Surround


{-| The `_name` a clause is tagged with, which comes back in `matched_queries`.

Naming costs nothing at query time and is the only way to see which clause put a
hit where it is, so the shape carries names rather than dropping them.

-}
type ClauseName
    = Unnamed
    | Named String
    | NamedWithWords String



-- CLAUSE PARAMETERS


{-| How a `multi_match` combines its fields. `cross_fields` treats them as one
big field, `best_fields` scores by the single best one, `most_fields` sums them.
-}
type MultiMatchKind
    = BestFields
    | MostFields
    | CrossFields
    | Phrase
    | PhrasePrefix
    | BoolPrefix


{-| The search-time analyzer, overriding the field's own.

`whitespace` is the one the current query uses: it splits on spaces and does
nothing else, so a query keeps its punctuation and its case instead of being
stemmed into something an attribute name will not match.

-}
type Analyzer
    = Whitespace
    | Standard
    | Simple
    | KeywordAnalyzer
    | LowercaseAnalyzer


{-| How many edits away from the query a term may be. `Auto` scales with term
length; `Edits` fixes it.
-}
type Fuzziness
    = Auto
    | Edits Int


{-| Whether every word has to match or any one will do.
-}
type Operator
    = And
    | Or


{-| How many of the optional clauses have to match, as a count or a percentage.
-}
type MinimumShouldMatch
    = MsmCount Int
    | MsmPercent Int



-- BOUNDED NUMBERS


{-| A clause weight. Positive and bounded, so a mutation cannot produce a boost
that drowns out the rest of the query or one that rounds to nothing.
-}
type Boost
    = Boost Float


{-| Build a `Boost`, clamping into range.
-}
boost : Float -> Boost
boost value =
    Boost (clamp boostMin boostMax value)


boostMin : Float
boostMin =
    0.0001


boostMax : Float
boostMax =
    10000


{-| Read a `Boost` back out.
-}
boostValue : Boost -> Float
boostValue (Boost value) =
    value


{-| A number Elasticsearch reads as a fraction: `tie_breaker`, a sigmoid
exponent. Clamped to `0..1`.
-}
type Unit
    = Unit Float


{-| Build a `Unit`, clamping into range.
-}
unit : Float -> Unit
unit value =
    Unit (clamp 0 1 value)


{-| Read a `Unit` back out.
-}
unitValue : Unit -> Float
unitValue (Unit value) =
    value


{-| A strictly positive number: a `rank_feature` pivot or scaling factor, where
zero would divide by zero and a negative is meaningless.
-}
type Positive
    = Positive Float


{-| Build a `Positive`, clamping into range.
-}
positive : Float -> Positive
positive value =
    Positive (clamp 1.0e-6 1.0e9 value)


{-| Read a `Positive` back out.
-}
positiveValue : Positive -> Float
positiveValue (Positive value) =
    value


{-| A list that cannot be empty, which is what `DisMax.queries` and
`MultiMatch.fields` need: an empty `dis_max` is not a query and a `multi_match`
over no fields searches nothing.
-}
type Nonempty a
    = Nonempty a (List a)


{-| Build a `Nonempty` from a list, or fail because the list was empty.
-}
nonempty : List a -> Maybe (Nonempty a)
nonempty list =
    case list of
        first :: rest ->
            Just (Nonempty first rest)

        [] ->
            Nothing


{-| Flatten a `Nonempty` back to an ordinary list.
-}
nonemptyToList : Nonempty a -> List a
nonemptyToList (Nonempty first rest) =
    first :: rest



-- FIELD NAMES


{-| The Elasticsearch name of a field reference, subfield included.
-}
fieldName : FieldRef -> String
fieldName ref =
    case ref of
        Path field sub ->
            pathFieldName field
                ++ (case sub of
                        PathBase ->
                            ""

                        PathEdge ->
                            ".edge"

                        AttrPath ->
                            ".attr_path"

                        AttrPathReverse ->
                            ".attr_path_reverse"

                        PathAll ->
                            ".*"
                   )

        Edged field sub ->
            edgedFieldName field
                ++ (case sub of
                        EdgeBase ->
                            ""

                        Edge ->
                            ".edge"

                        EdgeAll ->
                            ".*"
                   )

        Plain field ->
            case field of
                FlakeName ->
                    "flake_name"

                FlakeDescription ->
                    "flake_description"


pathFieldName : PathField -> String
pathFieldName field =
    case field of
        PackageAttrName ->
            "package_attr_name"

        OptionName ->
            "option_name"


edgedFieldName : EdgedField -> String
edgedFieldName field =
    case field of
        PackagePname ->
            "package_pname"

        PackagePrograms ->
            "package_programs"

        PackageMainProgram ->
            "package_mainProgram"

        PackageAttrSet ->
            "package_attr_set"

        PackageDescription ->
            "package_description"

        PackageLongDescription ->
            "package_longDescription"

        OptionDescription ->
            "option_description"

        ServicePackage ->
            "service_package"

        ServicePackages ->
            "service_packages"


{-| The Elasticsearch name of a term-family target.
-}
keywordFieldName : KeywordTarget -> String
keywordFieldName target =
    case target of
        KwAttrName sub ->
            "package_attr_name" ++ pathKwSuffix sub

        KwOptionName sub ->
            "option_name" ++ pathKwSuffix sub

        KwPname ->
            "package_pname"

        KwPrograms ->
            "package_programs"

        KwMainProgram ->
            "package_mainProgram"

        KwAttrSet ->
            "package_attr_set"

        KwServicePackage ->
            "service_package"

        KwServicePackages ->
            "service_packages"


pathKwSuffix : PathKwSub -> String
pathKwSuffix sub =
    case sub of
        KwBase ->
            ""

        KwAttrPath ->
            ".attr_path"

        KwAttrPathReverse ->
            ".attr_path_reverse"

        KwEdge ->
            ".edge"


{-| The Elasticsearch name of a doc-values field.
-}
docValueFieldName : DocValueField -> String
docValueFieldName field =
    case field of
        DocPackageAttrName ->
            "package_attr_name"

        DocOptionName ->
            "option_name"

        DocPackagePname ->
            "package_pname"

        DocPackagePrograms ->
            "package_programs"

        DocPackageMainProgram ->
            "package_mainProgram"

        DocPackageAttrSet ->
            "package_attr_set"

        DocServicePackage ->
            "service_package"

        DocServicePackages ->
            "service_packages"


{-| The Elasticsearch name of a rank-feature field.
-}
rankFeatureFieldName : RankFeatureField -> String
rankFeatureFieldName field =
    case field of
        PackageDepCount ->
            "package_dep_count"

        PackageRepologyRepos ->
            "package_repology_repos"



-- TERM DERIVATION


{-| The strings a `Term` derives from the query. One per clause the term
produces, so an empty list drops the clause.
-}
terms : Context -> Term -> List String
terms context term =
    let
        words : List String
        words =
            context.positiveWords

        -- An empty search box splits into one empty word rather than no words,
        -- so "did the user type anything" is a question about the words'
        -- contents, not their count.
        whenTyped : List String -> List String
        whenTyped derived =
            if List.any (String.isEmpty >> not) words then
                derived

            else
                []
    in
    case term of
        Whole ->
            [ String.join " " words ]

        MultiWordWhole ->
            if List.length words > 1 then
                [ String.join " " words ]

            else
                []

        Glued glue ->
            [ glueWords glue words ]

        Dotted ->
            whenTyped [ String.join "." words ]

        DottedPlus suffix ->
            whenTyped [ String.join "." words ++ suffix ]

        LastWord ->
            whenTyped
                (List.Extra.last words
                    |> Maybe.map List.singleton
                    |> Maybe.withDefault []
                )

        AllButLast ->
            whenTyped
                (case List.Extra.init words of
                    Just leading ->
                        if List.isEmpty leading then
                            []

                        else
                            [ String.join " " leading ]

                    Nothing ->
                        []
                )

        Fixed value ->
            whenTyped [ value ]

        PerWord spec ->
            words
                |> (if spec.variants then
                        List.concatMap dashUnderscoreVariants

                    else
                        identity
                   )
                |> List.Extra.unique
                |> List.map
                    (case spec.wrap of
                        PlainWord ->
                            identity

                        Surround ->
                            \word -> "*" ++ word ++ "*"
                    )


glueWords : Glue -> List String -> String
glueWords glue words =
    case glue of
        Concat ->
            String.concat words

        Dash ->
            String.join "-" words

        Underscore ->
            String.join "_" words


{-| The dash and underscore spellings of a word, plus the word itself. No
analysed field splits `-` or `_` apart, so a name written one way is not found
by a query written the other way unless we ask for both.
-}
dashUnderscoreVariants : String -> List String
dashUnderscoreVariants word =
    [ String.replace "_" "-" word
    , String.replace "-" "_" word
    , word
    ]


clauseName : Context -> ClauseName -> List ( String, Json.Encode.Value )
clauseName context name =
    case name of
        Unnamed ->
            []

        Named value ->
            [ ( "_name", Json.Encode.string value ) ]

        NamedWithWords prefix ->
            [ ( "_name"
              , Json.Encode.string (prefix ++ String.join "_" context.positiveWords)
              )
            ]



-- ENCODING


{-| Render a shape into the `must` / `should` / `minimum_should_match` entries
of the body's top-level `bool`, in the order they belong there.
-}
encode : Context -> Shape -> List ( String, Json.Encode.Value )
encode context shape =
    [ ( "must", Json.Encode.list identity (encodeAll context (nonemptyToList shape.must)) )
    , ( "should", Json.Encode.list identity (encodeAll context shape.should) )
    ]
        ++ optional "minimum_should_match" encodeMinimumShouldMatch shape.minimumShouldMatch


{-| Render a shape's rescore pass, where it has one.
-}
encodeRescore : Shape -> Maybe ( String, Json.Encode.Value )
encodeRescore shape =
    shape.rescore
        |> Maybe.map
            (\rescore ->
                ( "rescore"
                , Json.Encode.object
                    [ ( "window_size", Json.Encode.int rescore.windowSize )
                    , ( "query"
                      , Json.Encode.object
                            [ ( "rescore_query"
                              , Json.Encode.object
                                    [ ( "function_score"
                                      , Json.Encode.object
                                            [ ( "script_score"
                                              , Json.Encode.object
                                                    [ ( "script"
                                                      , Json.Encode.object
                                                            [ ( "source"
                                                              , Json.Encode.string (rescoreSource rescore.fn)
                                                              )
                                                            ]
                                                      )
                                                    ]
                                              )
                                            ]
                                      )
                                    ]
                              )
                            , ( "rescore_query_weight", Json.Encode.float (boostValue rescore.weight) )
                            ]
                      )
                    ]
                )
            )


rescoreSource : RescoreFn -> String
rescoreSource fn =
    case fn of
        InverseFieldLength field ->
            "1.0 / doc['" ++ docValueFieldName field ++ "'].value.length()"


{-| The envelope's negated-word clauses: a `wildcard` per excluded word and
spelling, against each of the given fields.

This is not part of the shape - excluding what the user asked to exclude decides
membership, not ranking - but it spells words the same way a per-word `Term`
does, so it shares the derivation rather than repeating it.

-}
negatedWordClauses : Context -> List KeywordTarget -> Json.Encode.Value
negatedWordClauses context targets =
    context.negativeWords
        |> List.concatMap dashUnderscoreVariants
        |> List.Extra.unique
        |> List.concatMap
            (\word ->
                List.map
                    (\target ->
                        Json.Encode.object
                            [ ( "wildcard"
                              , Json.Encode.object
                                    [ ( keywordFieldName target
                                      , Json.Encode.object
                                            [ ( "value", Json.Encode.string ("*" ++ word ++ "*") )
                                            , ( "case_insensitive", Json.Encode.bool True )
                                            ]
                                      )
                                    ]
                              )
                            ]
                    )
                    targets
            )
        |> Json.Encode.list identity


{-| Render a list of clauses, dropping the ones this query gives nothing to say
and collapsing duplicates.

Duplicates are not hypothetical: the three `Glued` spellings of a one-word query
are the same string, and so are the dash and underscore variants of a word
containing neither. Two identical scoring clauses count that match twice, which
is never what a shape meant, so the same clause appearing twice is the same
clause.

-}
encodeAll : Context -> List Clause -> List Json.Encode.Value
encodeAll context clauses =
    clauses
        |> List.concatMap (encodeClause context)
        |> dedupe


dedupe : List Json.Encode.Value -> List Json.Encode.Value
dedupe values =
    values
        |> List.foldl
            (\value ( seen, kept ) ->
                let
                    key : String
                    key =
                        Json.Encode.encode 0 value
                in
                if Set.member key seen then
                    ( seen, kept )

                else
                    ( Set.insert key seen, value :: kept )
            )
            ( Set.empty, [] )
        |> Tuple.second
        |> List.reverse


encodeClause : Context -> Clause -> List Json.Encode.Value
encodeClause context clause =
    case clause of
        Bool_ spec ->
            let
                must : List Json.Encode.Value
                must =
                    encodeAll context spec.must

                should : List Json.Encode.Value
                should =
                    encodeAll context spec.should

                mustNot : List Json.Encode.Value
                mustNot =
                    encodeAll context spec.mustNot
            in
            if List.isEmpty must && List.isEmpty should && List.isEmpty mustNot then
                []

            else
                [ wrap "bool"
                    (nonEmptyList "must" must
                        ++ nonEmptyList "should" should
                        ++ nonEmptyList "must_not" mustNot
                        ++ optional "minimum_should_match" encodeMinimumShouldMatch spec.minimumShouldMatch
                        ++ optional "boost" encodeBoost spec.boost
                    )
                ]

        DisMax spec ->
            case encodeAll context (nonemptyToList spec.queries) of
                [] ->
                    []

                queries ->
                    [ wrap "dis_max"
                        (optional "tie_breaker" encodeUnit spec.tieBreaker
                            ++ [ ( "queries", Json.Encode.list identity queries ) ]
                            ++ optional "boost" encodeBoost spec.boost
                        )
                    ]

        ConstantScore spec ->
            case encodeClause context spec.filter of
                [] ->
                    []

                [ only ] ->
                    [ wrap "constant_score"
                        [ ( "filter", only )
                        , ( "boost", encodeBoost spec.boost )
                        ]
                    ]

                many ->
                    [ wrap "constant_score"
                        [ ( "filter"
                          , Json.Encode.object
                                [ ( "bool"
                                  , Json.Encode.object
                                        [ ( "should", Json.Encode.list identity many ) ]
                                  )
                                ]
                          )
                        , ( "boost", encodeBoost spec.boost )
                        ]
                    ]

        MultiMatch spec ->
            if List.isEmpty spec.fields then
                []

            else
                terms context spec.term
                    |> List.map
                        (\text ->
                            wrap "multi_match"
                                ([ ( "type", Json.Encode.string (multiMatchKindName spec.kind) )
                                 , ( "query", Json.Encode.string text )
                                 ]
                                    ++ optional "analyzer" encodeAnalyzer spec.analyzer
                                    ++ optional "auto_generate_synonyms_phrase_query" Json.Encode.bool spec.autoGenerateSynonymsPhraseQuery
                                    ++ optional "fuzziness" encodeFuzziness spec.fuzziness
                                    ++ optional "prefix_length" Json.Encode.int spec.prefixLength
                                    ++ optional "operator" encodeOperator spec.operator
                                    ++ optional "minimum_should_match" encodeMinimumShouldMatch spec.minimumShouldMatch
                                    ++ clauseName context spec.name
                                    ++ [ ( "fields"
                                         , spec.fields
                                            |> List.map weightedFieldName
                                            |> Json.Encode.list Json.Encode.string
                                         )
                                       ]
                                    ++ optional "boost" encodeBoost spec.boost
                                )
                        )

        MatchQ spec ->
            terms context spec.term
                |> List.map
                    (\text ->
                        wrap "match"
                            [ ( fieldName spec.field
                              , Json.Encode.object
                                    (( "query", Json.Encode.string text )
                                        :: optional "analyzer" encodeAnalyzer spec.analyzer
                                        ++ optional "fuzziness" encodeFuzziness spec.fuzziness
                                        ++ optional "prefix_length" Json.Encode.int spec.prefixLength
                                        ++ optional "operator" encodeOperator spec.operator
                                        ++ optional "minimum_should_match" encodeMinimumShouldMatch spec.minimumShouldMatch
                                        ++ optional "boost" encodeBoost spec.boost
                                        ++ clauseName context spec.name
                                    )
                              )
                            ]
                    )

        TermQ spec ->
            encodeTermFamily context "term" spec

        PrefixQ spec ->
            encodeTermFamily context "prefix" spec

        WildcardQ spec ->
            encodeTermFamily context "wildcard" spec

        RankFeatureQ spec ->
            [ wrap "rank_feature"
                (( "field", Json.Encode.string (rankFeatureFieldName spec.field) )
                    :: optional "boost" encodeBoost spec.boost
                    ++ clauseName context spec.name
                    ++ [ encodeRankFeatureFn spec.fn ]
                )
            ]


encodeTermFamily : Context -> String -> TermSpec -> List Json.Encode.Value
encodeTermFamily context kind spec =
    terms context spec.term
        |> List.map
            (\text ->
                wrap kind
                    [ ( keywordFieldName spec.target
                      , Json.Encode.object
                            (( "value", Json.Encode.string text )
                                :: optional "boost" encodeBoost spec.boost
                                ++ optional "case_insensitive" Json.Encode.bool spec.caseInsensitive
                                ++ clauseName context spec.name
                            )
                      )
                    ]
            )


weightedFieldName : ( FieldRef, Boost ) -> String
weightedFieldName ( ref, weight ) =
    fieldName ref ++ "^" ++ String.fromFloat (boostValue weight)


wrap : String -> List ( String, Json.Encode.Value ) -> Json.Encode.Value
wrap kind body =
    Json.Encode.object [ ( kind, Json.Encode.object body ) ]


optional : String -> (a -> Json.Encode.Value) -> Maybe a -> List ( String, Json.Encode.Value )
optional key encoder =
    Maybe.map (\value -> [ ( key, encoder value ) ]) >> Maybe.withDefault []


nonEmptyList : String -> List Json.Encode.Value -> List ( String, Json.Encode.Value )
nonEmptyList key values =
    if List.isEmpty values then
        []

    else
        [ ( key, Json.Encode.list identity values ) ]


encodeBoost : Boost -> Json.Encode.Value
encodeBoost =
    boostValue >> Json.Encode.float


encodeUnit : Unit -> Json.Encode.Value
encodeUnit =
    unitValue >> Json.Encode.float


encodeMinimumShouldMatch : MinimumShouldMatch -> Json.Encode.Value
encodeMinimumShouldMatch msm =
    case msm of
        MsmCount count ->
            Json.Encode.int count

        MsmPercent percent ->
            Json.Encode.string (String.fromInt percent ++ "%")


encodeAnalyzer : Analyzer -> Json.Encode.Value
encodeAnalyzer =
    analyzerName >> Json.Encode.string


encodeFuzziness : Fuzziness -> Json.Encode.Value
encodeFuzziness fuzziness =
    Json.Encode.string <|
        case fuzziness of
            Auto ->
                "AUTO"

            Edits edits ->
                String.fromInt edits


encodeOperator : Operator -> Json.Encode.Value
encodeOperator =
    operatorName >> Json.Encode.string


encodeRankFeatureFn : RankFeatureFn -> ( String, Json.Encode.Value )
encodeRankFeatureFn fn =
    case fn of
        Saturation pivot ->
            ( "saturation"
            , Json.Encode.object [ ( "pivot", Json.Encode.float (positiveValue pivot) ) ]
            )

        Log scalingFactor ->
            ( "log"
            , Json.Encode.object
                [ ( "scaling_factor", Json.Encode.float (positiveValue scalingFactor) ) ]
            )

        Sigmoid pivot exponent ->
            ( "sigmoid"
            , Json.Encode.object
                [ ( "pivot", Json.Encode.float (positiveValue pivot) )
                , ( "exponent", Json.Encode.float (unitValue exponent) )
                ]
            )

        Linear ->
            ( "linear", Json.Encode.object [] )


multiMatchKindName : MultiMatchKind -> String
multiMatchKindName kind =
    case kind of
        BestFields ->
            "best_fields"

        MostFields ->
            "most_fields"

        CrossFields ->
            "cross_fields"

        Phrase ->
            "phrase"

        PhrasePrefix ->
            "phrase_prefix"

        BoolPrefix ->
            "bool_prefix"


analyzerName : Analyzer -> String
analyzerName analyzer =
    case analyzer of
        Whitespace ->
            "whitespace"

        Standard ->
            "standard"

        Simple ->
            "simple"

        KeywordAnalyzer ->
            "keyword"

        LowercaseAnalyzer ->
            "lowercase"


operatorName : Operator -> String
operatorName operator =
    case operator of
        And ->
            "and"

        Or ->
            "or"



-- VALIDATION


{-| Reject the structures the types alone cannot: a `bool` with nothing to match
on, a negative window size, a percentage outside `0..100`.

The search that varies these shapes builds them in JavaScript and posts them
back through `decoder`, so this is where a bug in that grammar surfaces - as a
loud failure rather than as a query Elasticsearch quietly reads differently than
intended.

-}
validate : Shape -> Result String Shape
validate shape =
    let
        clauses : List Clause
        clauses =
            nonemptyToList shape.must ++ shape.should
    in
    List.foldl (\clause acc -> Result.andThen (\_ -> validateClause clause) acc)
        (Ok ())
        clauses
        |> Result.andThen (\_ -> validateMsm shape.minimumShouldMatch)
        |> Result.andThen (\_ -> validateRescore shape.rescore)
        |> Result.map (\_ -> shape)


validateClause : Clause -> Result String ()
validateClause clause =
    case clause of
        Bool_ spec ->
            if List.isEmpty spec.must && List.isEmpty spec.should && List.isEmpty spec.mustNot then
                Err "a `bool` clause needs at least one of `must`, `should` and `must_not`"

            else
                List.foldl (\child acc -> Result.andThen (\_ -> validateClause child) acc)
                    (validateMsm spec.minimumShouldMatch)
                    (spec.must ++ spec.should ++ spec.mustNot)

        DisMax spec ->
            List.foldl (\child acc -> Result.andThen (\_ -> validateClause child) acc)
                (Ok ())
                (nonemptyToList spec.queries)

        ConstantScore spec ->
            validateClause spec.filter

        MultiMatch spec ->
            if List.isEmpty spec.fields then
                Err "a `multi_match` clause needs at least one field to search"

            else
                validateMsm spec.minimumShouldMatch
                    |> Result.andThen (\_ -> validatePrefixLength spec.prefixLength)

        MatchQ spec ->
            validateMsm spec.minimumShouldMatch
                |> Result.andThen (\_ -> validatePrefixLength spec.prefixLength)

        TermQ _ ->
            Ok ()

        PrefixQ _ ->
            Ok ()

        WildcardQ _ ->
            Ok ()

        RankFeatureQ _ ->
            Ok ()


validateMsm : Maybe MinimumShouldMatch -> Result String ()
validateMsm msm =
    case msm of
        Just (MsmPercent percent) ->
            if percent < 0 || percent > 100 then
                Err ("`minimum_should_match` percentage out of range: " ++ String.fromInt percent)

            else
                Ok ()

        Just (MsmCount count) ->
            if count < 0 then
                Err ("negative `minimum_should_match`: " ++ String.fromInt count)

            else
                Ok ()

        Nothing ->
            Ok ()


validatePrefixLength : Maybe Int -> Result String ()
validatePrefixLength prefixLength =
    case prefixLength of
        Just length ->
            if length < 0 then
                Err ("negative `prefix_length`: " ++ String.fromInt length)

            else
                Ok ()

        Nothing ->
            Ok ()


validateRescore : Maybe Rescore -> Result String ()
validateRescore rescore =
    case rescore of
        Just { windowSize } ->
            if windowSize < 1 then
                Err ("`window_size` must be at least 1, got " ++ String.fromInt windowSize)

            else
                Ok ()

        Nothing ->
            Ok ()



-- CARRYING A SHAPE AS DATA


{-| Serialize a shape, so a search over shapes can hold one as a genome and hand
it back through `decoder`.

This is the shape itself, not the Elasticsearch query it renders to - `encode`
is what produces that, and it needs a `Context` this does not have.

-}
toJson : Shape -> Json.Encode.Value
toJson shape =
    Json.Encode.object
        ([ ( "must", Json.Encode.list clauseToJson (nonemptyToList shape.must) )
         , ( "should", Json.Encode.list clauseToJson shape.should )
         ]
            ++ optional "minimumShouldMatch" msmToJson shape.minimumShouldMatch
            ++ optional "rescore" rescoreToJson shape.rescore
        )


msmToJson : MinimumShouldMatch -> Json.Encode.Value
msmToJson msm =
    case msm of
        MsmCount count ->
            tagged "count" [ ( "value", Json.Encode.int count ) ]

        MsmPercent percent ->
            tagged "percent" [ ( "value", Json.Encode.int percent ) ]


rescoreToJson : Rescore -> Json.Encode.Value
rescoreToJson rescore =
    Json.Encode.object
        [ ( "windowSize", Json.Encode.int rescore.windowSize )
        , ( "weight", Json.Encode.float (boostValue rescore.weight) )
        , ( "fn"
          , case rescore.fn of
                InverseFieldLength field ->
                    tagged "inverseFieldLength"
                        [ ( "field", Json.Encode.string (docValueFieldName field) ) ]
          )
        ]


tagged : String -> List ( String, Json.Encode.Value ) -> Json.Encode.Value
tagged kind body =
    Json.Encode.object (( "kind", Json.Encode.string kind ) :: body)


clauseToJson : Clause -> Json.Encode.Value
clauseToJson clause =
    case clause of
        Bool_ spec ->
            tagged "bool"
                ([ ( "must", Json.Encode.list clauseToJson spec.must )
                 , ( "should", Json.Encode.list clauseToJson spec.should )
                 , ( "mustNot", Json.Encode.list clauseToJson spec.mustNot )
                 ]
                    ++ optional "minimumShouldMatch" msmToJson spec.minimumShouldMatch
                    ++ optional "boost" encodeBoost spec.boost
                )

        DisMax spec ->
            tagged "disMax"
                (( "queries", Json.Encode.list clauseToJson (nonemptyToList spec.queries) )
                    :: optional "tieBreaker" encodeUnit spec.tieBreaker
                    ++ optional "boost" encodeBoost spec.boost
                )

        ConstantScore spec ->
            tagged "constantScore"
                [ ( "filter", clauseToJson spec.filter )
                , ( "boost", encodeBoost spec.boost )
                ]

        MultiMatch spec ->
            tagged "multiMatch"
                -- `kind` is taken by the clause tag, so the `multi_match` kind
                -- travels under the name Elasticsearch gives it.
                ([ ( "type", Json.Encode.string (multiMatchKindName spec.kind) )
                 , ( "term", termToJson spec.term )
                 , ( "fields"
                   , spec.fields
                        |> Json.Encode.list
                            (\( ref, weight ) ->
                                Json.Encode.object
                                    [ ( "field", Json.Encode.string (fieldName ref) )
                                    , ( "boost", encodeBoost weight )
                                    ]
                            )
                   )
                 , ( "name", nameToJson spec.name )
                 ]
                    ++ optional "analyzer" encodeAnalyzer spec.analyzer
                    ++ optional "autoGenerateSynonymsPhraseQuery" Json.Encode.bool spec.autoGenerateSynonymsPhraseQuery
                    ++ optional "fuzziness" encodeFuzziness spec.fuzziness
                    ++ optional "prefixLength" Json.Encode.int spec.prefixLength
                    ++ optional "operator" encodeOperator spec.operator
                    ++ optional "minimumShouldMatch" msmToJson spec.minimumShouldMatch
                    ++ optional "boost" encodeBoost spec.boost
                )

        MatchQ spec ->
            tagged "match"
                ([ ( "field", Json.Encode.string (fieldName spec.field) )
                 , ( "term", termToJson spec.term )
                 , ( "name", nameToJson spec.name )
                 ]
                    ++ optional "analyzer" encodeAnalyzer spec.analyzer
                    ++ optional "fuzziness" encodeFuzziness spec.fuzziness
                    ++ optional "prefixLength" Json.Encode.int spec.prefixLength
                    ++ optional "operator" encodeOperator spec.operator
                    ++ optional "minimumShouldMatch" msmToJson spec.minimumShouldMatch
                    ++ optional "boost" encodeBoost spec.boost
                )

        TermQ spec ->
            termFamilyToJson "term" spec

        PrefixQ spec ->
            termFamilyToJson "prefix" spec

        WildcardQ spec ->
            termFamilyToJson "wildcard" spec

        RankFeatureQ spec ->
            tagged "rankFeature"
                ([ ( "field", Json.Encode.string (rankFeatureFieldName spec.field) )
                 , ( "name", nameToJson spec.name )
                 , ( "fn", rankFeatureFnToJson spec.fn )
                 ]
                    ++ optional "boost" encodeBoost spec.boost
                )


termFamilyToJson : String -> TermSpec -> Json.Encode.Value
termFamilyToJson kind spec =
    tagged kind
        ([ ( "target", Json.Encode.string (keywordFieldName spec.target) )
         , ( "term", termToJson spec.term )
         , ( "name", nameToJson spec.name )
         ]
            ++ optional "boost" encodeBoost spec.boost
            ++ optional "caseInsensitive" Json.Encode.bool spec.caseInsensitive
        )


rankFeatureFnToJson : RankFeatureFn -> Json.Encode.Value
rankFeatureFnToJson fn =
    case fn of
        Saturation pivot ->
            tagged "saturation" [ ( "pivot", Json.Encode.float (positiveValue pivot) ) ]

        Log scalingFactor ->
            tagged "log"
                [ ( "scalingFactor", Json.Encode.float (positiveValue scalingFactor) ) ]

        Sigmoid pivot exponent ->
            tagged "sigmoid"
                [ ( "pivot", Json.Encode.float (positiveValue pivot) )
                , ( "exponent", Json.Encode.float (unitValue exponent) )
                ]

        Linear ->
            tagged "linear" []


termToJson : Term -> Json.Encode.Value
termToJson term =
    case term of
        Whole ->
            tagged "whole" []

        MultiWordWhole ->
            tagged "multiWordWhole" []

        Glued glue ->
            tagged "glued"
                [ ( "glue"
                  , Json.Encode.string
                        (case glue of
                            Concat ->
                                "concat"

                            Dash ->
                                "dash"

                            Underscore ->
                                "underscore"
                        )
                  )
                ]

        Dotted ->
            tagged "dotted" []

        DottedPlus suffix ->
            tagged "dottedPlus" [ ( "suffix", Json.Encode.string suffix ) ]

        LastWord ->
            tagged "lastWord" []

        AllButLast ->
            tagged "allButLast" []

        Fixed value ->
            tagged "fixed" [ ( "value", Json.Encode.string value ) ]

        PerWord spec ->
            tagged "perWord"
                [ ( "variants", Json.Encode.bool spec.variants )
                , ( "wrap"
                  , Json.Encode.string
                        (case spec.wrap of
                            PlainWord ->
                                "plain"

                            Surround ->
                                "surround"
                        )
                  )
                ]


nameToJson : ClauseName -> Json.Encode.Value
nameToJson name =
    case name of
        Unnamed ->
            tagged "unnamed" []

        Named value ->
            tagged "named" [ ( "value", Json.Encode.string value ) ]

        NamedWithWords prefix ->
            tagged "namedWithWords" [ ( "prefix", Json.Encode.string prefix ) ]


{-| Read a shape back from the JSON `toJson` writes.

Field names arrive as the strings Elasticsearch uses, and are resolved back
against the same enums that produced them - so a field the mapping does not have
is a decode failure here rather than a clause that silently never matches.

-}
decoder : Json.Decode.Decoder Shape
decoder =
    Json.Decode.succeed Shape
        |> Json.Decode.Pipeline.required "must" (nonemptyDecoder clauseDecoder)
        |> Json.Decode.Pipeline.optional "should" (Json.Decode.list clauseDecoder) []
        |> Json.Decode.Pipeline.optional "minimumShouldMatch" (Json.Decode.maybe msmDecoder) Nothing
        |> Json.Decode.Pipeline.optional "rescore" (Json.Decode.maybe rescoreDecoder) Nothing
        |> Json.Decode.andThen
            (\shape ->
                case validate shape of
                    Ok valid ->
                        Json.Decode.succeed valid

                    Err message ->
                        Json.Decode.fail message
            )


nonemptyDecoder : Json.Decode.Decoder a -> Json.Decode.Decoder (Nonempty a)
nonemptyDecoder itemDecoder =
    Json.Decode.list itemDecoder
        |> Json.Decode.andThen
            (\list ->
                case nonempty list of
                    Just value ->
                        Json.Decode.succeed value

                    Nothing ->
                        Json.Decode.fail "expected at least one entry, got an empty list"
            )


{-| Look a string up in a table of the names the encoders produce.
-}
fromName : String -> List ( String, a ) -> Json.Decode.Decoder a
fromName name table =
    case List.Extra.find (\( candidate, _ ) -> candidate == name) table of
        Just ( _, value ) ->
            Json.Decode.succeed value

        Nothing ->
            Json.Decode.fail
                ("unknown \""
                    ++ name
                    ++ "\"; expected one of "
                    ++ String.join ", " (List.map Tuple.first table)
                )


byName : List ( String, a ) -> Json.Decode.Decoder a
byName table =
    Json.Decode.string |> Json.Decode.andThen (\name -> fromName name table)


kindDecoder : List ( String, Json.Decode.Decoder a ) -> Json.Decode.Decoder a
kindDecoder table =
    Json.Decode.field "kind" Json.Decode.string
        |> Json.Decode.andThen (\kind -> fromName kind table)
        |> Json.Decode.andThen identity


clauseDecoder : Json.Decode.Decoder Clause
clauseDecoder =
    Json.Decode.lazy
        (\_ ->
            kindDecoder
                [ ( "bool", Json.Decode.map Bool_ boolSpecDecoder )
                , ( "disMax", Json.Decode.map DisMax disMaxSpecDecoder )
                , ( "constantScore", Json.Decode.map ConstantScore constantScoreSpecDecoder )
                , ( "multiMatch", Json.Decode.map MultiMatch multiMatchSpecDecoder )
                , ( "match", Json.Decode.map MatchQ matchSpecDecoder )
                , ( "term", Json.Decode.map TermQ termSpecDecoder )
                , ( "prefix", Json.Decode.map PrefixQ termSpecDecoder )
                , ( "wildcard", Json.Decode.map WildcardQ termSpecDecoder )
                , ( "rankFeature", Json.Decode.map RankFeatureQ rankFeatureSpecDecoder )
                ]
        )


boolSpecDecoder : Json.Decode.Decoder BoolSpec
boolSpecDecoder =
    Json.Decode.succeed BoolSpec
        |> Json.Decode.Pipeline.optional "must" (Json.Decode.list clauseDecoder) []
        |> Json.Decode.Pipeline.optional "should" (Json.Decode.list clauseDecoder) []
        |> Json.Decode.Pipeline.optional "mustNot" (Json.Decode.list clauseDecoder) []
        |> Json.Decode.Pipeline.optional "minimumShouldMatch" (Json.Decode.maybe msmDecoder) Nothing
        |> Json.Decode.Pipeline.optional "boost" (Json.Decode.maybe boostDecoder) Nothing


disMaxSpecDecoder : Json.Decode.Decoder DisMaxSpec
disMaxSpecDecoder =
    Json.Decode.succeed DisMaxSpec
        |> Json.Decode.Pipeline.optional "tieBreaker" (Json.Decode.maybe unitDecoder) Nothing
        |> Json.Decode.Pipeline.required "queries" (nonemptyDecoder clauseDecoder)
        |> Json.Decode.Pipeline.optional "boost" (Json.Decode.maybe boostDecoder) Nothing


constantScoreSpecDecoder : Json.Decode.Decoder ConstantScoreSpec
constantScoreSpecDecoder =
    Json.Decode.succeed ConstantScoreSpec
        |> Json.Decode.Pipeline.required "filter" clauseDecoder
        |> Json.Decode.Pipeline.required "boost" boostDecoder


multiMatchSpecDecoder : Json.Decode.Decoder MultiMatchSpec
multiMatchSpecDecoder =
    Json.Decode.succeed MultiMatchSpec
        |> Json.Decode.Pipeline.required "type" (byName multiMatchKinds)
        |> Json.Decode.Pipeline.required "term" termDecoder
        |> Json.Decode.Pipeline.optional "analyzer" (Json.Decode.maybe analyzerDecoder) Nothing
        |> Json.Decode.Pipeline.optional "autoGenerateSynonymsPhraseQuery" (Json.Decode.maybe Json.Decode.bool) Nothing
        |> Json.Decode.Pipeline.optional "fuzziness" (Json.Decode.maybe fuzzinessDecoder) Nothing
        |> Json.Decode.Pipeline.optional "prefixLength" (Json.Decode.maybe Json.Decode.int) Nothing
        |> Json.Decode.Pipeline.optional "operator" (Json.Decode.maybe operatorDecoder) Nothing
        |> Json.Decode.Pipeline.optional "minimumShouldMatch" (Json.Decode.maybe msmDecoder) Nothing
        |> Json.Decode.Pipeline.optional "name" nameDecoder Unnamed
        |> Json.Decode.Pipeline.required "fields" (Json.Decode.list weightedFieldDecoder)
        |> Json.Decode.Pipeline.optional "boost" (Json.Decode.maybe boostDecoder) Nothing


matchSpecDecoder : Json.Decode.Decoder MatchSpec
matchSpecDecoder =
    Json.Decode.succeed MatchSpec
        |> Json.Decode.Pipeline.required "field" (byName fieldRefs)
        |> Json.Decode.Pipeline.required "term" termDecoder
        |> Json.Decode.Pipeline.optional "analyzer" (Json.Decode.maybe analyzerDecoder) Nothing
        |> Json.Decode.Pipeline.optional "fuzziness" (Json.Decode.maybe fuzzinessDecoder) Nothing
        |> Json.Decode.Pipeline.optional "prefixLength" (Json.Decode.maybe Json.Decode.int) Nothing
        |> Json.Decode.Pipeline.optional "operator" (Json.Decode.maybe operatorDecoder) Nothing
        |> Json.Decode.Pipeline.optional "minimumShouldMatch" (Json.Decode.maybe msmDecoder) Nothing
        |> Json.Decode.Pipeline.optional "name" nameDecoder Unnamed
        |> Json.Decode.Pipeline.optional "boost" (Json.Decode.maybe boostDecoder) Nothing


termSpecDecoder : Json.Decode.Decoder TermSpec
termSpecDecoder =
    Json.Decode.succeed TermSpec
        |> Json.Decode.Pipeline.required "target" (byName keywordTargets)
        |> Json.Decode.Pipeline.required "term" termDecoder
        |> Json.Decode.Pipeline.optional "boost" (Json.Decode.maybe boostDecoder) Nothing
        |> Json.Decode.Pipeline.optional "caseInsensitive" (Json.Decode.maybe Json.Decode.bool) Nothing
        |> Json.Decode.Pipeline.optional "name" nameDecoder Unnamed


rankFeatureSpecDecoder : Json.Decode.Decoder RankFeatureSpec
rankFeatureSpecDecoder =
    Json.Decode.succeed RankFeatureSpec
        |> Json.Decode.Pipeline.required "field" (byName rankFeatureFields)
        |> Json.Decode.Pipeline.optional "boost" (Json.Decode.maybe boostDecoder) Nothing
        |> Json.Decode.Pipeline.optional "name" nameDecoder Unnamed
        |> Json.Decode.Pipeline.required "fn" rankFeatureFnDecoder


rankFeatureFnDecoder : Json.Decode.Decoder RankFeatureFn
rankFeatureFnDecoder =
    kindDecoder
        [ ( "saturation"
          , Json.Decode.map Saturation (Json.Decode.field "pivot" positiveDecoder)
          )
        , ( "log"
          , Json.Decode.map Log (Json.Decode.field "scalingFactor" positiveDecoder)
          )
        , ( "sigmoid"
          , Json.Decode.map2 Sigmoid
                (Json.Decode.field "pivot" positiveDecoder)
                (Json.Decode.field "exponent" unitDecoder)
          )
        , ( "linear", Json.Decode.succeed Linear )
        ]


rescoreDecoder : Json.Decode.Decoder Rescore
rescoreDecoder =
    Json.Decode.succeed Rescore
        |> Json.Decode.Pipeline.required "windowSize" Json.Decode.int
        |> Json.Decode.Pipeline.required "weight" boostDecoder
        |> Json.Decode.Pipeline.required "fn"
            (kindDecoder
                [ ( "inverseFieldLength"
                  , Json.Decode.map InverseFieldLength
                        (Json.Decode.field "field" (byName docValueFields))
                  )
                ]
            )


weightedFieldDecoder : Json.Decode.Decoder ( FieldRef, Boost )
weightedFieldDecoder =
    Json.Decode.map2 Tuple.pair
        (Json.Decode.field "field" (byName fieldRefs))
        (Json.Decode.field "boost" boostDecoder)


termDecoder : Json.Decode.Decoder Term
termDecoder =
    kindDecoder
        [ ( "whole", Json.Decode.succeed Whole )
        , ( "multiWordWhole", Json.Decode.succeed MultiWordWhole )
        , ( "glued"
          , Json.Decode.map Glued
                (Json.Decode.field "glue"
                    (byName
                        [ ( "concat", Concat )
                        , ( "dash", Dash )
                        , ( "underscore", Underscore )
                        ]
                    )
                )
          )
        , ( "dotted", Json.Decode.succeed Dotted )
        , ( "dottedPlus"
          , Json.Decode.map DottedPlus (Json.Decode.field "suffix" Json.Decode.string)
          )
        , ( "lastWord", Json.Decode.succeed LastWord )
        , ( "allButLast", Json.Decode.succeed AllButLast )
        , ( "fixed", Json.Decode.map Fixed (Json.Decode.field "value" Json.Decode.string) )
        , ( "perWord"
          , Json.Decode.map2 (\variants wrapping -> PerWord { variants = variants, wrap = wrapping })
                (Json.Decode.field "variants" Json.Decode.bool)
                (Json.Decode.field "wrap"
                    (byName [ ( "plain", PlainWord ), ( "surround", Surround ) ])
                )
          )
        ]


nameDecoder : Json.Decode.Decoder ClauseName
nameDecoder =
    kindDecoder
        [ ( "unnamed", Json.Decode.succeed Unnamed )
        , ( "named", Json.Decode.map Named (Json.Decode.field "value" Json.Decode.string) )
        , ( "namedWithWords"
          , Json.Decode.map NamedWithWords (Json.Decode.field "prefix" Json.Decode.string)
          )
        ]


msmDecoder : Json.Decode.Decoder MinimumShouldMatch
msmDecoder =
    kindDecoder
        [ ( "count", Json.Decode.map MsmCount (Json.Decode.field "value" Json.Decode.int) )
        , ( "percent", Json.Decode.map MsmPercent (Json.Decode.field "value" Json.Decode.int) )
        ]


analyzerDecoder : Json.Decode.Decoder Analyzer
analyzerDecoder =
    byName
        [ ( "whitespace", Whitespace )
        , ( "standard", Standard )
        , ( "simple", Simple )
        , ( "keyword", KeywordAnalyzer )
        , ( "lowercase", LowercaseAnalyzer )
        ]


fuzzinessDecoder : Json.Decode.Decoder Fuzziness
fuzzinessDecoder =
    Json.Decode.string
        |> Json.Decode.andThen
            (\raw ->
                if raw == "AUTO" then
                    Json.Decode.succeed Auto

                else
                    case String.toInt raw of
                        Just edits ->
                            Json.Decode.succeed (Edits edits)

                        Nothing ->
                            Json.Decode.fail ("unknown fuzziness \"" ++ raw ++ "\"")
            )


operatorDecoder : Json.Decode.Decoder Operator
operatorDecoder =
    byName [ ( "and", And ), ( "or", Or ) ]


boostDecoder : Json.Decode.Decoder Boost
boostDecoder =
    Json.Decode.map boost Json.Decode.float


unitDecoder : Json.Decode.Decoder Unit
unitDecoder =
    Json.Decode.map unit Json.Decode.float


positiveDecoder : Json.Decode.Decoder Positive
positiveDecoder =
    Json.Decode.map positive Json.Decode.float



-- NAME TABLES
--
-- One table per enum, keyed by the name its encoder writes. Deriving the
-- decoders from these is what keeps a round trip honest: a constructor that
-- gains a name it cannot be read back from is a missing row here, not a silent
-- asymmetry between two `case` expressions.


multiMatchKinds : List ( String, MultiMatchKind )
multiMatchKinds =
    [ BestFields, MostFields, CrossFields, Phrase, PhrasePrefix, BoolPrefix ]
        |> List.map (\kind -> ( multiMatchKindName kind, kind ))


keywordTargets : List ( String, KeywordTarget )
keywordTargets =
    let
        subs : List PathKwSub
        subs =
            [ KwBase, KwAttrPath, KwAttrPathReverse, KwEdge ]
    in
    (List.map KwAttrName subs
        ++ List.map KwOptionName subs
        ++ [ KwPname, KwPrograms, KwMainProgram, KwAttrSet, KwServicePackage, KwServicePackages ]
    )
        |> List.map (\target -> ( keywordFieldName target, target ))


docValueFields : List ( String, DocValueField )
docValueFields =
    [ DocPackageAttrName
    , DocOptionName
    , DocPackagePname
    , DocPackagePrograms
    , DocPackageMainProgram
    , DocPackageAttrSet
    , DocServicePackage
    , DocServicePackages
    ]
        |> List.map (\field -> ( docValueFieldName field, field ))


rankFeatureFields : List ( String, RankFeatureField )
rankFeatureFields =
    [ PackageDepCount, PackageRepologyRepos ]
        |> List.map (\field -> ( rankFeatureFieldName field, field ))


fieldRefs : List ( String, FieldRef )
fieldRefs =
    let
        pathSubs : List PathSub
        pathSubs =
            [ PathBase, PathEdge, AttrPath, AttrPathReverse, PathAll ]

        edgeSubs : List EdgeSub
        edgeSubs =
            [ EdgeBase, Edge, EdgeAll ]

        edgedFields : List EdgedField
        edgedFields =
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
    in
    (List.concatMap (\field -> List.map (Path field) pathSubs) [ PackageAttrName, OptionName ]
        ++ List.concatMap (\field -> List.map (Edged field) edgeSubs) edgedFields
        ++ List.map Plain [ FlakeName, FlakeDescription ]
    )
        |> List.map (\ref -> ( fieldName ref, ref ))
