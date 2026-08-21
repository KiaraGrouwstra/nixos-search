#!/usr/bin/env node
/**
 * Relevance benchmark test driver
 *
 * scores curated queries against our live ES instance.
 *
 * Usage:
 *   node benchmark/run.mjs [--packages <path>] [--options <path>] [--channel <branch>] [--schema <n>] [--index <name>] [--k <n>] [--persistence <f>] [--json] [--msearch <n>] [--cache <path>]
 *
 * `--index` names a concrete index instead of the `latest-<schema>-<channel>`
 * alias, which pins an A/B to one nixpkgs evaluation once the alias has moved
 * on to a newer one.
 *
 * `--json` prints the per-query rows and the aggregates as JSON instead of the
 * markdown report, so a comparison does not have to parse prose.
 *
 * `--msearch <n>` batches `n` queries per request, which is minutes against the
 * live cluster rather than seconds. It is off by default because the report is
 * the artifact people diff, and a batched run is only worth trusting once it has
 * been shown to produce the same one.
 *
 * `--cache <path>` reuses the answer to any request body already seen at this
 * index, which is what makes repeated A/Bs cheap.
 *
 * The metric definitions, the category weights, and the Elasticsearch client all
 * live in `lib/`, shared with `evolve/` - a search that optimized a metric this
 * report does not print would be optimizing something nobody agreed to.
 *
 * Each curated query is an object:
 *
 *   id          stable handle, also the sort key of the per-query table
 *   q           the search term, as a user would type it
 *   category    the one axis this query is here to exercise, e.g. `typo` or
 *               `attrpath`. Also the unit the aggregate is weighted in, so
 *               every category needs an entry in `WEIGHTS` and vice versa.
 *               Where a query fits more than one, the rarer axis wins: an
 *               uppercase name is `cased` before it is `exact`, and a bare last
 *               segment is `leaf` before it is `cased`.
 *   relevant    tiers of ids we accept as answers, `pkg:`/`opt:` prefixed. Each
 *               tier is a list of ids tied at that rank: order *between* tiers
 *               is a claim, order *within* one is not. `[[a, b, c]]` states no
 *               preference, `[[a], [b], [c]]` is a strict order, and
 *               `[[a], [b, c]]` is a best answer followed by a tie. Only tier a
 *               gold set where the ordering is real - `text editor` has no
 *               business claiming `emacs` beats `vim`.
 *   exhaustive  optional; `relevant` enumerates *every* acceptable answer, so
 *               anything else on the page counts as noise. Required for RBP.
 */

import { readFileSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";

import { cacheKey, openCache } from "./lib/cache.mjs";
import { esClient, esConfigFromEnv } from "./lib/es.mjs";
import { mean, rankHits, scoreQuery, weightedMean } from "./lib/metrics.mjs";
import { WEIGHTS, checkWeights } from "./lib/weights.mjs";
import { bootWorker } from "./lib/worker.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FRONTEND_DIR = resolve(__dirname, "..");
const REPO_ROOT = resolve(FRONTEND_DIR, "..");

/// Grep the schema version
function frontendSchema() {
    const version_nix = readFileSync(join(REPO_ROOT, "version.nix"), "utf8");
    const match = version_nix.match(/frontend\s*=\s*"(\d+)"/);
    if (!match) {
        throw new Error("could not parse `frontend` schema from version.nix");
    }
    return match[1];
}

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
        channel: { type: "string", default: "nixos-unstable" },
        schema: { type: "string" },
        index: { type: "string" },
        k: { type: "string", default: "10" },
        persistence: { type: "string", default: "0.8" },
        json: { type: "boolean", default: false },
        msearch: { type: "string" },
        cache: { type: "string" },
    },
    strict: false,
});

// Settings
const K = parseInt(args.k, 10);
const P = parseFloat(args.persistence);
const SCHEMA = args.schema ?? frontendSchema();
const INDEX = args.index ?? `latest-${SCHEMA}-${args.channel}`;
const BATCH = args.msearch ? parseInt(args.msearch, 10) : 1;

