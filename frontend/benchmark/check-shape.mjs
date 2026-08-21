/**
 * Prove that a change to the query shape did not change the query.
 *
 * `Search.Query` used to spell the Elasticsearch body out directly; it now
 * builds one from a `Search.QueryShape` value. That refactor is only worth
 * anything if it is exactly behaviour-preserving, and "exactly" here means the
 * bytes: two bodies that differ only in key order are the same query to
 * Elasticsearch but not the same artifact to review, and a shape that can
 * *nearly* reproduce the incumbent is a shape that has quietly dropped
 * something.
 *
 * So this compares, for every curated benchmark query, the body the working
 * tree produces against the body a reference git revision produces. No
 * Elasticsearch involved - it is the encoder that is under test.
 *
 *     node benchmark/check-shape.mjs --reference HEAD~1
 *
 * Use it whenever `Search/Query.elm` or `Search/QueryShape.elm` is refactored
 * rather than retuned. A run that reports a difference is either a bug or a
 * deliberate ranking change - and if it is deliberate, the benchmark report is
 * the thing that has to justify it.
 */

import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { mkdtempSync, readFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FRONTEND_DIR = resolve(__dirname, "..");
const REPO_ROOT = resolve(FRONTEND_DIR, "..");

const { values: args } = parseArgs({
    args: process.argv.slice(2),
    options: {
        packages: {
            type: "string",
            default: join(__dirname, "queries-packages.json"),
        },
        options: {
            type: "string",
            default: join(__dirname, "queries-options.json"),
        },
        reference: { type: "string", default: "HEAD" },
        k: { type: "string", default: "10" },
    },
    strict: true,
});

const K = parseInt(args.k, 10);

/**
 * Compile `Benchmark.elm` from a source directory and boot the worker.
 *
 * Each tree gets its own `elm make` output, but they share `~/.elm`, so the
 * second compile only rebuilds the modules that actually differ.
 */
function bootWorker(sourceDir, label) {
    const outDir = mkdtempSync(join(tmpdir(), `nixos-search-shape-${label}-`));
    const workerPath = join(outDir, "benchmark.js");
    console.error(`[check-shape] compiling ${label} -> ${workerPath}`);
    execFileSync(
        join(FRONTEND_DIR, "node_modules/.bin/elm"),
        ["make", "src/Benchmark.elm", "--optimize", "--output", workerPath],
        { cwd: sourceDir, stdio: ["ignore", "ignore", "inherit"] },
    );
    const require = createRequire(import.meta.url);
    const app = require(workerPath).Elm.Benchmark.init({ flags: {} });
    return {
        bodiesFor(query) {
            return new Promise((resolve) => {
                const once = (bodies) => {
                    app.ports.gotBodies.unsubscribe(once);
                    resolve(bodies);
                };
                app.ports.gotBodies.subscribe(once);
                app.ports.sendQuery.send({ query, k: K });
            });
        },
        cleanup: () => rmSync(outDir, { recursive: true, force: true }),
    };
}

/**
 * Check out a revision's `frontend/` into a scratch directory.
 *
 * `elm make` needs `elm.json` and `src/`, both of which come from the
 * revision, and it needs `elm-stuff` to be writable - which is why this is a
 * copy rather than a read straight out of the object store.
 */
function checkoutFrontend(revision) {
    const dir = mkdtempSync(join(tmpdir(), "nixos-search-shape-ref-"));
    execFileSync(
        "bash",
        [
            "-c",
            `git archive --format=tar ${JSON.stringify(revision)} frontend | tar -x -C ${JSON.stringify(dir)} --strip-components=1 frontend`,
        ],
        { cwd: REPO_ROOT, stdio: ["ignore", "ignore", "inherit"] },
    );
    if (!existsSync(join(dir, "elm.json"))) {
        throw new Error(`revision ${revision} has no frontend/elm.json`);
    }
    return dir;
}

function queriesFrom(path) {
    return JSON.parse(readFileSync(path, "utf8")).map((entry) => entry.q);
}

const queries = [
    ...queriesFrom(args.packages),
    ...queriesFrom(args.options),
    // The encoder's behaviour on an empty search box is easy to break and
    // impossible to notice, since no curated query exercises it.
    "",
];

const referenceDir = checkoutFrontend(args.reference);
const reference = bootWorker(referenceDir, "reference");
const current = bootWorker(FRONTEND_DIR, "current");

let differing = 0;
for (const query of queries) {
    const [was, is] = await Promise.all([
        reference.bodiesFor(query),
        current.bodiesFor(query),
    ]);
    for (const track of ["packages", "options"]) {
        if (was[track] === is[track]) continue;
        differing += 1;
        if (differing <= 3) {
            console.error(`\n--- ${track} body differs for ${JSON.stringify(query)}`);
            console.error(`  ${args.reference}: ${was[track]}`);
            console.error(`  working tree: ${is[track]}`);
        }
    }
}

reference.cleanup();
current.cleanup();
rmSync(referenceDir, { recursive: true, force: true });

const checked = queries.length * 2;
if (differing === 0) {
    console.log(
        `check-shape: ${checked} bodies identical to ${args.reference} across ${queries.length} queries`,
    );
} else {
    console.error(
        `\ncheck-shape: ${differing} of ${checked} bodies differ from ${args.reference}`,
    );
    process.exitCode = 1;
}
