module Search.Query exposing (defaultOptionsShape, defaultPackagesShape, optionsBody, optionsBodyWith, packagesBody, packagesBodyWith, platforms)

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


{-| The package query the client sends, ranked by `defaultPackagesShape`.
-}
packagesBody :
    String
    -> Int
    -> Int
    -> Sort
    -> List ( String, List String )
    -> Json.Encode.Value
packagesBody =
    packagesBodyWith defaultPackagesShape


{-| The same query ranked by a shape the caller supplies.

`benchmark/evolve` scores candidate shapes through this, so that what it tunes
is rendered by the encoder that ships rather than by a reimplementation of it.

-}
packagesBodyWith :
    Shape
    -> String
    -> Int
    -> Int
    -> Sort
    -> List ( String, List String )
    -> Json.Encode.Value
packagesBodyWith shape query from size sort selectedBuckets =
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
        shape
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


{-| The option query the client sends, ranked by `defaultOptionsShape`.
-}
optionsBody :
    List String
    -> String
    -> Int
    -> Int
    -> Sort
    -> Json.Encode.Value
optionsBody =
    optionsBodyWith defaultOptionsShape


{-| The same query ranked by a shape the caller supplies.
-}
optionsBodyWith :
    Shape
    -> List String
    -> String
    -> Int
    -> Int
    -> Sort
    -> Json.Encode.Value
optionsBodyWith shape types query from size sort =
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
        shape
        [ KwOptionName KwBase ]



-- THE SHAPES
--
-- These are the two points the relevance benchmark scores, and the two starting
-- points `benchmark/evolve` searches out from. Changing a number here changes
-- the ranking, so it should come with a benchmark delta.


