/**
 * How a ranked page is scored against a curated gold set.
 *
 * These are the definitions the report and the shape search both read from, and
 * that is the point of the module: a search that optimizes a metric the report
 * does not print is optimizing something nobody has agreed to. There is one
 * definition of `nDCG@10` in this repo and both callers use it.
 *
 * Every metric takes a ranked list of ids and returns a number in `0..1`, or
 * `null` where the query makes no claim the metric can read - which drops it
 * from the mean rather than scoring it zero.
 */

/**
 * The gold set as ranked tiers, validated.
 *
 * A tier is a non-empty list of ids tied at that rank, and an id belongs to
 * exactly one of them. Order *between* tiers is a claim the gold set makes;
 * order *within* one is explicitly not.
 */
export function tiers(q) {
    if (!Array.isArray(q.relevant) || q.relevant.length === 0) {
        throw new Error(`${q.id}: "relevant" must be a non-empty list of tiers`);
    }
    const seen = new Set();
    for (const tier of q.relevant) {
        if (!Array.isArray(tier) || tier.length === 0) {
            throw new Error(
                `${q.id}: every tier of "relevant" must be a non-empty list of ids, got ${JSON.stringify(tier)}`,
            );
        }
        for (const id of tier) {
            if (typeof id !== "string") {
                throw new Error(
                    `${q.id}: tier entry ${JSON.stringify(id)} is not a string`,
                );
            }
            if (seen.has(id)) {
                throw new Error(`${q.id}: ${id} appears in more than one tier`);
            }
            seen.add(id);
        }
    }
    return q.relevant;
}

/**
 * The gold set flattened back to a plain set of acceptable answers, which is
 * what the membership metrics ask for.
 */
export function flatRelevant(q) {
    return tiers(q).flat();
}

/**
 * The one answer a user typing this query is most likely after, or `null` where
 * the gold set declines to name one.
 *
 * The top tier holds it whenever that tier holds a single id - including the
 * single-answer case, where with nothing to compare against it is the best
 * answer by definition. A tie at the top states no preference, so there is no
 * ordinal claim to score.
 */
export function bestAnswer(q) {
    const top = tiers(q)[0];
    return top.length === 1 ? top[0] : null;
}

/**
 * The ranked ids on the page, read out of an Elasticsearch response.
 *
 * ES returns hits in score order per index, so no re-sort is needed; the dedup
 * is kept for parity with the previous merged ranker.
 */
export function rankHits(hits, field, prefix, k) {
    const out = [],
        seen = new Set();
    for (const h of hits) {
        const name = h._source?.[field];
        if (!name) continue;
        const id = prefix + name;
        if (seen.has(id)) continue;
        seen.add(id);
        out.push(id);
        if (out.length === k) break;
    }
    return out;
}

export function reciprocalRank(ranked, relevant) {
    const rel = new Set(relevant);
    for (let i = 0; i < ranked.length; i++) {
        if (rel.has(ranked[i])) return 1 / (i + 1);
    }
    return 0;
}

/**
 * Reciprocal rank of the best answer, rather than of the first relevant hit.
 *
 * MRR asks "did we surface something usable", which a cluster gold set answers
 * trivially: on `node`, every `nodejs*` variant is relevant, so MRR reads 1.000
 * whether `nodejs` or `nodejs-slim_26` came first. BestRR asks the ordinal
 * question instead - "did the answer they wanted come first" - and separates
 * those two pages 1.000 to 0.167.
 *
 * It collapses to MRR on a single-answer query, so it only speaks up on the
 * cluster queries it was added for. Returns `null` when the query makes no
 * ordinal claim, which drops it from the mean.
 */
export function bestReciprocalRank(ranked, best) {
    if (best === null) return null;
    const i = ranked.indexOf(best);
    return i === -1 ? 0 : 1 / (i + 1);
}

/**
 * Graded nDCG (Jarvelin & Kekalainen 2002) over the gold set's tiers: a hit in
 * tier `i` of `T` grades `T - i`, and anything off the gold set grades 0.
 *
 * Where BestRR prices one position, this prices the whole page against its
 * ideal ordering, so demoting a variant below the canonical package pays off
 * even when the canonical package was already first. A single-tier query keeps
 * a flat grade of 1 across its gold set, which is ordinary binary nDCG - it
 * still scores, it just states no preference within the set.
 */
