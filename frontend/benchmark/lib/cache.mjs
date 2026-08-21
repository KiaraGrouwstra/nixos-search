/**
 * A result cache keyed by the exact request that produced it.
 *
 * A shape search re-sends the same request body constantly: elites survive
 * generations unchanged, a mutation to one branch leaves the other branches
 * identical, and duplicate genomes appear no matter how the population is
 * deduped. Each of those is a request that has already been answered, and the
 * answer cannot have changed - the index is pinned.
 *
 * The key is `sha256(index + body)`, so it is safe across indices and across
 * runs, and it is exact rather than structural: two bodies that differ only in
 * key order are different keys, which is the conservative direction to be wrong
 * in.
 *
 * On disk it is one append-only NDJSON file, read into memory at open. That
 * makes it survive restarts - the point of an overnight run being resumable -
 * without a database, and an interrupted write costs at most the last line,
 * which is dropped on the next open.
 */

import { createHash } from "node:crypto";
import { createWriteStream, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname } from "node:path";

export function cacheKey(index, body) {
    return createHash("sha256").update(index).update("\n").update(body).digest("hex");
}

/**
 * Open the cache at `path`, creating it if it is not there.
 *
 * The caller decides what a value is - the cache only moves JSON - so it is
 * worth storing the smallest thing that answers the question rather than a
 * whole Elasticsearch response.
 */
export function openCache(path) {
    const entries = new Map();
    let dropped = 0;

    if (existsSync(path)) {
        const text = readFileSync(path, "utf8");
        for (const line of text.split("\n")) {
            if (line === "") continue;
            try {
                const [key, value] = JSON.parse(line);
                entries.set(key, value);
            } catch {
                // A run killed mid-write leaves a partial last line. Anything
                // unreadable is a cache miss, which costs a request and nothing
                // else.
                dropped += 1;
            }
        }
    } else {
        mkdirSync(dirname(path), { recursive: true });
    }

    const out = createWriteStream(path, { flags: "a" });

    return {
        path,
        dropped,
        get size() {
            return entries.size;
        },
        has(key) {
            return entries.has(key);
        },
        get(key) {
            return entries.get(key);
        },
        set(key, value) {
            entries.set(key, value);
            out.write(JSON.stringify([key, value]) + "\n");
        },
        close() {
            return new Promise((resolve) => out.end(resolve));
        },
    };
}