const es = esClient({ ...esConfigFromEnv(), index: INDEX });
const cache = args.cache ? openCache(args.cache) : null;
const worker = bootWorker({ label: "benchmark" });

/**
 * The pages for a list of request bodies, as `rankHits` reads them.
 *
 * Cached against `sha256(index + body)`: the body fixes the query, the page
 * size and - because the two tracks never share one - which track's name field
 * to read, and the index is pinned, so the answer cannot have changed.
 */
async function pagesFor(bodies, field, prefix) {
    const pages = new Array(bodies.length);
    const misses = [];
    for (const [i, body] of bodies.entries()) {
        const key = cache && cacheKey(INDEX, body);
        if (key && cache.has(key)) pages[i] = cache.get(key);
        else misses.push(i);
    }

    for (let at = 0; at < misses.length; at += BATCH) {
        const slice = misses.slice(at, at + BATCH);
        const responses =
            BATCH === 1
                ? [await es.search(bodies[slice[0]])]
                : await es.msearch(slice.map((i) => bodies[i]));
        for (const [j, i] of slice.entries()) {
            const data = responses[j];
            const page = {
                ranked: rankHits(data.hits.hits, field, prefix, K),
                matched: data.hits.total.value,
                matchedExact: data.hits.total.relation === "eq",
            };
            pages[i] = page;
            if (cache) cache.set(cacheKey(INDEX, bodies[i]), page);
        }
    }
    return pages;
}

/**
 * Score one curated file against a single index.
 *
 * `bodyKey` selects which of the two bodies the Elm worker emits;
 * `field`/`prefix` build the ranked ids.
 */
async function scoreTrack(queries, bodyKey, field, prefix) {
    const rendered = await worker.bodiesFor(
        queries.map((q) => q.q),
        K,
    );
    const pages = await pagesFor(
        rendered.map((bodies) => bodies[bodyKey]),
        field,
        prefix,
    );
    return queries.map((q, i) => ({
        id: q.id,
        q: q.q,
        category: q.category,
        relevant: q.relevant,
        ...pages[i],
        ...scoreQuery(q, pages[i].ranked, K, P),
    }));
}

const pkgQueries = JSON.parse(readFileSync(args.packages, "utf8"));
const optQueries = JSON.parse(readFileSync(args.options, "utf8"));

checkWeights("packages", pkgQueries, WEIGHTS.packages);
checkWeights("options", optQueries, WEIGHTS.options);

console.error(
    `[benchmark] scoring ${pkgQueries.length} package queries against ${INDEX}`,
);
const pkgResults = await scoreTrack(
    pkgQueries,
    "packages",
    "package_attr_name",
    "pkg:",
);
console.error(
    `[benchmark] scoring ${optQueries.length} option queries against ${INDEX}`,
);
const optResults = await scoreTrack(
    optQueries,
    "options",
    "option_name",
    "opt:",
);

worker.cleanup();
if (cache) await cache.close();

/**
 * The category-weighted aggregate for one track.
 *
 * RBP only covers the closed-set queries that returned something and BestRR only
 * the ones that name a best answer, so each carries the count it was read over.
 */
function aggregate(results, weights) {
    const closed = results.filter((r) => r.rbp !== null);
    const ordinal = results.filter((r) => r.bestrr !== null);
    const agg = (rows, pick) => weightedMean(rows, weights, pick);
    return {
        success: agg(results, (r) => r.success),
        mrr: agg(results, (r) => r.mrr),
        recall: agg(results, (r) => r.recall),
        rbp: agg(closed, (r) => r.rbp),
        bestrr: agg(ordinal, (r) => r.bestrr),
        ndcg: agg(results, (r) => r.ndcg),
        n: results.length,
        nRbp: closed.length,
        nBestrr: ordinal.length,
    };
}

if (args.json) {
    console.log(
        JSON.stringify(
            {
                index: INDEX,
                k: K,
                persistence: P,
                packages: {
                    overall: aggregate(pkgResults, WEIGHTS.packages),
                    queries: pkgResults,
                },
                options: {
                    overall: aggregate(optResults, WEIGHTS.options),
                    queries: optResults,
                },
            },
            null,
            2,
        ),
    );
    process.exit(0);
}

