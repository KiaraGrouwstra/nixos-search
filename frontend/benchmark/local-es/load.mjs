#!/usr/bin/env node
/**
 * Replay a `dump.mjs` dump into a local Elasticsearch cluster.
 *
 * Usage:
 *   node benchmark/local-es/load.mjs [--index <name>] [--url <url>] [--in <dir>] [--bytes <n>] [--force]
 *
 * Refuses to touch an index that already exists unless `--force`, which deletes
 * it first. There is no incremental mode: the point of the copy is that it
 * scores identically to production, and that is only defensible if the whole
 * index is rebuilt from one dump.
 *
 * The saved settings are replayed as-is except for four keys Elasticsearch
 * assigns rather than accepts - `uuid`, `creation_date`, `provided_name` and
 * `version` - and the shard counts, which are pinned to 1 primary and 0
 * replicas. One primary shard is what production runs, and it is what makes the
 * copy score identically: BM25 draws its IDF from per-shard statistics, so a
 * differently sharded copy of the same documents would rank them differently.
 * Zero replicas keeps a single-node cluster green.
 *
 * Analysis settings, on the other hand, are copied verbatim and matter enormously:
 * the `edge` and `attr_path` analyzers are what the benchmarked query relies on.
 *
 * Bulk requests are issued one at a time, in dump order. That is slower than
 * fanning out, but it reproduces production's Lucene document order, which is
 * how Elasticsearch breaks ties between documents on equal score.
 */

import { createReadStream, readFileSync } from "node:fs";
import { createInterface } from "node:readline";
import { join } from "node:path";
import { parseArgs } from "node:util";

const { values: args } = parseArgs({
    args: process.argv.slice(2),
    options: {
        index: { type: "string" },
        url: { type: "string", default: "http://localhost:9200" },
        in: { type: "string", default: "benchmark/local-es/dump" },
        bytes: { type: "string", default: String(16 * 1024 * 1024) },
        force: { type: "boolean", default: false },
    },
    strict: false,
});

const ES_URL = args.url.replace(/\/$/, "");
const IN = args.in;
const MAX_BYTES = parseInt(args.bytes, 10);

const ES_USER = process.env.ELASTICSEARCH_USERNAME || "aWVSALXpZv";
const ES_PASS =
    process.env.ELASTICSEARCH_PASSWORD || "X8gPHnzL52wFEekuxsfQ9cSh";
const AUTH = "Basic " + Buffer.from(`${ES_USER}:${ES_PASS}`).toString("base64");

const readJson = (name) => JSON.parse(readFileSync(join(IN, name), "utf8"));

async function es(path, { method = "GET", body, ndjson = false } = {}) {
    const resp = await fetch(`${ES_URL}${path}`, {
        method,
        headers: {
            "Content-Type": ndjson
                ? "application/x-ndjson"
                : "application/json",
            Authorization: AUTH,
        },
        body:
            body === undefined
                ? undefined
                : ndjson
                  ? body
                  : JSON.stringify(body),
    });
    const text = await resp.text();
    if (!resp.ok) throw new Error(`ES ${resp.status} on ${path}: ${text}`);
    return text === "" ? null : JSON.parse(text);
}

// `_settings` and `_mapping` both answer keyed by index name, and the dump may
// have come from an alias, so read the single value rather than the key.
const only = (response) => Object.values(response)[0];
const dumped = readJson("settings.json");
const SOURCE_INDEX = Object.keys(dumped)[0];
const INDEX = args.index ?? SOURCE_INDEX;

const index = { ...only(dumped).settings.index };
for (const assigned of ["uuid", "creation_date", "provided_name", "version"]) {
    delete index[assigned];
}
index.number_of_shards = "1";
index.number_of_replicas = "0";
// `_settings` reports unset dynamic settings as null, which the create API rejects.
for (const [key, value] of Object.entries(index)) {
    if (value === null) delete index[key];
}

const exists = await fetch(`${ES_URL}/${INDEX}`, {
    method: "HEAD",
    headers: { Authorization: AUTH },
});
if (exists.ok) {
    if (!args.force) {
        console.error(
            `[load] ${INDEX} already exists on ${ES_URL}; pass --force to replace it`,
        );
        process.exit(1);
    }
    await es(`/${INDEX}`, { method: "DELETE" });
}

await es(`/${INDEX}`, {
    method: "PUT",
    body: {
        // Indexing throughput only; restored below so searches see the docs.
        settings: { ...index, refresh_interval: "-1" },
        mappings: only(readJson("mapping.json")).mappings,
    },
});

const started = Date.now();
let total = 0;
let batch = [];
let bytes = 0;

async function flush() {
    if (batch.length === 0) return;
    const result = await es(`/${INDEX}/_bulk`, {
        method: "POST",
        ndjson: true,
        body: batch.join(""),
    });
    if (result.errors) {
        const failed = result.items.find((item) => item.index.error);
        throw new Error(`bulk failed: ${JSON.stringify(failed.index.error)}`);
    }
    total += batch.length;
    batch = [];
    bytes = 0;
    const secs = (Date.now() - started) / 1000;
    process.stderr.write(
        `\r[load] ${total} docs (${Math.round(total / secs)}/s)`,
    );
}

const lines = createInterface({
    input: createReadStream(join(IN, "docs.ndjson")),
    crlfDelay: Infinity,
});
for await (const line of lines) {
    if (line === "") continue;
    const { _id, _source } = JSON.parse(line);
    const action = `${JSON.stringify({ index: { _id } })}\n${JSON.stringify(_source)}\n`;
    batch.push(action);
    bytes += action.length;
    if (bytes >= MAX_BYTES) await flush();
}
await flush();
process.stderr.write("\n");

await es(`/${INDEX}/_settings`, {
    method: "PUT",
    body: { index: { refresh_interval: null } },
});
await es(`/${INDEX}/_refresh`, { method: "POST" });

const count = (await es(`/${INDEX}/_count`)).count;
if (count !== total) {
    throw new Error(`loaded ${total} docs, index reports ${count}`);
}

console.error(
    `[load] ${total} docs into ${INDEX} on ${ES_URL} in ${((Date.now() - started) / 1000).toFixed(1)}s`,
);
