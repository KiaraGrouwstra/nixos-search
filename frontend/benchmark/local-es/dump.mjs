#!/usr/bin/env node
/**
 * Dump one Elasticsearch index to disk, for replay into a local cluster.
 *
 * Usage:
 *   node benchmark/local-es/dump.mjs [--index <name>] [--url <url>] [--out <dir>] [--size <n>]
 *
 * Writes three files into `--out`:
 *
 *   settings.json  the index `_settings` verbatim, cluster-specific keys and all
 *   mapping.json   the index `_mapping` verbatim
 *   docs.ndjson    one `{"_id": ..., "_source": {...}}` object per line
 *
 * Pagination is `search_after` over a `_doc` sort. `_doc` is Lucene document
 * order, so `load.mjs` can replay documents in the order production stored
 * them, which is how Elasticsearch breaks ties between equal scores. A scroll
 * would be the obvious way to walk an index, but `search.nixos.org/backend` is
 * a Bonsai proxy that only authorizes index-scoped paths, and scroll
 * continuation lives at the cluster-scoped `/_search/scroll` (401 there).
 * `search_after` needs no server-side state anyway.
 *
 * Correctness rests on the index not changing under the walk. The indices this
 * targets are per-evaluation and immutable once built, so no point-in-time
 * reader is needed.
 *
 * The index this exists to copy is a single shard, so there is no cross-shard
 * IDF variance to reproduce: same documents plus same mapping plus one shard
 * gives the same scores.
 */

import { mkdirSync, createWriteStream } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { once } from "node:events";

const { values: args } = parseArgs({
    args: process.argv.slice(2),
    options: {
        index: {
            type: "string",
            default:
                "nixos-51-unstable-ffb3c9b700e759be2ef13237c9d8f953b32a1e46",
        },
        url: { type: "string", default: "https://search.nixos.org/backend" },
        out: { type: "string", default: "benchmark/local-es/dump" },
        size: { type: "string", default: "2000" },
    },
    strict: false,
});

const ES_URL = args.url.replace(/\/$/, "");
const INDEX = args.index;
const SIZE = parseInt(args.size, 10);
const OUT = args.out;

// Same defaults as `run.mjs`: the public cluster wants these, a local one
// ignores the header.
const ES_USER = process.env.ELASTICSEARCH_USERNAME || "aWVSALXpZv";
const ES_PASS =
    process.env.ELASTICSEARCH_PASSWORD || "X8gPHnzL52wFEekuxsfQ9cSh";
const AUTH = "Basic " + Buffer.from(`${ES_USER}:${ES_PASS}`).toString("base64");

const RETRYABLE_STATUS = new Set([429, 502, 503, 504]);
const MAX_ATTEMPTS = 5;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function es(path, { method = "GET", body } = {}) {
    let lastErr;
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
        try {
            const resp = await fetch(`${ES_URL}${path}`, {
                method,
                headers: {
                    "Content-Type": "application/json",
                    Authorization: AUTH,
                },
                body: body === undefined ? undefined : JSON.stringify(body),
            });
            if (resp.ok) return resp.json();
            const text = await resp.text();
            if (!RETRYABLE_STATUS.has(resp.status)) {
                throw new Error(`ES ${resp.status} on ${path}: ${text}`);
            }
            lastErr = new Error(`ES ${resp.status} on ${path}: ${text}`);
        } catch (err) {
            if (!(err instanceof TypeError && err.cause)) throw err;
            lastErr = err;
        }
        await sleep(500 * 2 ** (attempt - 1));
    }
    throw lastErr;
}

/// Backpressure-aware write, so a slow disk cannot outrun the walk.
async function writeLine(stream, line) {
    if (!stream.write(line)) await once(stream, "drain");
}

mkdirSync(OUT, { recursive: true });

const settings = await es(`/${INDEX}/_settings`);
const mapping = await es(`/${INDEX}/_mapping`);
await Promise.all(
    [
        ["settings.json", settings],
        ["mapping.json", mapping],
    ].map(async ([name, value]) => {
        const stream = createWriteStream(join(OUT, name));
        stream.end(JSON.stringify(value, null, 2) + "\n");
        await once(stream, "close");
    }),
);

const docs = createWriteStream(join(OUT, "docs.ndjson"));
const started = Date.now();
let total = 0;

try {
    let expected;
    let after;
    for (;;) {
        const page = await es(`/${INDEX}/_search`, {
            method: "POST",
            body: {
                size: SIZE,
                sort: ["_doc"],
                query: { match_all: {} },
                // Only the first page pays for the exact count.
                ...(after === undefined
                    ? { track_total_hits: true }
                    : { search_after: after }),
            },
        });
        expected ??= page.hits.total.value;
        if (page.hits.hits.length === 0) break;

        for (const hit of page.hits.hits) {
            await writeLine(
                docs,
                JSON.stringify({ _id: hit._id, _source: hit._source }) + "\n",
            );
        }
        after = page.hits.hits.at(-1).sort;
        total += page.hits.hits.length;
        const secs = (Date.now() - started) / 1000;
        process.stderr.write(
            `\r[dump] ${total}/${expected} docs (${Math.round(total / secs)}/s)`,
        );
    }
    process.stderr.write("\n");

    if (total !== expected) {
        throw new Error(`dumped ${total} docs, index reports ${expected}`);
    }
} finally {
    docs.end();
    await once(docs, "close");
}

console.error(
    `[dump] ${total} docs from ${INDEX} to ${OUT} in ${((Date.now() - started) / 1000).toFixed(1)}s`,
);