const table = (header, rows) =>
    [
        `| ${header.join(" | ")} |`,
        `| ${header.map(() => "---").join(" | ")} |`,
        ...rows.map((r) => `| ${r.join(" | ")} |`),
    ].join("\n");

// Metric labels paired with the footnote GitHub renders at the bottom of the
// report. Every table names a metric through `metric()`, so each definition is
// written once and the term links there where the report first uses it.
const METRICS = {
    success: {
        label: `Success@${K}`,
        note: `Did the page hold an acceptable answer at all - 1 or 0 per
            query.`,
    },
    mrr: {
        label: "MRR",
        note: `Mean reciprocal rank of the first acceptable answer: 1.000 if it
            led, 0.500 second, 0.333 third, 0 if none made the page.`,
    },
    recall: {
        label: `Recall@${K}`,
        note: `What share of the acceptable answers the page held, over the most
            it could have held at k.`,
    },
    rbp: {
        label: `RBP (p=${P})`,
        note: `Rank-biased precision (Moffat & Zobel 2008): how much of the page
            a user is expected to find useful, pricing rank \`i\` at \`p^(i-1)\`
            so junk near the top costs more than junk near the bottom. \`p\` is
            the chance they read one more result; the denominator is the page we
            returned, so a short clean page still reaches 1.000.`,
    },
    bestrr: {
        label: "BestRR",
        note: `Reciprocal rank of the one answer the query most wants: 1.000 if
            it led, 0.500 second, 0 if it never appeared. Where MRR is satisfied
            by any acceptable answer, this reads the ordering within that set -
            on \`node\` MRR is 1.000 whether \`nodejs\` or \`nodejs-slim_26\`
            led, and BestRR separates those pages 1.000 to 0.167. The gold set
            is a list of tiers of ids tied at a rank; the best answer is a top
            tier holding one id.`,
    },
    ndcg: {
        label: `nDCG@${K}`,
        note: `Normalized discounted cumulative gain (Jarvelin & Kekalainen
            2002): the whole page priced against its ideal ordering, 1.000 when
            nothing could have been ranked better. A hit in tier \`i\` of \`T\`
            grades \`T - i\`, so a one-tier gold set is ordinary binary nDCG.`,
    },
    weight: {
        label: "weight",
        note: `What share of the \`Overall\` figures the category is worth,
            split evenly across its queries. Set from the shape of the real
            queries in \`corpus/observed-queries.json\` where that corpus can
            see them, and by stated judgement where it cannot - it is mined from
            shared links, so it is blind to the searches that failed. Weighting
            per category rather than per query means adding a query sharpens its
            category without moving the mix.`,
    },
    n: {
        label: "n",
        note: `How many queries the figure covers; the rest make no claim the
            metric can read and drop out of its mean. RBP covers queries marked
            \`"exhaustive": true\`, meaning the gold set lists every acceptable
            answer so anything else is noise, that returned at least one hit.
            BestRR covers queries whose gold set names a single best answer.`,
    },
};

// A footnote definition has to be one line; wrap the source, not the output.
const oneLine = (s) => s.trim().replace(/\s+/g, " ");

// A metric named in a table. Only the first mention carries the footnote
// marker - the seven metrics land in the first `Overall` table and `weight` in
// the first `By category` one - because the reference is there to introduce the
// term, and repeating it on every table leaves the reader looking past markers
// to reach the numbers.
const cited = new Set();
const metric = (key) => {
    const first = !cited.has(key);
    cited.add(key);
    return METRICS[key].label + (first ? `[^${key}]` : "");
};

const FOOTNOTES = Object.entries(METRICS).map(
    ([key, { note }]) => `[^${key}]: ${oneLine(note)}`,
);