{-| How a package query is ranked.

Written by `benchmark/evolve`, not by hand, and transcribed from
`benchmark/evolve/champion-packages.json` by `to-elm.mjs`; `check-shape.mjs
--shape` asserts the two still agree. Read it as a found artefact rather than an
argued design - the reasons below are read off the result, not the intent behind
it.

A package can now match on its description alone. The `must` is a `dis_max` over
a `constant_score` phrase on the descriptions, a fuzzy `best_fields` on the last
word of the query, and each word as `*word*` against the attribute name; the
hand-written shape reached the descriptions only through `should`, so a query
that named no package matched nothing. That is where the gain is - `multiterm`
and `intent` move by +0.157 and +0.116 nDCG, and the other six categories move by
at most +0.058.

Two of the clauses look like they should be inert and are not. The second
`rank_feature` on `package_repology_repos` duplicates a field the clause below it
already reads, and the `bool` carries a `rank_feature` in its `must` next to a
lone scoring `should`; removing either costs 0.014 and 0.007 nDCG respectively.
They stand because they were measured, not because they read well.

-}
defaultPackagesShape : Shape
defaultPackagesShape =
    { must =
        Nonempty
            (DisMax
                { tieBreaker = Just (QueryShape.unit 0.387)
                , queries =
                    Nonempty
                        (ConstantScore
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
                                    , fields =
                                        [ ( Edged PackageDescription EdgeBase, QueryShape.boost 7.42 )
                                        , ( Edged PackageLongDescription EdgeBase, QueryShape.boost 1.0 )
                                        ]
                                    , boost = Nothing
                                    }
                            , boost = QueryShape.boost 110.0
                            }
                        )
                        [ MultiMatch
                            { kind = BestFields
                            , term = LastWord
                            , analyzer = Nothing
                            , autoGenerateSynonymsPhraseQuery = Nothing
                            , fuzziness = Just (Edits 1)
                            , prefixLength = Just 1
                            , operator = Nothing
                            , minimumShouldMatch = Just (MsmPercent 20)
                            , name = NamedWithWords "fuzzy_"
                            , fields =
                                [ ( Path PackageAttrName PathBase, QueryShape.boost 0.378 )
                                , ( Edged PackagePrograms EdgeBase, QueryShape.boost 0.441 )
                                , ( Edged PackageMainProgram EdgeBase, QueryShape.boost 0.413 )
                                , ( Edged PackagePname EdgeBase, QueryShape.boost 0.30000000000000004 )
                                ]
                            , boost = Nothing
                            }
                        , WildcardQ
                            { target = KwAttrName KwBase
                            , term = PerWord { variants = True, wrap = Surround }
                            , boost = Nothing
                            , caseInsensitive = Just True
                            , name = Unnamed
                            }
                        ]
                , boost = Nothing
                }
            )
            []
    , should =
        [ TermQ
            { target = KwAttrName KwBase
            , term = Glued Dash
            , boost = Just (QueryShape.boost 127.0)
            , caseInsensitive = Nothing
            , name = Unnamed
            }
        , PrefixQ
            { target = KwAttrName KwBase
            , term = Glued Concat
            , boost = Just (QueryShape.boost 16.4)
            , caseInsensitive = Just True
            , name = Unnamed
            }
        , MultiMatch
            { kind = CrossFields
            , term = AllButLast
            , analyzer = Just KeywordAnalyzer
            , autoGenerateSynonymsPhraseQuery = Nothing
            , fuzziness = Nothing
            , prefixLength = Nothing
            , operator = Nothing
            , minimumShouldMatch = Nothing
            , name = Unnamed
            , fields =
                [ ( Edged PackagePname Edge, QueryShape.boost 3.52 )
                , ( Edged PackageDescription EdgeBase, QueryShape.boost 1.17 )
                , ( Edged PackagePrograms EdgeBase, QueryShape.boost 117.0 )
                ]
            , boost = Nothing
            }
        , PrefixQ
            { target = KwPname
            , term = Glued Concat
            , boost = Just (QueryShape.boost 10.1)
            , caseInsensitive = Just True
            , name = Unnamed
            }
        , RankFeatureQ
            { field = PackageRepologyRepos
            , boost = Just (QueryShape.boost 328.0)
            , name = Unnamed
            , fn = Log (QueryShape.positive 5140.0)
            }
        , RankFeatureQ
            { field = PackageRepologyRepos
            , boost = Just (QueryShape.boost 5.0)
            , name = Named "popularity_package_repology_repos"
            , fn = Saturation (QueryShape.positive 13.5)
            }
        , Bool_
            { must =
                [ RankFeatureQ
                    { field = PackageDepCount
                    , boost = Nothing
                    , name = Unnamed
                    , fn = Sigmoid (QueryShape.positive 7580.0) (QueryShape.unit 0.434)
                    }
                ]
            , should =
                [ MultiMatch
                    { kind = BestFields
                    , term = PerWord { variants = False, wrap = PlainWord }
                    , analyzer = Just LowercaseAnalyzer
                    , autoGenerateSynonymsPhraseQuery = Nothing
                    , fuzziness = Nothing
                    , prefixLength = Nothing
                    , operator = Nothing
                    , minimumShouldMatch = Nothing
                    , name = Unnamed
                    , fields =
                        [ ( Edged PackageLongDescription Edge, QueryShape.boost 12.0 )
                        , ( Edged PackageAttrSet EdgeBase, QueryShape.boost 2.97 )
                        , ( Path PackageAttrName PathEdge, QueryShape.boost 0.307 )
                        ]
                    , boost = Just (QueryShape.boost 0.128)
                    }
                ]
            , mustNot = []
            , minimumShouldMatch = Nothing
            , boost = Just (QueryShape.boost 0.364)
            }
        , WildcardQ
            { target = KwPrograms
            , term = Dotted
            , boost = Just (QueryShape.boost 12.8)
            , caseInsensitive = Just True
            , name = Unnamed
            }
        ]
    , minimumShouldMatch = Nothing
    , rescore =
        Just
            { windowSize = 100
            , weight = QueryShape.boost 30.3
            , fn = InverseFieldLength DocPackageAttrName
            }
    }


