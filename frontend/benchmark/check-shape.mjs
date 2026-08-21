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
 * tree produces against a reference body. No Elasticsearch involved - it is the
 * encoder that is under test. There are two references worth checking against:
 *
 *     node benchmark/check-shape.mjs --reference HEAD~1
 *
 * a git revision, for whenever `Search/Query.elm` or `Search/QueryShape.elm` is
 * refactored rather than retuned; and
 *
 *     node benchmark/check-shape.mjs --shape benchmark/evolve/champion-packages.json
 *
 * a committed champion, for the shape a search chose. That one is the guard
 * against codegen drift: `evolve/to-elm.mjs` turns the JSON into the Elm literal
 * in `Query.elm` by hand-maintained name tables, and this is what fails when one
 * of those tables is wrong or when the literal is later edited away from the
 * JSON it is supposed to be. Both belong in CI.
 *
 * A run that reports a difference is either a bug or a deliberate ranking change
 * - and if it is deliberate, the benchmark report is the thing that has to
 * justify it.
 */

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";

import { bootWorker } from "./lib/worker.mjs";

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
        shape: { type: "string", multiple: true, default: [] },
        k: { type: "string", default: "10" },
    },
    strict: true,
});

const K = parseInt(args.k, 10);

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

const current = bootWorker({ sourceDir: FRONTEND_DIR, label: "current" });
const isAll = await current.bodiesFor(queries, K);

let differing = 0;
let checked = 0;

/** Report one body mismatch, up to a few - the first is nearly always enough. */
function compare(source, track, query, was, is) {
    checked += 1;
    if (was === is) return;
    differing += 1;
    if (differing <= 3) {
        console.error(`\n--- ${track} body differs for ${JSON.stringify(query)}`);
        console.error(`  ${source}: ${was}`);
        console.error(`  working tree: ${is}`);
    }
}

if (args.shape.length > 0) {
    // Codegen drift: the Elm literal in `Query.elm` against the champion JSON it
    // was generated from. Both go through the same worker, so what is compared
    // is only the transcription.
    for (const path of args.shape) {
        const saved = JSON.parse(readFileSync(path, "utf8"));
        const track = saved.track;
        if (track !== "packages" && track !== "options") {
            throw new Error(`${path}: no "track" saying which shape this is`);
        }
        const fromJson = await current.bodiesFor(queries, K, { [track]: saved.shape });
        for (const [i, query] of queries.entries()) {
            compare(path, track, query, fromJson[i][track], isAll[i][track]);
        }
    }
} else {
    const referenceDir = checkoutFrontend(args.reference);
    const reference = bootWorker({ sourceDir: referenceDir, label: "reference" });
    const wasAll = await reference.bodiesFor(queries, K);
    for (const [i, query] of queries.entries()) {
        for (const track of ["packages", "options"]) {
            compare(args.reference, track, query, wasAll[i][track], isAll[i][track]);
        }
    }
    reference.cleanup();
    rmSync(referenceDir, { recursive: true, force: true });
}

current.cleanup();

const against = args.shape.length > 0 ? args.shape.join(", ") : args.reference;
if (differing === 0) {
    console.log(
        `check-shape: ${checked} bodies identical to ${against} across ${queries.length} queries`,
    );
} else {
    console.error(`\ncheck-shape: ${differing} of ${checked} bodies differ from ${against}`);
    process.exitCode = 1;
}
