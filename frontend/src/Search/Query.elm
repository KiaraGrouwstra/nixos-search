module Search.Query exposing (defaultOptionsShape, defaultPackagesShape, optionsBody, packagesBody, platforms)

{-| Single source of truth for the Elasticsearch query the client sends.

The query has two halves, and this module owns the boundary between them.

**Ranking** is `defaultPackagesShape` and `defaultOptionsShape`, expressed in
the `Search.QueryShape` AST. Every clause that decides the _order_ of the
results lives there, and every constant it is tuned by is a value in that data
rather than a literal buried in an encoder - which is what lets
`benchmark/evolve` search for a better shape and what lets the benchmark score a
candidate without a recompile.

**Filtering** is everything else in this module: `from`, `size`, `sort`, the
aggregations that back the sidebar, the `type` and bucket filters, and the
`must_not` that honours `-word`. Those decide membership, not order, so they are
not part of the shape and not something the search is allowed to touch.

Ranking relevant hyperparameters should always be added to the shapes, so that
they are searched rather than guessed.

-}

import Json.Encode
import Search exposing (Sort(..), Terms)
import Search.QueryShape as QueryShape
    exposing
        ( Analyzer(..)
        , Boost
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


platforms : List String
platforms =
    [ "x86_64-linux"
    , "aarch64-linux"
    , "i686-linux"
    , "x86_64-darwin"
    , "aarch64-darwin"
    ]


packagesBody :
    String
    -> Int
    -> Int
    -> Sort
    -> List ( String, List String )
    -> Json.Encode.Value
packagesBody query from size sort selectedBuckets =
    let
        terms : List Terms
        terms =
            [ { field = "package_attr_set", size = 20, include = Nothing }
            , { field = "package_license_set", size = 20, include = Nothing }
            , { field = "package_maintainers_set", size = 20, include = Nothing }
            , { field = "package_teams_set", size = 20, include = Nothing }
            , { field = "package_platforms", size = 20, include = Just platforms }
            ]

        selectionFor : String -> List String
        selectionFor field =
            selectedBuckets
                |> List.filter (\( f, _ ) -> f == field)
                |> List.head
                |> Maybe.map Tuple.second
                |> Maybe.withDefault []

        filterByBuckets : List ( String, Json.Encode.Value )
        filterByBuckets =
            [ ( "bool"
              , Json.Encode.object
                    [ ( "must"
                      , Json.Encode.list Json.Encode.object
                            (List.map
                                (\term ->
                                    [ ( "bool"
                                      , Json.Encode.object
                                            [ ( "should"
                                              , Json.Encode.list Json.Encode.object <|
                                                    List.map
                                                        (filterByBucket term.field)
                                                        (selectionFor term.field)
                                              )
                                            ]
                                      )
                                    ]
                                )
                                terms
                            )
                      )
                    ]
              )
            ]
    in
    encodeRequestBody
        (String.trim query)
        from
        size
        sort
        [ "package" ]
        "package_attr_name"
        [ "package_pversion" ]
        terms
        filterByBuckets
        defaultPackagesShape
        [ KwAttrName KwBase ]


filterByBucket : String -> String -> List ( String, Json.Encode.Value )
filterByBucket field value =
    [ ( "term"
      , Json.Encode.object
            [ ( field
              , Json.Encode.object
                    [ ( "value", Json.Encode.string value )
                    , ( "_name", Json.Encode.string <| "filter_bucket_" ++ field )
                    ]
              )
            ]
      )
    ]


optionsBody :
    List String
    -> String
    -> Int
    -> Int
    -> Sort
    -> Json.Encode.Value
optionsBody types query from size sort =
    encodeRequestBody
        (String.trim query)
        from
        size
        sort
        types
        "option_name"
        []
        []
        []
        defaultOptionsShape
        [ KwOptionName KwBase ]



-- THE SHAPES
--
-- These are the two points the relevance benchmark scores, and the two starting
-- points `benchmark/evolve` searches out from. Changing a number here changes
-- the ranking, so it should come with a benchmark delta.


{-| How a package query is ranked.

Reading it top to bottom: a hit has to match the words somehow (`must`), and
then a stack of `should` clauses says which of the matches deserve to be first -
an exact attribute name above a prefix of one, a description phrase above a
scattering of the same words, a widely packaged program above an obscure one.
The rescore pass then breaks the remaining ties toward shorter names.

-}
defaultPackagesShape : Shape
defaultPackagesShape =
    let
        searchedFields : List ( FieldRef, Boost )
        searchedFields =
            List.concat
                [ pathFieldWeights PackageAttrName 9.0
                , edgedFieldWeights PackagePrograms 9.0
                , edgedFieldWeights PackageMainProgram 9.0
                , edgedFieldWeights PackagePname 6.0
                , edgedFieldWeights PackageDescription 1.3
                , edgedFieldWeights PackageLongDescription 1.0
                , plainFieldWeights FlakeName 0.5
                ]

        fuzzyFields : List ( FieldRef, Boost )
        fuzzyFields =
            fuzzyFallbackWeights
                [ ( Path PackageAttrName PathBase, 9.0 )
                , ( Edged PackagePrograms EdgeBase, 9.0 )
                , ( Edged PackageMainProgram EdgeBase, 9.0 )
                , ( Edged PackagePname EdgeBase, 6.0 )
                ]
    in
    { must =
        Nonempty
            (anyOf (crossFieldsClause searchedFields)
                [ fuzzyClause fuzzyFields
                , substringClause (KwAttrName KwBase)
                ]
            )
            []
    , should =
        exactNameClauses (KwAttrName KwBase)
            ++ [ phraseClause
                    [ ( Edged PackageDescription EdgeBase, QueryShape.boost 3.0 )
                    , ( Edged PackageLongDescription EdgeBase, QueryShape.boost 1.0 )
                    ]
               , popularityClause PackageRepologyRepos 20.0
               , popularityClause PackageDepCount 1000.0
               ]
    , minimumShouldMatch = Nothing
    , rescore =
        Just
            { windowSize = 100
            , weight = QueryShape.boost 20.0
            , fn = InverseFieldLength DocPackageAttrName
            }
    }


{-| How an option query is ranked.

The same skeleton as the package shape, with two differences that follow from
what an option name is. There is no popularity signal and no shortest-name
rescore, because option names are a hierarchy rather than a namespace of
competing packages. In exchange there are the two entry-point clauses: a query
like `postgresql` almost always means `services.postgresql.enable`, which
`attr_path_reverse` reaches by matching the path from its leaf inwards.

-}
defaultOptionsShape : Shape
defaultOptionsShape =
    let
        searchedFields : List ( FieldRef, Boost )
        searchedFields =
            List.concat
                [ pathFieldWeights OptionName 6.0
                , edgedFieldWeights OptionDescription 1.0
                , plainFieldWeights FlakeName 0.5
                , edgedFieldWeights ServicePackage 3.0
                , edgedFieldWeights ServicePackages 3.0
                ]

        fuzzyFields : List ( FieldRef, Boost )
        fuzzyFields =
            fuzzyFallbackWeights
                [ ( Path OptionName PathBase, 6.0 )
                , ( Edged ServicePackage EdgeBase, 3.0 )
                , ( Edged ServicePackages EdgeBase, 3.0 )
                ]
    in
    { must =
        Nonempty
            (anyOf (crossFieldsClause searchedFields)
                [ fuzzyClause fuzzyFields
                , substringClause (KwOptionName KwBase)
                ]
            )
            []
    , should =
        exactNameClauses (KwOptionName KwBase)
            ++ [ phraseClause [ ( Edged OptionDescription EdgeBase, QueryShape.boost 3.0 ) ]
               , entryPointClause
               , enableLeafClause
               ]
    , minimumShouldMatch = Nothing
    , rescore = Nothing
    }



-- CLAUSES THE TWO SHAPES SHARE


{-| Score a hit by its best-matching branch, plus a share of each of the others.

The branches are alternative ways of reading the same query - as words across
the indexed fields, as words a typo away from them, as a substring of a name -
so summing them would reward a hit for being found three ways rather than for
being the right hit. `dis_max` takes the best reading instead, and
`tie_breaker` keeps the others from counting for nothing at all.

-}
anyOf : Clause -> List Clause -> Clause
anyOf first rest =
    DisMax
        { tieBreaker = Just (QueryShape.unit 0.7)
        , queries = Nonempty first rest
        , boost = Nothing
        }


{-| The main clause: every query word has to appear, but not necessarily in the
same field.

`cross_fields` is what makes `firefox esr` work when `firefox` is the name and
`esr` is in the description. The `whitespace` analyzer keeps the query's
punctuation and case, since an attribute name is not English and stemming it
does more harm than good.

-}
crossFieldsClause : List ( FieldRef, Boost ) -> Clause
crossFieldsClause fields =
    MultiMatch
        { kind = CrossFields
        , term = Whole
        , analyzer = Just Whitespace
        , autoGenerateSynonymsPhraseQuery = Just False
        , fuzziness = Nothing
        , prefixLength = Nothing
        , operator = Just And
        , minimumShouldMatch = Nothing
        , name = NamedWithWords "multi_match_"
        , fields = fields
        , boost = Nothing
        }


{-| The same query one edit away, so a typo still finds something.

It is weighted far below the exact clause - see `fuzzyFallbackWeights` - because
it should decide the ranking only when nothing matched properly. `prefix_length`
of 1 keeps the first character fixed, which is both much cheaper and a good
approximation of how people mistype.

-}
fuzzyClause : List ( FieldRef, Boost ) -> Clause
fuzzyClause fields =
    MultiMatch
        { kind = BestFields
        , term = Whole
        , analyzer = Nothing
        , autoGenerateSynonymsPhraseQuery = Nothing
        , fuzziness = Just (Edits 1)
        , prefixLength = Just 1
        , operator = Just And
        , minimumShouldMatch = Nothing
        , name = NamedWithWords "fuzzy_"
        , fields = fields
        , boost = Nothing
        }


{-| Each query word as a substring of the name, so `sql` finds `postgresql`.

No analysed field can do this - they match whole tokens - so it takes a
`wildcard` against the keyword itself.

-}
substringClause : KeywordTarget -> Clause
substringClause target =
    WildcardQ
        { target = target
        , term = PerWord { variants = True, wrap = Surround }
        , boost = Nothing
        , caseInsensitive = Just True
        , name = Unnamed
        }


{-| The name typed exactly, and the name typed as far as the user got.

Both are worth a lot: someone who types an attribute name wants that attribute,
not the thirty packages that mention it. The prefix clause is worth less than
the exact one so that `git` outranks `gitFull` without hiding it.

The three clauses of each are the three ways a multi-word query can spell one
name; `Search.QueryShape` collapses them back to one where they coincide, which
is every single-word query.

-}
exactNameClauses : KeywordTarget -> List Clause
exactNameClauses target =
    let
        spellings : List Term
        spellings =
            List.map Glued [ Concat, Dash, Underscore ]
    in
    List.map
        (\term ->
            TermQ
                { target = target
                , term = term
                , boost = Just (QueryShape.boost 100.0)
                , caseInsensitive = Nothing
                , name = Unnamed
                }
        )
        spellings
        ++ List.map
            (\term ->
                PrefixQ
                    { target = target
                    , term = term
                    , boost = Just (QueryShape.boost 20.0)
                    , caseInsensitive = Just True
                    , name = Unnamed
                    }
            )
            spellings


{-| The whole query as a phrase in the descriptions.

`constant_score` because what matters is that the words appear together in that
order at all; how often they do says nothing about which package the user meant.
Single-word queries skip it, since a one-word phrase is just the word and the
main clause has already scored it.

-}
phraseClause : List ( FieldRef, Boost ) -> Clause
phraseClause fields =
    ConstantScore
        { filter =
            MultiMatch
                { kind = Phrase
                , term = MultiWordWhole
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
        , boost = QueryShape.boost 80.0
        }


{-| A popularity signal, saturating at `pivot`.

Saturation is the point: the difference between 1 and 20 repositories packaging
something says a lot about which one is meant, and the difference between 500
and 1000 says nothing.

-}
popularityClause : RankFeatureField -> Float -> Clause
popularityClause field pivot =
    RankFeatureQ
        { field = field
        , boost = Just (QueryShape.boost 5.0)
        , name = Named ("popularity_" ++ QueryShape.rankFeatureFieldName field)
        , fn = Saturation (QueryShape.positive pivot)
        }


{-| The option a query most likely means: the one that switches the module on.

`attr_path_reverse` tokenizes `services.postgresql.enable` from the leaf
inwards, so the query `postgresql` spelled as `postgresql.enable` matches it
exactly.

-}
entryPointClause : Clause
entryPointClause =
    TermQ
        { target = KwOptionName KwAttrPathReverse
        , term = DottedPlus ".enable"
        , boost = Just (QueryShape.boost 100.0)
        , caseInsensitive = Nothing
        , name = Named "module_entry_point"
        }


{-| Any `enable` option, well below the one the query actually names.

This is the consolation prize for `entryPointClause`: when the exact path does
not exist, an `enable` option is still more likely to be what was wanted than
one of the module's settings.

-}
enableLeafClause : Clause
enableLeafClause =
    TermQ
        { target = KwOptionName KwAttrPathReverse
        , term = Fixed "enable"
        , boost = Just (QueryShape.boost 10.0)
        , caseInsensitive = Nothing
        , name = Named "module_enable_leaf"
        }



-- FIELD WEIGHTS


{-| What a field's subfields are worth relative to the field itself.

The `.*` pattern covers the `.edge` n-grams and the attribute-path analyses. A
match there is a weaker signal than a match on the field proper - an edge n-gram
of `postgresql` matches `post` - so it is scored below it.

-}
subfieldWeight : Float
subfieldWeight =
    0.6


{-| Scales the field weights of the fuzzy clause down to a fallback.
-}
fuzzyFallbackWeight : Float
fuzzyFallbackWeight =
    0.05


fuzzyFallbackWeights : List ( FieldRef, Float ) -> List ( FieldRef, Boost )
fuzzyFallbackWeights =
    List.map (Tuple.mapSecond (\score -> QueryShape.boost (score * fuzzyFallbackWeight)))


{-| An attribute-path field and the `.*` pattern covering its subfields.
-}
pathFieldWeights : PathField -> Float -> List ( FieldRef, Boost )
pathFieldWeights field score =
    [ ( Path field PathBase, QueryShape.boost score )
    , ( Path field PathAll, QueryShape.boost (score * subfieldWeight) )
    ]


{-| An edge-ngram field and the `.*` pattern covering its `.edge` subfield.
-}
edgedFieldWeights : EdgedField -> Float -> List ( FieldRef, Boost )
edgedFieldWeights field score =
    [ ( Edged field EdgeBase, QueryShape.boost score )
    , ( Edged field EdgeAll, QueryShape.boost (score * subfieldWeight) )
    ]


{-| A field with no subfields, so no `.*` pattern - it would resolve to nothing.
-}
plainFieldWeights : PlainField -> Float -> List ( FieldRef, Boost )
plainFieldWeights field score =
    [ ( Plain field, QueryShape.boost score ) ]



-- THE ENVELOPE


toAggregations :
    List Terms
    -> ( String, Json.Encode.Value )
toAggregations terms =
    let
        aggs =
            List.map
                (\term ->
                    ( term.field
                    , Json.Encode.object
                        [ ( "terms"
                          , Json.Encode.object
                                ([ ( "field"
                                   , Json.Encode.string term.field
                                   )
                                 , ( "size"
                                   , Json.Encode.int term.size
                                   )
                                 ]
                                    ++ (case term.include of
                                            Just include ->
                                                [ ( "include"
                                                  , Json.Encode.list Json.Encode.string include
                                                  )
                                                ]

                                            Nothing ->
                                                []
                                       )
                                )
                          )
                        ]
                    )
                )
                terms

        allAggs =
            [ ( "all"
              , Json.Encode.object
                    [ ( "global"
                      , Json.Encode.object []
                      )
                    , ( "aggregations"
                      , Json.Encode.object aggs
                      )
                    ]
              )
            ]
    in
    ( "aggs"
    , Json.Encode.object <| aggs ++ allAggs
    )


toSortQuery :
    Sort
    -> String
    -> List String
    -> ( String, Json.Encode.Value )
toSortQuery sort field fields =
    ( "sort"
    , case sort of
        AlphabeticallyAsc ->
            Json.Encode.list Json.Encode.object
                [ ( field, Json.Encode.string "asc" )
                    :: List.map
                        (\x -> ( x, Json.Encode.string "asc" ))
                        fields
                ]

        AlphabeticallyDesc ->
            Json.Encode.list Json.Encode.object
                [ ( field, Json.Encode.string "desc" )
                    :: List.map
                        (\x -> ( x, Json.Encode.string "desc" ))
                        fields
                ]

        Relevance ->
            Json.Encode.list Json.Encode.object
                [ ( "_score", Json.Encode.string "desc" )
                    :: ( field, Json.Encode.string "asc" )
                    :: List.map
                        (\x -> ( x, Json.Encode.string "asc" ))
                        fields
                ]
    )


filterByType :
    List String
    -> List ( String, Json.Encode.Value )
filterByType types =
    case types of
        [ type_ ] ->
            [ ( "term"
              , Json.Encode.object
                    [ ( "type"
                      , Json.Encode.object
                            [ ( "value", Json.Encode.string type_ )
                            , ( "_name", Json.Encode.string <| "filter_" ++ type_ ++ "s" )
                            ]
                      )
                    ]
              )
            ]

        _ ->
            [ ( "terms"
              , Json.Encode.object
                    [ ( "type", Json.Encode.list Json.Encode.string types )
                    , ( "_name", Json.Encode.string <| "filter_" ++ String.join "_" types )
                    ]
              )
            ]


encodeRequestBody :
    String
    -> Int
    -> Int
    -> Sort
    -> List String
    -> String
    -> List String
    -> List Terms
    -> List ( String, Json.Encode.Value )
    -> Shape
    -> List KeywordTarget
    -> Json.Encode.Value
encodeRequestBody query from sizeRaw sort types sortField otherSortFields terms filterByBuckets shape negatedTargets =
    let
        -- you can not request more then 10000 results otherwise it will return 404
        size =
            if from + sizeRaw > 10000 then
                10000 - from

            else
                sizeRaw

        ( negativeWords, positiveWords ) =
            String.toLower query
                |> String.words
                |> List.partition (String.startsWith "-")
                |> Tuple.mapFirst (List.map (String.dropLeft 1))

        context : Context
        context =
            { positiveWords = positiveWords, negativeWords = negativeWords }

        -- only emit `rescore` for the `Relevance` sort.
        rescoreActive : Bool
        rescoreActive =
            case ( sort, shape.rescore ) of
                ( Relevance, Just _ ) ->
                    True

                _ ->
                    False

        sortQuery : ( String, Json.Encode.Value )
        sortQuery =
            if rescoreActive then
                ( "sort"
                , Json.Encode.list Json.Encode.object
                    [ [ ( "_score", Json.Encode.string "desc" ) ] ]
                )

            else
                toSortQuery sort sortField otherSortFields
    in
    Json.Encode.object
        ([ ( "from"
           , Json.Encode.int from
           )
         , ( "size"
           , Json.Encode.int size
           )
         , sortQuery
         , toAggregations terms
         , ( "query"
           , Json.Encode.object
                [ ( "bool"
                  , Json.Encode.object
                        ([ ( "filter"
                           , Json.Encode.list Json.Encode.object
                                (List.append
                                    [ filterByType types ]
                                    (if List.isEmpty filterByBuckets then
                                        []

                                     else
                                        [ filterByBuckets ]
                                    )
                                )
                           )
                         , ( "must_not", QueryShape.negatedWordClauses context negatedTargets )
                         ]
                            ++ QueryShape.encode context shape
                        )
                  )
                ]
           )
         ]
            ++ (if rescoreActive then
                    QueryShape.encodeRescore shape
                        |> Maybe.map List.singleton
                        |> Maybe.withDefault []

                else
                    []
               )
        )
