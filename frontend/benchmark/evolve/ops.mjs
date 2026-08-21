/**
 * The moves a search can make on a query shape.
 *
 * Every operator here rewrites one site and leaves the rest of the genome
 * alone, and every one of them lands inside the grammar - a mutation cannot
 * point a clause at a field the track does not have, or set a `tie_breaker`
 * outside `0..1`, because those values are drawn from `grammar.mjs` rather than
 * arrived at arithmetically. That matters more than it sounds: `QueryShape`
 * clamps on the way in, so an out-of-range draw would not fail, it would
 * silently become a different genome than the one being scored.
 *
 * The mix is deliberately weighted towards small moves. A boost perturbation is
 * a step along a smooth surface and usually pays; replacing a subtree is a jump
 * that usually does not, but is the only way out of a local optimum. Structural
 * moves are the minority for that reason, not because they are less useful.
 */

import {
    ANALYZERS,
    BOOST_SIGMA,
    FUZZINESS,
    GLUES,
    MULTI_MATCH_TYPES,
    OPERATORS,
    TRACKS,
    clampBoost,
    clampUnit,
    clone,
    containers,
    drawBoost,
    drawClause,
    drawMsm,
    drawRankFeatureFn,
    drawRescore,
    drawTerm,
    gaussian,
    pick,
    repair,
    round,
    sites,
} from "./grammar.mjs";

/**
 * A shape with one thing about it changed.
 *
 * Operators that find no site to work on return the genome untouched rather
 * than failing - a shape with no `rank_feature` clause has no pivot to nudge -
 * and the caller retries, so a rare operator does not stall the generation.
 */
export function mutate(rng, track, shape) {
    const next = clone(shape);
    for (let attempt = 0; attempt < 8; attempt++) {
        if (pickOperator(rng)(rng, track, next)) break;
    }
    return repair(next);
}

function pickOperator(rng) {
    // Cumulative weights, smallest moves first.
    const roll = rng();
    if (roll < 0.3) return perturbBoost;
    if (roll < 0.45) return flipEnum;
    if (roll < 0.55) return changeTerm;
    if (roll < 0.63) return swapField;
    if (roll < 0.71) return toggleOption;
    if (roll < 0.79) return addClause;
    if (roll < 0.87) return deleteClause;
    if (roll < 0.94) return replaceSubtree;
    return toggleRescore;
}

// -- NUMERIC ----------------------------------------------------------------

/**
 * Nudge one boost by a log-normal step.
 *
 * Multiplicative because that is how a boost is read: the distance from 1 to 2
 * is the distance from 50 to 100, and an additive step would crawl at the top of
 * the range and thrash at the bottom.
 */
function perturbBoost(rng, track, shape) {
    const holders = [];
    for (const { clause } of sites(shape)) {
        if (clause.boost !== undefined) holders.push([clause, "boost"]);
        if (clause.kind === "multiMatch") {
            clause.fields.forEach((f) => holders.push([f, "boost"]));
        }
        if (clause.kind === "disMax" && clause.tieBreaker !== undefined) {
            holders.push([clause, "tieBreaker"]);
        }
        if (clause.kind === "rankFeature") {
            for (const key of ["pivot", "scalingFactor", "exponent"]) {
                if (clause.fn[key] !== undefined) holders.push([clause.fn, key]);
            }
        }
    }
    if (shape.rescore) holders.push([shape.rescore, "weight"]);
    if (holders.length === 0) return false;

    const [owner, key] = pick(rng, holders);
    const scaled = owner[key] * Math.exp(BOOST_SIGMA * gaussian(rng));
    // `tieBreaker` and a sigmoid `exponent` are fractions; everything else is a
    // boost, and the two have different ceilings.
    owner[key] =
        key === "tieBreaker" || key === "exponent"
            ? clampUnit(scaled)
            : clampBoost(scaled);
    return true;
}

// -- CATEGORICAL ------------------------------------------------------------

/** Flip one enum to a different member of its own domain. */
function flipEnum(rng, track, shape) {
    const choices = [];
    for (const { clause } of sites(shape)) {
        if (clause.kind === "multiMatch") {
            choices.push([clause, "type", MULTI_MATCH_TYPES]);
        }
        if (clause.analyzer !== undefined) choices.push([clause, "analyzer", ANALYZERS]);
        if (clause.operator !== undefined) choices.push([clause, "operator", OPERATORS]);
        if (clause.fuzziness !== undefined) choices.push([clause, "fuzziness", FUZZINESS]);
        if (clause.term?.kind === "glued") choices.push([clause.term, "glue", GLUES]);
        if (clause.kind === "term" || clause.kind === "prefix" || clause.kind === "wildcard") {
            choices.push([clause, "kind", ["term", "prefix", "wildcard"]]);
        }
    }
    if (choices.length === 0) return false;

    const [owner, key, domain] = pick(rng, choices);
    const others = domain.filter((value) => value !== owner[key]);
    if (others.length === 0) return false;
    owner[key] = pick(rng, others);
    return true;
}

/** Change how one clause derives its text from the query. */
function changeTerm(rng, track, shape) {
    const holders = sites(shape).filter(({ clause }) => clause.term !== undefined);
    if (holders.length === 0) return false;
    const { clause } = pick(rng, holders);
    clause.term = drawTerm(rng, track, { wildcard: clause.kind === "wildcard" });
    return true;
}