{-| How an option query is ranked.

Written by `benchmark/evolve`, not by hand, and transcribed from
`benchmark/evolve/champion-options.json` by `to-elm.mjs`; `check-shape.mjs
--shape` asserts the two still agree. Read it as a found artefact rather than an
argued design - the reasons below are read off the result, not the intent behind
it.

An option matches on its name alone. The `must` is one `dis_max` over two
readings of the name - the dash-glued query as a prefix of `attr_path_reverse`,
and each word as `*word*` against the edge-ngrams - so a description no longer
gates whether a document matches at all, only where it ranks.

Three of the `should` clauses are wrapped in `constant_score`, which discards
the score of what it wraps and returns its own boost. Their inner numbers -
`QueryShape.boost 682.0` and the like - are therefore inert, and the weight each
clause carries is the small outer boost. The search had no gradient to tidy them
with, so they stand as found rather than being cleaned up into something that
would no longer be the shape that was measured.

The shortest-name rescore that the package shape uses turns out to pay here too,
which the hand-written shape did not do.

-}
defaultOptionsShape : Shape
defaultOptionsShape =
    { must =
        Nonempty
            (DisMax
                { tieBreaker = Just (QueryShape.unit 0.509)
                , queries =
                    Nonempty
                        (PrefixQ
                            { target = KwOptionName KwAttrPathReverse
                            , term = Glued Dash
                            , boost = Just (QueryShape.boost 26.4)
                            , caseInsensitive = Nothing
                            , name = Unnamed
                            }
                        )
                        [ WildcardQ
                            { target = KwOptionName KwEdge
                            , term = PerWord { variants = True, wrap = Surround }
                            , boost = Nothing
                            , caseInsensitive = Nothing
                            , name = Unnamed
                            }
                        ]
                , boost = Just (QueryShape.boost 8.33)
                }
            )
            []
    , should =
        [ WildcardQ
            { target = KwOptionName KwAttrPath
            , term = Dotted
            , boost = Just (QueryShape.boost 0.546)
            , caseInsensitive = Nothing
            , name = Unnamed
            }
        , PrefixQ
            { target = KwOptionName KwAttrPathReverse
            , term = AllButLast
            , boost = Just (QueryShape.boost 206.0)
            , caseInsensitive = Just True
            , name = Unnamed
            }
        , WildcardQ
            { target = KwOptionName KwAttrPathReverse
            , term = DottedPlus ".package"
            , boost = Just (QueryShape.boost 0.111)
            , caseInsensitive = Nothing
            , name = Unnamed
            }
        , ConstantScore
            { filter =
                MultiMatch
                    { kind = PhrasePrefix
                    , term = Fixed "enable"
                    , analyzer = Nothing
                    , autoGenerateSynonymsPhraseQuery = Nothing
                    , fuzziness = Nothing
                    , prefixLength = Nothing
                    , operator = Just Or
                    , minimumShouldMatch = Nothing
                    , name = Unnamed
                    , fields =
                        [ ( Edged ServicePackages Edge, QueryShape.boost 373.0 )
                        , ( Path OptionName PathEdge, QueryShape.boost 11.6 )
                        , ( Edged ServicePackages Edge, QueryShape.boost 0.839 )
                        , ( Path OptionName AttrPathReverse, QueryShape.boost 682.0 )
                        ]
                    , boost = Just (QueryShape.boost 5.45)
                    }
            , boost = QueryShape.boost 0.128
            }
        , ConstantScore
            { filter =
                MultiMatch
                    { kind = Phrase
                    , term = LastWord
                    , analyzer = Nothing
                    , autoGenerateSynonymsPhraseQuery = Nothing
                    , fuzziness = Nothing
                    , prefixLength = Nothing
                    , operator = Nothing
                    , minimumShouldMatch = Nothing
                    , name = Unnamed
                    , fields =
                        [ ( Edged ServicePackages Edge, QueryShape.boost 206.0 )
                        , ( Edged OptionDescription EdgeBase, QueryShape.boost 11.6 )
                        , ( Edged OptionDescription EdgeAll, QueryShape.boost 0.65 )
                        , ( Path OptionName PathBase, QueryShape.boost 630.0 )
                        ]
                    , boost = Just (QueryShape.boost 105.0)
                    }
            , boost = QueryShape.boost 0.0682
            }
        , ConstantScore
            { filter =
                MultiMatch
                    { kind = CrossFields
                    , term = LastWord
                    , analyzer = Nothing
                    , autoGenerateSynonymsPhraseQuery = Nothing
                    , fuzziness = Nothing
                    , prefixLength = Nothing
                    , operator = Nothing
                    , minimumShouldMatch = Nothing
                    , name = Unnamed
                    , fields =
                        [ ( Edged ServicePackages Edge, QueryShape.boost 384.0 )
                        , ( Path OptionName PathEdge, QueryShape.boost 11.6 )
                        , ( Edged OptionDescription EdgeAll, QueryShape.boost 0.542 )
                        , ( Path OptionName AttrPathReverse, QueryShape.boost 746.0 )
                        ]
                    , boost = Just (QueryShape.boost 39.3)
                    }
            , boost = QueryShape.boost 0.0975
            }
        ]
    , minimumShouldMatch = Nothing
    , rescore =
        Just
            { windowSize = 100
            , weight = QueryShape.boost 22.3
            , fn = InverseFieldLength DocOptionName
            }
    }



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
