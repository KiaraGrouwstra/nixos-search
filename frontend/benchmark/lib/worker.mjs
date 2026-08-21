/**
 * Booting `src/Benchmark.elm` and asking it for request bodies.
 *
 * Everything that scores the search goes through here, because the point of the
 * Elm worker is that the benchmark measures the encoder that ships rather than a
 * JavaScript copy of it. A shape search additionally *tunes* through it: a
 * candidate shape is posted in as JSON, `Search.QueryShape.decoder` is the thing
 * that decides whether it is a query at all, and what comes back is the body
 * Elasticsearch would receive from the browser.
 *
 * One compile serves a whole run. `elm make` costs a few seconds and the worker
 * is pure, so it is booted once and asked thousands of times.
 */

import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FRONTEND_DIR = resolve(__dirname, "../..");

/**
 * Compile and boot the worker from a source tree.
 *
 * `sourceDir` is the working tree by default; `check-shape.mjs` points it at a
 * checkout of another revision instead. The `elm` binary always comes from the
 * working tree's `node_modules` - the revision under test supplies source, not
 * a toolchain - and the compiles share `~/.elm`, so the second one only rebuilds
 * what actually differs.
 */
export function bootWorker({
    sourceDir = FRONTEND_DIR,
    label = "worker",
    log = (message) => console.error(message),
} = {}) {
    const outDir = mkdtempSync(join(tmpdir(), `nixos-search-${label}-`));
    const workerPath = join(outDir, "benchmark.js");
    log(`[benchmark] compiling ${label} -> ${workerPath}`);
    execFileSync(
        join(FRONTEND_DIR, "node_modules/.bin/elm"),
        ["make", "src/Benchmark.elm", "--optimize", "--output", workerPath],
        { cwd: sourceDir, stdio: ["ignore", "ignore", "inherit"] },
    );

    const require = createRequire(import.meta.url);
    const app = require(workerPath).Elm.Benchmark.init({ flags: {} });

    // `check-shape.mjs` compiles arbitrary revisions, including ones from before
    // the port took a batch. Those speak one query per round trip and know
    // nothing about shape overrides, so they are driven through their own port
    // and refuse an override rather than silently ignoring one - a comparison
    // that quietly dropped the shape under test would report a false pass.
    const batched = "sendBatch" in app.ports;

    /**
     * Render a batch.
     *
     * `shapes` is `{ packages, options }` of shape JSON, either omitted or
     * `null` for the default the app ships with. Returns `{ bodies, shapes }`:
     * one `{ packages, options }` of body JSON per query in order, and the
     * shapes that ranked them as `QueryShape.decoder` read them - which is the
     * incumbent when nothing was overridden, and the canonical form of the
     * override otherwise.
     */
    async function render(queries, k, shapes = {}) {
        const { packages = null, options = null } = shapes ?? {};
        if (!batched) {
            if (packages || options) {
                throw new Error(
                    `${label}: this revision's worker predates shape overrides`,
                );
            }
            return { bodies: await legacyBodiesFor(app, queries, k), shapes: null };
        }
        return new Promise((resolve, reject) => {
            const once = (reply) => {
                app.ports.gotBodies.unsubscribe(once);
                if (reply.error) reject(new Error(`${label}: ${reply.error}`));
                else resolve(reply);
            };
            app.ports.gotBodies.subscribe(once);
            app.ports.sendBatch.send({
                queries,
                k,
                packagesShape: packages,
                optionsShape: options,
            });
        });
    }

    return {
        render,

        /** `render`, for the callers that only want the bodies. */
        async bodiesFor(queries, k, shapes = {}) {
            return (await render(queries, k, shapes)).bodies;
        },

        /**
         * The shapes the app ships with, as JSON.
         *
         * A shape search seeds generation 0 from these, so the search starts
         * from the incumbent and can only report an improvement on it.
         */
        async defaultShapes() {
            const { shapes } = await render([], 1);
            return {
                packages: JSON.parse(shapes.packages),
                options: JSON.parse(shapes.options),
            };
        },

        cleanup: () => rmSync(outDir, { recursive: true, force: true }),
    };
}

/** Drive a pre-batch worker: one `sendQuery` round trip per query. */
async function legacyBodiesFor(app, queries, k) {
    const bodies = [];
    for (const query of queries) {
        bodies.push(
            await new Promise((resolve) => {
                const once = (pair) => {
                    app.ports.gotBodies.unsubscribe(once);
                    resolve(pair);
                };
                app.ports.gotBodies.subscribe(once);
                app.ports.sendQuery.send({ query, k });
            }),
        );
    }
    return bodies;
}