/** Point one clause at a different field of the same kind class. */
function swapField(rng, track, shape) {
    const pool = TRACKS[track];
    const holders = [];
    for (const { clause } of sites(shape)) {
        switch (clause.kind) {
            case "multiMatch":
                clause.fields.forEach((f) => holders.push([f, "field", pool.analyzed]));
                break;
            case "match":
                holders.push([clause, "field", pool.analyzed]);
                break;
            case "term":
            case "prefix":
            case "wildcard":
                holders.push([clause, "target", pool.keyword]);
                break;
            case "rankFeature":
                holders.push([clause, "field", pool.rankFeature]);
                break;
        }
    }
    if (shape.rescore) holders.push([shape.rescore.fn, "field", pool.docValue]);
    if (holders.length === 0) return false;

    const [owner, key, domain] = pick(rng, holders);
    const others = domain.filter((value) => value !== owner[key]);
    if (others.length === 0) return false;
    owner[key] = pick(rng, others);
    return true;
}

/**
 * Add or remove one optional parameter.
 *
 * Elasticsearch's defaults are not neutral - leaving `operator` off is not the
 * same as setting it to `or` in every context - so whether a parameter is
 * present at all is a dimension of the search, not just its value.
 */
function toggleOption(rng, track, shape) {
    const holders = [];
    for (const { clause } of sites(shape)) {
        switch (clause.kind) {
            case "multiMatch":
            case "match":
                holders.push([clause, "analyzer", () => pick(rng, ANALYZERS)]);
                holders.push([clause, "fuzziness", () => pick(rng, FUZZINESS)]);
                holders.push([clause, "operator", () => pick(rng, OPERATORS)]);
                holders.push([clause, "prefixLength", () => Math.floor(rng() * 4)]);
                holders.push([clause, "minimumShouldMatch", () => drawMsm(rng)]);
                holders.push([clause, "boost", () => drawBoost(rng)]);
                break;
            case "bool":
                holders.push([clause, "minimumShouldMatch", () => drawMsm(rng)]);
                holders.push([clause, "boost", () => drawBoost(rng)]);
                break;
            case "disMax":
                holders.push([clause, "tieBreaker", () => round(rng())]);
                holders.push([clause, "boost", () => drawBoost(rng)]);
                break;
            case "term":
            case "prefix":
            case "wildcard":
                holders.push([clause, "caseInsensitive", () => true]);
                holders.push([clause, "boost", () => drawBoost(rng)]);
                break;
            case "rankFeature":
                holders.push([clause, "boost", () => drawBoost(rng)]);
                holders.push([clause, "fn", () => drawRankFeatureFn(rng)]);
                break;
        }
    }
    holders.push([shape, "minimumShouldMatch", () => drawMsm(rng)]);
    if (holders.length === 0) return false;

    const [owner, key, draw] = pick(rng, holders);
    // `fn` is not optional on a `rank_feature`, so toggling it means redrawing.
    if (key === "fn") owner[key] = draw();
    else if (owner[key] === undefined) owner[key] = draw();
    else delete owner[key];
    return true;
}

// -- STRUCTURAL -------------------------------------------------------------

/** Add a freshly drawn clause to a `bool` or a `dis_max`. */
function addClause(rng, track, shape) {
    const target = pick(rng, containers(shape));
    (target.clause[target.list] ??= []).push(drawClause(rng, track, 1));
    return true;
}

/**
 * Remove one clause, unless removing it would leave something invalid.
 *
 * A `bool` needs one of its three lists non-empty, a `dis_max` needs at least
 * one query, and the shape itself needs a non-empty `must` - so the ones that
 * cannot be removed are simply not offered.
 */
function deleteClause(rng, track, shape) {
    const removable = [];
    for (const { clause, list } of containers(shape)) {
        const children = clause[list] ?? [];
        if (children.length === 0) continue;
        if (children.length === 1) {
            if (clause === shape && list === "must") continue;
            if (clause.kind === "disMax") continue;
            if (
                clause.kind === "bool" &&
                clause.must.length + clause.should.length + clause.mustNot.length === 1
            ) {
                continue;
            }
        }
        children.forEach((_, i) => removable.push({ clause, list, i }));
    }
    if (removable.length === 0) return false;
    const { clause, list, i } = pick(rng, removable);
    clause[list].splice(i, 1);
    return true;
}

/** Replace one clause wholesale, which is the only move that crosses a valley. */
function replaceSubtree(rng, track, shape) {
    const all = sites(shape);
    if (all.length === 0) return false;
    pick(rng, all).replace(drawClause(rng, track, 2));
    return true;
}

function toggleRescore(rng, track, shape) {
    if (shape.rescore) delete shape.rescore;
    else shape.rescore = drawRescore(rng, track);
    return true;
}

// -- CROSSOVER --------------------------------------------------------------

/**
 * A child of two parents: `a`, with one of its clauses replaced by one of `b`'s.
 *
 * Subtree crossover rather than uniform, because a query shape's meaning is in
 * its branches - a `should` list of well-tuned clauses is a unit worth
 * inheriting whole, and splicing at the parameter level would take it apart. The
 * splice point is kind-agnostic since any clause can stand where any other does.
 */
export function crossover(rng, a, b) {
    const child = clone(a);
    const into = sites(child);
    const from = sites(b);
    if (into.length === 0 || from.length === 0) return child;
    pick(rng, into).replace(clone(pick(rng, from).clause));
    return repair(child);
}
