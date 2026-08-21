/**
 * What share of the aggregate each query category is worth.
 *
 * Curated queries are not a sample of anything - they were written down, not
 * observed - so an unweighted mean reports how we do on the mix we happened to
 * invent. `corpus/observed-queries.json` holds real queries mined from shared
 * `search.nixos.org/...?query=` links, and `corpus/mine.mjs` prints the shape
 * distribution the numbers below cite. Re-run it when these are up for review.
 *
 * The corpus has a bias the weights have to respect: a shared link is a link
 * that *worked*, so it can price the plain/dotted/cased/versioned mix but is
 * blind to typos and to failed natural-language queries. Where it can see, the
 * weight follows the observation; where it cannot, the weight is judgement and
 * says so.
 *
 * Weighting at the category level rather than per query is what lets the query
 * sets grow: adding a query sharpens its category's estimate without shifting
 * the mix. Each table sums to 1.
 */
export const WEIGHTS = {
    // Observed (n=808): plain 84.5%, dotted 6.2%, cased 4.8%, multiterm 2.4%,
    // versioned 2.1%.
    packages: {
        exact: 0.4, // share of the plain block
        prefix: 0.22, // judgement: every typed search passes through prefix
        // states and the typeahead queries them, but the corpus only ever sees
        // the query that got shared
        typo: 0.1, // judgement: the corpus cannot see these at all
        intent: 0.08, // judgement: a natural-language query that failed is the
        // least likely to be shared and the one we most want to fix
        attrpath: 0.06, // observed 6.2%
        cased: 0.05, // observed 4.8%
        multiterm: 0.05, // observed 2.4%, upweighted alongside `intent`
        versioned: 0.04, // observed 2.1%
    },
    // Observed (n=436): plain 45.4%, dotted 41.1% (depth 1: 109, depth 2: 58,
    // depth 3+: 18), cased 8.0%, multiterm 5.5%. 20.6% carry an uppercase
    // letter somewhere, most of them inside a path.
    options: {
        exact: 0.24, // share of the plain block
        scoped: 0.22, // a module plus the setting inside it - the same shape as
        // the depth-1 end of the dotted block, which is most of it
        dotted: 0.16, // literal paths, the depth-2+ end of that block
        prefix: 0.1, // judgement, as above
        leaf: 0.06, // observed: bare leaf names, e.g. `systemPackages`
        cased: 0.06, // observed: uppercase inside a path
        typo: 0.06, // judgement
        multiterm: 0.05, // observed 5.5%
        intent: 0.05, // judgement
    },
};

/**
 * A category with no weight would silently drop out of the aggregate and a
 * weight with no category would silently renormalize the rest, so both are
 * errors, and both are worth hearing about before a scoring run rather than
 * after it.
 */
export function checkWeights(track, queries, weights) {
    const present = new Set(queries.map((q) => q.category));
    for (const category of [...present].sort()) {
        if (!(category in weights)) {
            throw new Error(
                `${track}: category "${category}" has no weight in WEIGHTS.${track}`,
            );
        }
    }
    for (const category of Object.keys(weights)) {
        if (!present.has(category)) {
            throw new Error(
                `${track}: WEIGHTS.${track}.${category} has no queries`,
            );
        }
    }
    const total = Object.values(weights).reduce((a, b) => a + b, 0);
    if (Math.abs(total - 1) > 1e-6) {
        throw new Error(
            `${track}: WEIGHTS.${track} sums to ${total.toFixed(4)}, not 1`,
        );
    }
}
