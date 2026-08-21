port module Benchmark exposing (main)

{-| Headless worker: renders Elasticsearch request bodies the way the app does.

`benchmark/run.mjs` scores the frontend's real query rather than a
reimplementation of it, and `benchmark/evolve` tunes the shape that this module
hands to `Search.Query`. Both talk to the same worker, so what is measured and
what is tuned is what ships.

A request carries a whole batch of queries, because the alternative - a round
trip per query - costs more in message passing than in the encoding it asks for,
and a shape search issues one batch per candidate. It may also override either
track's ranking shape; omitting an override (`null`) means the default the app
ships with.

-}

import Json.Decode
import Json.Decode.Pipeline
import Json.Encode
import Platform
import Search
import Search.Query
import Search.QueryShape as QueryShape exposing (Shape)


{-| A batch, as JSON rather than as a typed record.

The shape overrides are arbitrary JSON that only `QueryShape.decoder` can judge,
and a port that took them as `Json.Decode.Value` would still leave the decoding
here - so the whole request is decoded in one place, and a malformed one comes
back as a message instead of as a crash.

-}
port sendBatch : (Json.Decode.Value -> msg) -> Sub msg


{-| The bodies, in the order their queries were sent, and the shapes that ranked
them.

`shapes` echoes what `QueryShape.decoder` made of the request: with no override
it hands back the shape the app ships with, which is where a shape search gets
its starting point without anyone transcribing it, and with one it hands back the
decoded form, which is the form worth hashing when deduplicating a population.

`error` is `""` on success: ports cannot carry a `Maybe`, and an empty body list
is a legitimate answer to an empty batch, so the two cases need telling apart.

-}
port gotBodies :
    { bodies : List { packages : String, options : String }
    , shapes : { packages : String, options : String }
    , error : String
    }
    -> Cmd msg


type alias Request =
    { queries : List String
    , k : Int
    , packagesShape : Maybe Shape
    , optionsShape : Maybe Shape
    }


requestDecoder : Json.Decode.Decoder Request
requestDecoder =
    Json.Decode.succeed Request
        |> Json.Decode.Pipeline.required "queries" (Json.Decode.list Json.Decode.string)
        |> Json.Decode.Pipeline.required "k" Json.Decode.int
        |> Json.Decode.Pipeline.optional "packagesShape" (Json.Decode.nullable QueryShape.decoder) Nothing
        |> Json.Decode.Pipeline.optional "optionsShape" (Json.Decode.nullable QueryShape.decoder) Nothing


main : Program () () Json.Decode.Value
main =
    Platform.worker
        { init = \_ -> ( (), Cmd.none )
        , update = \msg _ -> ( (), emit msg )
        , subscriptions = \_ -> sendBatch identity
        }


emit : Json.Decode.Value -> Cmd msg
emit raw =
    case Json.Decode.decodeValue requestDecoder raw of
        Ok request ->
            let
                packages =
                    Maybe.withDefault Search.Query.defaultPackagesShape request.packagesShape

                options =
                    Maybe.withDefault Search.Query.defaultOptionsShape request.optionsShape
            in
            gotBodies
                { bodies =
                    List.map (bodiesFor request.k packages options) request.queries
                , shapes =
                    { packages = Json.Encode.encode 0 (QueryShape.toJson packages)
                    , options = Json.Encode.encode 0 (QueryShape.toJson options)
                    }
                , error = ""
                }

        Err error ->
            gotBodies
                { bodies = []
                , shapes = { packages = "", options = "" }
                , error = Json.Decode.errorToString error
                }


bodiesFor : Int -> Shape -> Shape -> String -> { packages : String, options : String }
bodiesFor k packages options query =
    { packages =
        Search.Query.packagesBodyWith packages query 0 k Search.Relevance []
            |> Json.Encode.encode 0
    , options =
        Search.Query.optionsBodyWith options [ "option" ] query 0 k Search.Relevance
            |> Json.Encode.encode 0
    }