// One `## <label>` section: Overall + By-category tables for a single track.
function section(label, results, weights) {
    const overall = aggregate(results, weights);
    const byCategory = {};
    for (const r of results) {
        (byCategory[r.category] ??= []).push(r);
    }
    return [
        `## ${label}`,
        "",
        `> ${results.length} queries in ${Object.keys(byCategory).length} categories.`,
        "",
        "### Overall",
        "",
        `> Weighted by category, so the figures track the query mix real users
         type rather than the mix we happened to curate. The weights and where
         they come from are in \`WEIGHTS\` in \`run.mjs\`.`.replace(/\s+/g, " "),
        "",
        table(
            ["metric", "value", metric("n")],
            [
                [metric("success"), overall.success.toFixed(3), overall.n],
                [metric("mrr"), overall.mrr.toFixed(3), overall.n],
                [metric("recall"), overall.recall.toFixed(3), overall.n],
                [
                    metric("rbp"),
                    overall.rbp === null ? "-" : overall.rbp.toFixed(3),
                    overall.nRbp,
                ],
                [
                    metric("bestrr"),
                    overall.bestrr === null ? "-" : overall.bestrr.toFixed(3),
                    overall.nBestrr,
                ],
                [metric("ndcg"), overall.ndcg.toFixed(3), overall.n],
            ],
        ),
        "",
        "### By category",
        "",
        `> Unweighted - a category's mean is what it is. The \`weight\` column is
         the share it contributed to \`Overall\` above.`.replace(/\s+/g, " "),
        "",
        table(
            [
                "category",
                metric("weight"),
                metric("n"),
                metric("success"),
                metric("mrr"),
                metric("recall"),
                metric("rbp"),
                metric("bestrr"),
                metric("ndcg"),
            ],
            Object.entries(byCategory)
                .sort(([a], [b]) => a.localeCompare(b))
                .map(([cat, rs]) => {
                    // Cluster gold sets move Recall, RBP and BestRR, not
                    // Success/MRR, so a category is unreadable without them all.
                    const rbps = rs.filter((r) => r.rbp !== null);
                    const ords = rs.filter((r) => r.bestrr !== null);
                    return [
                        cat,
                        weights[cat].toFixed(2),
                        String(rs.length),
                        mean(rs.map((r) => r.success)).toFixed(3),
                        mean(rs.map((r) => r.mrr)).toFixed(3),
                        mean(rs.map((r) => r.recall)).toFixed(3),
                        rbps.length
                            ? `${mean(rbps.map((r) => r.rbp)).toFixed(3)} (n=${rbps.length})`
                            : "-",
                        ords.length
                            ? `${mean(ords.map((r) => r.bestrr)).toFixed(3)} (n=${ords.length})`
                            : "-",
                        mean(rs.map((r) => r.ndcg)).toFixed(3),
                    ];
                }),
        ),
        "",
    ];
}

// Combined per-query table with a `track` column so a weak `pkg` row sits next
// to its `opt` sibling for the same query.
const perQuery = [
    ...pkgResults.map((r) => ({ track: "pkg", ...r })),
    ...optResults.map((r) => ({ track: "opt", ...r })),
].sort((a, b) => a.id.localeCompare(b.id) || a.track.localeCompare(b.track));

const lines = [
    "# Relevance benchmark: frontend query vs deployed ES",
    "",
    `> Index: \`${INDEX}\`, k=${K}. Metric definitions are in the footnotes.`,
    "",
    ...section("Packages", pkgResults, WEIGHTS.packages),
    ...section("Options", optResults, WEIGHTS.options),
    "<details>",
    "<summary>Per-query results</summary>",
    "",
    "> `matched` is the size of the match set, and a `+` means ES stopped counting.",
    "",
    table(
        [
            "id",
            "track",
            "q",
            "category",
            "success",
            "mrr",
            "RBP",
            "BestRR",
            "nDCG",
            "matched",
            "top-3 ranked",
        ],
        perQuery.map((r) => [
            r.id,
            r.track,
            r.q,
            r.category,
            r.success.toFixed(0),
            r.mrr.toFixed(3),
            r.rbp === null ? "-" : r.rbp.toFixed(3),
            r.bestrr === null ? "-" : r.bestrr.toFixed(3),
            r.ndcg.toFixed(3),
            r.matched + (r.matchedExact ? "" : "+"),
            r.ranked.slice(0, 3).join(", "),
        ]),
    ),
    "",
    "</details>",
    "",
    ...FOOTNOTES,
];

console.log(lines.join("\n"));
