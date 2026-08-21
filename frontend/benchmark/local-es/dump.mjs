#!/usr/bin/env node
/**
 * Dump one Elasticsearch index to disk, for replay into a local cluster.
 *
 * Usage:
 *   node benchmark/local-es/dump.mjs [--index <name>] [--url <url>] [--out <dir>] [--size <n>] [--resume]
 *
 * Writes three files into `--out`:
 *
 *   settings.json  the index `_settings` verbatim, cluster-specific keys and all
 *   mapping.json   the index `_mapping` verbatim
 *   docs.ndjson    one `{"_id": ..., "_sort": [...], "_source": {...}}` per line
 *
 * The source cluster is `--url`, else `ELASTICSEARCH_URL`, else the public one.
 *
 * Pagination is `search_after` over a `_doc` sort. `_doc` is Lucene document
 * order, so `load.mjs` can replay documents in the order production stored
 * them, which is how Elasticsearch breaks ties between equal scores. A scroll
 * would be the obvious way to walk an index, but `search.nixos.org/backend` is
 * a Bonsai proxy that only authorizes index-scoped paths, and scroll
 * continuation lives at the cluster-scoped `/_search/scroll` (401 there).
 *
 * That choice also makes the walk resumable, which matters because this is
 * ninety-odd requests against somebody else's cluster over the internet and
 * they do not all survive. `_sort` on each line is the cursor that produced it,
 * so `--resume` recovers where to continue from the data already on disk -
 * there is no sidecar file that could disagree with it. Appending keeps `_doc`
 * order intact, and a line left half-written by a killed process is truncated
 * before the walk starts again.
 *
 * Correctness rests on the index not changing between the first request and the
 * last, resumed or not. The indices this targets are per-evaluation and
 * immutable once built, so no point-in-time reader is needed.
 *
 * The index this exists to copy is a single shard, so there is no cross-shard
 * IDF variance to reproduce: same documents plus same mapping plus one shard
 * gives the same scores.
 */

import { mkdirSync, createWriteStream } from "node:fs";
import { open, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { once } from "node:events";

import { esClient, esConfigFromEnv } from "../lib/es.mjs";

const { values: args } = parseArgs({
    args: process.argv.slice(2),
    options: {
        index: {
            type: "string",
            default:
                "nixos-51-unstable-ffb3c9b700e759be2ef13237c9d8f953b32a1e46",
        },
        url: { type: "string" },
        out: { type: "string", default: "benchmark/local-es/dump" },
        size: { type: "string", default: "2000" },
        resume: { type: "boolean", default: false },
    },
    strict: false,
});

const INDEX = args.index;
const SIZE = parseInt(args.size, 10);
const OUT = args.out;
const DOCS = join(OUT, "docs.ndjson");

// The shared client owns the retry policy, so there is only one of those in the
// tree. `--url` overrides `ELASTICSEARCH_URL` because a dump names its source
// on the command line more often than it exports it.
const es = esClient({
    ...esConfigFromEnv(),
    ...(args.url && { url: args.url.replace(/\/$/, "") }),
    index: INDEX,
    log: (message) => process.stderr.write(`\n${message}\n`),
});

/// Backpressure-aware write, so a slow disk cannot outrun the walk.
async function writeLine(stream, line) {
    if (!stream.write(line)) await once(stream, "drain");
}

/**
 * What is already in `docs.ndjson`, and where to carry on from.
 *
 * One pass, counting complete lines and keeping the last of them, then a
 * truncate to the final newline. Counting is what makes the doc-count check at
 * the end mean anything on a resumed run, and the truncate is what makes a
 * process killed mid-write recoverable rather than silently corrupt.
 */
async function resumeFrom(path) {
    let handle;
    try {
        handle = await open(path, "r+");
    } catch (err) {
        if (err.code === "ENOENT") return { count: 0 };
        throw err;
    }
    try {
        const decoder = new TextDecoder();
        let count = 0;
        let lastLine = null;
        let complete = 0; // bytes up to and including the last newline
        let offset = 0;
        let line = [];
        for await (const chunk of handle.createReadStream({
            autoClose: false,
        })) {
            let start = 0;
            let nl;
            while ((nl = chunk.indexOf(0x0a, start)) !== -1) {
                line.push(chunk.subarray(start, nl));
                lastLine = decoder.decode(Buffer.concat(line));
                line = [];
                count += 1;
                complete = offset + nl + 1;
                start = nl + 1;
            }
            line.push(chunk.subarray(start));
            offset += chunk.length;
        }
        if (count === 0) return { count: 0 };
        await handle.truncate(complete);

        const { _sort: after } = JSON.parse(lastLine);
        if (after === undefined) {
            throw new Error(
                `${path} has no \`_sort\` on its last line, so there is no cursor to resume from; it predates \`--resume\` and has to be dumped again`,
            );
        }
        return { count, after };
    } finally {
        await handle.close();
    }
}

mkdirSync(OUT, { recursive: true });

const [settings, mapping] = await Promise.all([
    es.get(`/${INDEX}/_settings`),
    es.get(`/${INDEX}/_mapping`),
]);
await Promise.all([
    writeFile(join(OUT, "settings.json"), JSON.stringify(settings, null, 2) + "\n"),
    writeFile(join(OUT, "mapping.json"), JSON.stringify(mapping, null, 2) + "\n"),
]);

const resumed = args.resume ? await resumeFrom(DOCS) : { count: 0 };
if (resumed.count > 0) {
    console.error(`[dump] resuming after ${resumed.count} docs already written`);
}

const docs = createWriteStream(DOCS, { flags: resumed.count > 0 ? "a" : "w" });
const started = Date.now();
let total = resumed.count;
let after = resumed.after;

try {
    let expected;
    for (;;) {
        const page = await es.search(
            JSON.stringify({
                size: SIZE,
                sort: ["_doc"],
                query: { match_all: {} },
                // Only the first request of the process pays for the count.
                ...(expected === undefined && { track_total_hits: true }),
                ...(after !== undefined && { search_after: after }),
            }),
        );
        expected ??= page.hits.total.value;
        if (page.hits.hits.length === 0) break;

        for (const hit of page.hits.hits) {
            await writeLine(
                docs,
                JSON.stringify({
                    _id: hit._id,
                    _sort: hit.sort,
                    _source: hit._source,
                }) + "\n",
            );
        }
        after = page.hits.hits.at(-1).sort;
        total += page.hits.hits.length;
        const secs = (Date.now() - started) / 1000;
        const rate = Math.round((total - resumed.count) / secs);
        process.stderr.write(`\r[dump] ${total}/${expected} docs (${rate}/s)`);
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
