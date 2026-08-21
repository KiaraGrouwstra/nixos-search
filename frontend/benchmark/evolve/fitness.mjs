/**
 * What a candidate query shape is worth.
 *
 *     fitness = 0.8 * nDCG@10 + 0.2 * RBP(p=0.8) - parsimony * nodes
 *
 * both terms category-weighted, with a hard floor on `Success@10`.
 *
 * nDCG carries the weight because it prices the whole page against its ideal
 * ordering, which is the thing the benchmark exists to improve. RBP is there for
 * what nDCG cannot see: on a single-gold query nDCG reads 1.000 for `[gold]` and
 * for `[gold, junk, junk]` alike, where RBP separates them 1.000 to 0.410. Two
 * facts about that 0.2 slice are worth keeping in view, and both end up in the
 * commit message rather than being argued away here:
 *
 *   - RBP's denominator is the page actually returned, so a candidate can raise
 *     it by returning *fewer* hits. That is what the `Success@10` floor is for:
 *     a shape that tightens `must` until only certain matches survive scores
 *     well on the queries it still answers and gets rejected outright.
 *   - RBP only reads queries marked `exhaustive`, which is 52 of 138 packages
 *     and 124 of 213 options - so a fifth of the fitness is decided by a subset.
 *
 * Parsimony is a small charge per node. It is not there to save bytes; it is
 * there so that when two shapes score the same, the readable one wins, and so
 * that a branch has to earn its keep rather than merely not hurt.
 *
 * A shape Elasticsearch rejects is lethal rather than zero-scoring. `grammar`'s
 * `repair` heads off the combinations that are known to be rejected, so what
 * lands here is a combination nobody anticipated - and treating it as lethal
 * keeps it out of the population while the run continues.
 */

import { cacheKey } from "../lib/cache.mjs";
import { rankHits, scoreQuery, weightedMean } from "../lib/metrics.mjs";
import { canonical, nodeCount } from "./grammar.mjs";

export const NDCG_WEIGHT = 0.8;
export const RBP_WEIGHT = 0.2;

/** Charged per node, so a 40-node shape gives up 0.008 of a 0..1 blend. */
export const PARSIMONY = 0.0002;

export const LETHAL = {
    fitness: -Infinity,
    ndcg: 0,
    rbp: null,
    success: 0,
    nodes: 0,
    rejected: true,
};

const TRACK_FIELDS = {
    packages: { field: "package_attr_name", prefix: "pkg:" },
    options: { field: "option_name", prefix: "opt:" },
};

/**
 * Build the evaluator a search runs its population through.
 *
 * `queries` is the set to score against - the train split during evolution, the
 * test split when checking a champion has not merely memorized it. Everything
 * else is shared with the report: the same worker renders the bodies, the same
 * client sends them, the same metrics read the pages back.
 */
export function makeFitness({
    worker,
    es,
    cache = null,
    track,
    queries,
    weights,
    k = 10,
    p = 0.8,
    batch = 20,
    parsimony = PARSIMONY,
}) {
    const { field, prefix } = TRACK_FIELDS[track];
    const texts = queries.map((q) => q.q);
    const shapeKey = track === "packages" ? "packages" : "options";

    /**
     * Score one shape, or report it lethal.
     *
     * Bodies are rendered in one round trip through Elm - which is what makes
     * the shape being scored the shape that would ship - and sent in batches,
     * with anything already answered at this index served from the cache.
     */
    async function evaluate(shape) {
        let bodies;
        try {
            bodies = (
                await worker.render(texts, k, { [shapeKey]: shape })
            ).bodies.map((pair) => pair[shapeKey]);
        } catch (error) {
            // `QueryShape.decoder` refused it: a grammar bug, worth hearing
            // about rather than quietly scoring zero forever.
            throw new Error(`shape rejected by QueryShape.decoder: ${error.message}`);
        }

        let pages;
        try {
            pages = await fetchPages(bodies);
        } catch (error) {
            return { ...LETHAL, reason: error.message };
        }

        const rows = queries.map((q, i) => ({
            category: q.category,
            ...scoreQuery(q, pages[i], k, p),
        }));
        const closed = rows.filter((r) => r.rbp !== null);

        const ndcg = weightedMean(rows, weights, (r) => r.ndcg);
        const rbp = weightedMean(closed, weights, (r) => r.rbp);
        const success = weightedMean(rows, weights, (r) => r.success);
        const nodes = nodeCount(shape);

        return {
            fitness:
                NDCG_WEIGHT * ndcg +
                RBP_WEIGHT * (rbp ?? 0) -
                parsimony * nodes,
            ndcg,
            rbp,
            success,
            nodes,
            rejected: false,
        };
    }

    async function fetchPages(bodies) {
        const pages = new Array(bodies.length);
        const misses = [];
        for (const [i, body] of bodies.entries()) {
            const key = cache && cacheKey(es.index, body);
            if (key && cache.has(key)) pages[i] = cache.get(key);
            else misses.push(i);
        }
        for (let at = 0; at < misses.length; at += batch) {
            const slice = misses.slice(at, at + batch);
            const responses = await es.msearch(slice.map((i) => bodies[i]));
            for (const [j, i] of slice.entries()) {
                const ranked = rankHits(responses[j].hits.hits, field, prefix, k);
                pages[i] = ranked;
                if (cache) cache.set(cacheKey(es.index, bodies[i]), ranked);
            }
        }
        return pages;
    }

    return {
        evaluate,

        /**
         * Whether a candidate is allowed to beat the incumbent.
         *
         * The floor is the incumbent's own `Success@10`, so nothing can win by
         * answering fewer queries than the shape it would replace. The margin
         * absorbs the last decimal of floating-point drift and nothing more.
         */
        passesFloor(score, floor) {
            return !score.rejected && score.success >= floor - 1e-9;
        },

        key: canonical,
    };
}

/**
 * Split queries into a train and a test half, deterministically and stratified.
 *
 * 351 curated queries against a search that can move dozens of parameters will
 * overfit, and the only honest answer to "did it really improve" is a set the
 * search never saw. Stratifying by category keeps the mix - and therefore the
 * category weights - meaningful on both sides, which an unstratified split of a
 * set this small would not.
 *
 * The order is the seeded shuffle rather than the file order, so the split does
 * not follow how the queries happened to be written down, and it is stable
 * across runs at the same seed so two runs can be compared.
 */
export function splitQueries(queries, rng, testShare = 0.3) {
    const byCategory = {};
    for (const q of queries) (byCategory[q.category] ??= []).push(q);

    const train = [];
    const test = [];
    for (const category of Object.keys(byCategory).sort()) {
        const members = shuffle(byCategory[category], rng);
        // Round down, so a category small enough to lose its whole weight to
        // rounding keeps its training examples instead.
        const held = Math.floor(members.length * testShare);
        test.push(...members.slice(0, held));
        train.push(...members.slice(held));
    }
    return { train, test };
}

function shuffle(items, rng) {
    const out = [...items];
    for (let i = out.length - 1; i > 0; i--) {
        const j = Math.floor(rng() * (i + 1));
        [out[i], out[j]] = [out[j], out[i]];
    }
    return out;
}
