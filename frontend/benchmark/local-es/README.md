# A local replica of a production index

The relevance benchmark in `frontend/benchmark` scores its curated queries
against `https://search.nixos.org/backend` by default. That is the right target
for a one-off A/B, but a single `_search` there costs around 800 ms of round
trip, so anything that needs thousands of evaluations - a sweep over the query
shape, say - is bounded by the network rather than by Elasticsearch.

These two scripts copy a pinned index onto a throwaway local cluster that
answers the same queries with the same scores.

## Why the scores match

The indices behind `search.nixos.org` are single-shard. BM25 draws its IDF from
per-shard statistics, so a copy with one shard, the same documents and the same
analysis settings ranks identically - there is no cross-shard variance to
reproduce. `load.mjs` therefore pins `number_of_shards` to 1 and replays the
saved `_settings` otherwise unchanged.

Ties are the other half. Elasticsearch breaks equal scores by Lucene document
id, so document order has to survive the copy: `dump.mjs` walks the source in
`_doc` order and `load.mjs` bulks the result back in one request at a time,
in that order.

`local-es` runs the same Elasticsearch the cluster does, 7.10.2 under the
Apache-2.0 licence, which nixpkgs no longer packages - see
`nix/elasticsearch-oss.nix`.

## Use

Start the cluster. It listens on `http://localhost:9200` without
authentication, and keeps its index, logs and generated config under
`--data-dir`, so the same directory can be reused across restarts.

    nix run .#local-es -- --data-dir ~/.cache/nixos-search-local-es

Copy an index across. Both scripts default to the same index name; `dump.mjs`
reads from the public cluster and `load.mjs` writes to localhost.

    cd frontend
    node benchmark/local-es/dump.mjs --index <name> --out <dir>
    node benchmark/local-es/load.mjs --in <dir>

`load.mjs` rebuilds the index wholesale and refuses to run against one that
already exists unless given `--force`; there is no incremental mode, because a
partially refreshed copy would score differently from production and the point
of the copy is that it does not.

Then point the benchmark at it:

    ELASTICSEARCH_URL=http://localhost:9200 node benchmark/run.mjs --index <name>

## Checking the copy

The copy is only useful while it is faithful, and that is cheap to assert: the
full report against the replica should be byte-identical to the report against
the live cluster for the same index.

    cd frontend
    node benchmark/run.mjs --index <name> > /tmp/live.md
    ELASTICSEARCH_URL=http://localhost:9200 node benchmark/run.mjs --index <name> > /tmp/local.md
    diff /tmp/live.md /tmp/local.md