export function ndcgAtK(ranked, q, k) {
    const gold = tiers(q);
    const grades = new Map(
        gold.flatMap((tier, i) => tier.map((id) => [id, gold.length - i])),
    );
    const gain = (g, i) => g / Math.log2(i + 2);

    const dcg = ranked
        .slice(0, k)
        .reduce((a, id, i) => a + gain(grades.get(id) ?? 0, i), 0);
    // Tiers are already in descending grade order, so this is the ideal page.
    const idcg = gold
        .flatMap((tier, i) => tier.map(() => gold.length - i))
        .slice(0, k)
        .reduce((a, g, i) => a + gain(g, i), 0);
    return idcg > 0 ? dcg / idcg : 0;
}

export function successAtK(ranked, relevant, k) {
    const rel = new Set(relevant);
    return ranked.slice(0, k).some((id) => rel.has(id)) ? 1 : 0;
}

export function recallAtK(ranked, relevant, k) {
    const rel = new Set(relevant);
    const hits = ranked.slice(0, k).filter((id) => rel.has(id)).length;

    const denom = Math.min(k, rel.size);
    return denom > 0 ? hits / denom : 0;
}

/**
 * Rank-biased precision (Moffat & Zobel 2008), conditioned on the user stopping
 * inside the page we returned.
 *
 * The user model: a user reads rank 1, then moves on to the next rank with
 * probability `p`. So rank `i` is examined with weight `p^(i-1)`.
 *
 *   RBP = sum(p^(i-1) over relevant hits) / sum(p^(i-1) over returned hits)
 *
 * Textbook RBP divides by `1 / (1 - p)`, the weight of an unbounded result
 * list. Dividing by the weight of the hits actually returned conditions the same
 * model on the user stopping inside the page, since
 * `sum(p^(i-1), i=1..n) = (1 - p^n) / (1 - p)`.
 *
 * Properties:
 * - Junk anywhere on the page costs something, discounted by rank.
 * - A page holding fewer than `k` hits is scored on what it returned, so a short
 *   clean page reaches 1.000. A search that optimizes RBP therefore has an
 *   incentive to return fewer hits, which is why `evolve` pairs it with a
 *   `Success@k` floor.
 * - `p` sets how far down the user reads: expected examination depth is
 *   `1 / (1 - p)` results.
 *
 * Requires `"exhaustive": true`, meaning `relevant` enumerates every acceptable
 * answer; otherwise a good-but-unlisted hit scores as noise. Returns `null` when
 * there are no hits, which drops the query from the mean.
 */
export function conditionalRBP(ranked, relevant, p) {
    if (ranked.length === 0) return null;
    const rel = new Set(relevant);
    let num = 0,
        denom = 0;
    for (let i = 0; i < ranked.length; i++) {
        const weight = p ** i;
        denom += weight;
        if (rel.has(ranked[i])) num += weight;
    }
    return num / denom;
}

/**
 * Every metric for one query against one page, which is the row the report
 * prints and the row the fitness function sums.
 */
export function scoreQuery(q, ranked, k, p) {
    const relevant = flatRelevant(q);
    return {
        mrr: reciprocalRank(ranked, relevant),
        success: successAtK(ranked, relevant, k),
        recall: recallAtK(ranked, relevant, k),
        rbp: q.exhaustive ? conditionalRBP(ranked, relevant, p) : null,
        bestrr: bestReciprocalRank(ranked, bestAnswer(q)),
        ndcg: ndcgAtK(ranked, q, k),
    };
}

export function mean(arr) {
    return arr.reduce((a, b) => a + b, 0) / arr.length;
}

/**
 * Each category contributes `weights[category]` to the aggregate, split evenly
 * across its members.
 *
 * Renormalizing by the weight actually present lets the metrics that drop
 * queries (RBP, BestRR) reuse this unchanged: a category that contributes
 * nothing to a metric simply leaves its weight out.
 */
export function weightedMean(rows, weights, pick) {
    const byCategory = {};
    for (const r of rows) {
        (byCategory[r.category] ??= []).push(pick(r));
    }
    let weighted = 0,
        present = 0;
    for (const [category, values] of Object.entries(byCategory)) {
        weighted += weights[category] * mean(values);
        present += weights[category];
    }
    return present > 0 ? weighted / present : null;
}
