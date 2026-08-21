/**
 * The space of query shapes a search is allowed to explore.
 *
 * `Search.QueryShape` says what a valid shape *is*; this says which valid shapes
 * are worth trying, and it is deliberately the narrower of the two. The enums
 * here are drawn from the live mapping, split by track, because a package shape
 * that reaches for `option_name` is not wrong so much as wasted - the field is
 * absent from package documents, so the clause never matches and the individual
 * carries a dead branch through every generation that inherits it.
 *
 * Nothing here validates. `Search.QueryShape.decoder` does that, on the far side
 * of the port, and a genome it rejects is a bug in this file that fails loudly
 * rather than a query Elasticsearch reads differently than intended.
 *
 * Every generator takes an `rng` - a zero-argument function returning `[0, 1)` -
 * so a run is reproducible from its seed.
 */

// -- VALUE DOMAINS ----------------------------------------------------------
//
// `QueryShape` clamps these on the way in, so a draw outside the range is a
// silently altered genome: the shape that gets scored stops being the shape the
// operators think they are holding, and hill climbing on a clamped parameter
// goes nowhere. Staying inside the clamp is what keeps the two in step.

export const BOOST_MIN = 0.0001;
export const BOOST_MAX = 10000;

/** Where boosts are actually useful, as opposed to merely representable. */
export const BOOST_DRAW = { min: 0.1, max: 1000 };

/** Log-normal sigma for a boost perturbation: about +-35% per step. */
export const BOOST_SIGMA = 0.3;

export const PIVOT_DRAW = { min: 1, max: 10000 };

// -- ENUMS ------------------------------------------------------------------

export const MULTI_MATCH_TYPES = [
    "best_fields",
    "most_fields",
    "cross_fields",
    "phrase",
    "phrase_prefix",
    "bool_prefix",
];

export const ANALYZERS = ["whitespace", "standard", "simple", "keyword", "lowercase"];

export const OPERATORS = ["and", "or"];

export const FUZZINESS = ["AUTO", "0", "1", "2"];

export const GLUES = ["concat", "dash", "underscore"];

// Elasticsearch documents a fourth, `linear`, which 7.13 added and the deployed
// 7.10.2 rejects outright.
export const RANK_FEATURE_FNS = ["saturation", "log", "sigmoid"];

// -- FIELD POOLS ------------------------------------------------------------
//
// `analyzed` is what `multi_match` and `match` can search; `keyword` is what the
// `term`/`prefix`/`wildcard` family can address; `rankFeature` and `docValue`
// are what their clauses accept. A `.edge` subfield is an edge-ngram, `.*`
// searches a field and all its subfields at once, and `.attr_path` /
// `.attr_path_reverse` only exist on the two attribute-path fields.

const PACKAGE_ANALYZED = [
    "package_attr_name",
    "package_attr_name.edge",
    "package_attr_name.attr_path",
    "package_attr_name.attr_path_reverse",
    "package_attr_name.*",
    "package_pname",
    "package_pname.edge",
    "package_pname.*",
    "package_programs",
    "package_programs.edge",
    "package_programs.*",
    "package_mainProgram",
    "package_mainProgram.edge",
    "package_mainProgram.*",
    "package_attr_set",
    "package_attr_set.edge",
    "package_attr_set.*",
    "package_description",
    "package_description.edge",
    "package_description.*",
    "package_longDescription",
    "package_longDescription.edge",
    "package_longDescription.*",
    "flake_name",
    "flake_description",
];

const PACKAGE_KEYWORD = [
    "package_attr_name",
    "package_attr_name.attr_path",
    "package_attr_name.attr_path_reverse",
    "package_attr_name.edge",
    "package_pname",
    "package_programs",
    "package_mainProgram",
    "package_attr_set",
];

const OPTION_ANALYZED = [
    "option_name",
    "option_name.edge",
    "option_name.attr_path",
    "option_name.attr_path_reverse",
    "option_name.*",
    "option_description",
    "option_description.edge",
    "option_description.*",
    "service_package",
    "service_package.edge",
    "service_package.*",
    "service_packages",
    "service_packages.edge",
    "service_packages.*",
];

const OPTION_KEYWORD = [
    "option_name",
    "option_name.attr_path",
    "option_name.attr_path_reverse",
    "option_name.edge",
    "service_package",
    "service_packages",
];

export const TRACKS = {
    packages: {
        analyzed: PACKAGE_ANALYZED,
        keyword: PACKAGE_KEYWORD,
        // Only package documents carry these, so the option track has no
        // `rank_feature` clause at all rather than a pool of one.
        rankFeature: ["package_dep_count", "package_repology_repos"],
        docValue: [
            "package_attr_name",
            "package_pname",
            "package_mainProgram",
            "package_attr_set",
        ],
    },
    options: {
        analyzed: OPTION_ANALYZED,
        keyword: OPTION_KEYWORD,
        rankFeature: [],
        // `option_name` is the only single-valued keyword an option document is
        // guaranteed to have, so a length rescore on this track has one choice.
        docValue: ["option_name"],
    },
};

/**
 * Which pool entries Elasticsearch indexes as `text` rather than `keyword`.
 *
 * The distinction decides what a clause is allowed to do, not just how well it
 * scores: a phrase query needs position data, which only an analyzed field has.
 * Every subfield in the mapping - `.edge`, `.attr_path`, `.attr_path_reverse` -
 * is text, so `foo.*` is text too, and the bare names below are the text fields
 * that carry prose.
 */
const TEXT_FIELDS = new Set([
    "package_description",
    "package_longDescription",
    "option_description",
    "flake_name",
    "flake_description",
]);

const isText = (field) => field.includes(".") || TEXT_FIELDS.has(field);

/**
 * The literal text a shape is allowed to introduce, per track.
 *
 * A shape may otherwise only search what the user typed, so these two lists are
 * the whole of what a search can invent. They are short because the trick they
 * encode is specific: a user typing `nginx virtual hosts` into the option search
 * is usually after `nginx.virtualHosts.enable`, and the incumbent shape already
 * exploits that with a `dottedPlus` suffix and a `fixed` leaf. Package attribute
 * paths have no equivalent convention, so that track gets separators and nothing
 * else.
 */
const SUFFIXES = {
    packages: ["", ".", "-"],
    options: ["", ".enable", ".enabled", ".package"],
};

const FIXED = {
    packages: [],
    options: ["enable", "enabled", "package"],
};

// -- DRAWS ------------------------------------------------------------------

/**
 * A seeded generator, so `--seed` names a run that can be repeated.
 *
 * Every draw in this module and every operator in `ops.mjs` takes its randomness
 * as an argument rather than reaching for `Math.random`, which is what makes a
 * search reproducible from its seed alone - a champion nobody can reproduce is a
 * number, not a result. This is mulberry32: a 32-bit state, statistically fine
 * for the job and short enough to read.
 */
export function makeRng(seed) {
    let state = seed >>> 0;
    return function rng() {
        state = (state + 0x6d2b79f5) >>> 0;
        let t = state;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

export const pick = (rng, xs) => xs[Math.floor(rng() * xs.length)];

const chance = (rng, p) => rng() < p;

/** Uniform on a log scale, which is how a boost is actually read. */
export function drawBoost(rng, { min, max } = BOOST_DRAW) {
    const value = Math.exp(Math.log(min) + rng() * (Math.log(max) - Math.log(min)));
    return round(value);
}

/** Boosts are read by humans in the committed champion; three digits is plenty. */
export const round = (value) => Number(value.toPrecision(3));

/** A standard normal, for the log-normal boost perturbation. */
export function gaussian(rng) {
    // Box-Muller. `rng()` can return 0, which `log` cannot take.
    const u = 1 - rng();
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * rng());
}

export const clampBoost = (value) =>
    round(Math.min(BOOST_MAX, Math.max(BOOST_MIN, value)));

export const clampUnit = (value) => round(Math.min(1, Math.max(0, value)));

// -- TERM DERIVATIONS -------------------------------------------------------

/**
 * How a clause gets its text out of what the user typed.
 *
 * `surround` wraps each word in `*`, which only means anything to a `wildcard`,
 * so the term drawn for a clause depends on which clause is asking.
 */
export function drawTerm(rng, track, { wildcard = false } = {}) {
    const kinds = [
        "whole",
        "whole",
        "glued",
        "glued",
        "dotted",
        "dottedPlus",
        "lastWord",
        "allButLast",
        "multiWordWhole",
        "perWord",
        ...(FIXED[track].length > 0 ? ["fixed"] : []),
    ];
    switch (pick(rng, kinds)) {
        case "glued":
            return { kind: "glued", glue: pick(rng, GLUES) };
        case "dottedPlus":
            return { kind: "dottedPlus", suffix: pick(rng, SUFFIXES[track]) };
        case "fixed":
            return { kind: "fixed", value: pick(rng, FIXED[track]) };
        case "perWord":
            return {
                kind: "perWord",
                variants: chance(rng, 0.5),
                wrap: wildcard && chance(rng, 0.7) ? "surround" : "plain",
            };
        default:
            return { kind: pick(rng, ["whole", "multiWordWhole", "dotted", "lastWord", "allButLast"]) };
    }
}

const UNNAMED = { kind: "unnamed" };

// -- CLAUSE DRAWS -----------------------------------------------------------

/**
 * A clause drawn from nothing, used for the random half of generation 0 and for
 * the "add a clause" and "replace a subtree" operators.
 *
 * `depth` is a budget rather than a target: compounds are only offered while
 * there is room, so the recursion terminates and a random draw stays small
 * enough to be worth reading. Parsimony pressure does the rest.
 */
export function drawClause(rng, track, depth = 2) {
    const pool = TRACKS[track];
    const leaves = ["multiMatch", "match", "term", "prefix", "wildcard"];
    if (pool.rankFeature.length > 0) leaves.push("rankFeature");
    const kinds = depth > 0 ? [...leaves, "bool", "disMax", "constantScore"] : leaves;

    switch (pick(rng, kinds)) {
        case "bool": {
            // At least one of the three, or `validate` rejects it.
            const must = drawClauses(rng, track, depth - 1, chance(rng, 0.6) ? 1 : 0);
            const should = drawClauses(
                rng,
                track,
                depth - 1,
                must.length === 0 ? 1 + Math.floor(rng() * 2) : Math.floor(rng() * 3),
            );
            const clause = { kind: "bool", must, should, mustNot: [] };
            if (chance(rng, 0.3)) clause.boost = drawBoost(rng);
            return clause;
        }
        case "disMax": {
            const clause = {
                kind: "disMax",
                queries: drawClauses(rng, track, depth - 1, 2),
            };
            if (chance(rng, 0.7)) clause.tieBreaker = clampUnit(rng());
            if (chance(rng, 0.3)) clause.boost = drawBoost(rng);
            return clause;
        }
        case "constantScore":
            return {
                kind: "constantScore",
                filter: drawClause(rng, track, depth - 1),
                boost: drawBoost(rng),
            };
        case "multiMatch": {
            const clause = {
                kind: "multiMatch",
                type: pick(rng, MULTI_MATCH_TYPES),
                term: drawTerm(rng, track),
                fields: drawFields(rng, pool.analyzed),
                name: UNNAMED,
            };
            decorateText(rng, clause);
            return clause;
        }
        case "match": {
            const clause = {
                kind: "match",
                field: pick(rng, pool.analyzed),
                term: drawTerm(rng, track),
                name: UNNAMED,
            };
            decorateText(rng, clause);
            return clause;
        }
        case "rankFeature": {
            const clause = {
                kind: "rankFeature",
                field: pick(rng, pool.rankFeature),
                name: UNNAMED,
                fn: drawRankFeatureFn(rng),
            };
            if (chance(rng, 0.7)) clause.boost = drawBoost(rng);
            return clause;
        }
        default: {
            const kind = pick(rng, ["term", "prefix", "wildcard"]);
            const clause = {
                kind,
                target: pick(rng, pool.keyword),
                term: drawTerm(rng, track, { wildcard: kind === "wildcard" }),
                name: UNNAMED,
            };
            if (chance(rng, 0.8)) clause.boost = drawBoost(rng);
            if (chance(rng, 0.5)) clause.caseInsensitive = true;
            return clause;
        }
    }
}

function drawClauses(rng, track, depth, count) {
    return Array.from({ length: count }, () => drawClause(rng, track, depth));
}

function drawFields(rng, pool) {
    const count = 1 + Math.floor(rng() * 4);
    const chosen = new Set();
    while (chosen.size < count) chosen.add(pick(rng, pool));
    return [...chosen].map((field) => ({ field, boost: drawBoost(rng) }));
}

/** The optional text-matching parameters `multi_match` and `match` share. */
function decorateText(rng, clause) {
    if (chance(rng, 0.3)) clause.analyzer = pick(rng, ANALYZERS);
    if (chance(rng, 0.25)) clause.fuzziness = pick(rng, FUZZINESS);
    if (chance(rng, 0.2)) clause.prefixLength = Math.floor(rng() * 4);
    if (chance(rng, 0.3)) clause.operator = pick(rng, OPERATORS);
    if (chance(rng, 0.2)) clause.minimumShouldMatch = drawMsm(rng);
    if (chance(rng, 0.6)) clause.boost = drawBoost(rng);
}

export function drawMsm(rng) {
    return chance(rng, 0.5)
        ? { kind: "count", value: 1 + Math.floor(rng() * 3) }
        : { kind: "percent", value: 10 * (1 + Math.floor(rng() * 10)) };
}

export function drawRankFeatureFn(rng) {
    switch (pick(rng, RANK_FEATURE_FNS)) {
        case "saturation":
            return { kind: "saturation", pivot: drawBoost(rng, PIVOT_DRAW) };
        case "log":
            return { kind: "log", scalingFactor: drawBoost(rng, PIVOT_DRAW) };
        case "sigmoid":
            return {
                kind: "sigmoid",
                pivot: drawBoost(rng, PIVOT_DRAW),
                exponent: clampUnit(rng()),
            };
        default:
            return { kind: "linear" };
    }
}

export function drawRescore(rng, track) {
    return {
        windowSize: pick(rng, [10, 20, 50, 100, 200]),
        weight: drawBoost(rng),
        fn: {
            kind: "inverseFieldLength",
            field: pick(rng, TRACKS[track].docValue),
        },
    };
}

/** A whole shape from nothing, for the diversity draws in generation 0. */
export function drawShape(rng, track) {
    const shape = {
        must: [drawClause(rng, track, 2)],
        should: drawClauses(rng, track, 2, 1 + Math.floor(rng() * 4)),
    };
    if (chance(rng, 0.2)) shape.minimumShouldMatch = drawMsm(rng);
    if (chance(rng, 0.2)) shape.rescore = drawRescore(rng, track);
    return repair(shape);
}

// -- READING A SHAPE --------------------------------------------------------

/**
 * Every clause in a shape, paired with a setter that puts a replacement back.
 *
 * The operators all work by picking a site and rewriting it, and the sites they
 * can pick differ only in which clauses they accept - so the walk is written
 * once here and filtered there.
 */
export function sites(shape) {
    const found = [];
    const walk = (clause, replace, parent) => {
        found.push({ clause, replace, parent });
        switch (clause.kind) {
            case "bool":
                for (const list of ["must", "should", "mustNot"]) {
                    clause[list].forEach((child, i) =>
                        walk(child, (next) => (clause[list][i] = next), clause),
                    );
                }
                break;
            case "disMax":
                clause.queries.forEach((child, i) =>
                    walk(child, (next) => (clause.queries[i] = next), clause),
                );
                break;
            case "constantScore":
                walk(clause.filter, (next) => (clause.filter = next), clause);
                break;
        }
    };
    for (const list of ["must", "should"]) {
        (shape[list] ?? []).forEach((child, i) =>
            walk(child, (next) => (shape[list][i] = next), null),
        );
    }
    return found;
}

/**
 * Compound clauses a child can be added to or removed from.
 *
 * `constantScore` is not one: its filter is a single clause, so there is nothing
 * to add to and removing the one it has would leave it empty.
 */
export function containers(shape) {
    const out = [];
    for (const { clause } of sites(shape)) {
        if (clause.kind === "bool") {
            out.push({ clause, list: "must" }, { clause, list: "should" });
        } else if (clause.kind === "disMax") {
            out.push({ clause, list: "queries" });
        }
    }
    // The shape's own `must` and `should` are containers too, and the ones most
    // worth reaching, since that is where the incumbent puts its structure.
    out.push({ clause: shape, list: "must" }, { clause: shape, list: "should" });
    return out;
}

/**
 * Nudge a shape off the combinations Elasticsearch rejects at parse time.
 *
 * These are the ones `Search.QueryShape` cannot rule out, because they are not
 * facts about the query language so much as facts about `multi_match`: the type
 * decides which parameters are legal, and the fields decide which types are.
 * All three rules below are what a 7.10.2 cluster answered when asked, not what
 * the documentation implies:
 *
 *   - `cross_fields`, `phrase` and `phrase_prefix` reject `fuzziness` outright,
 *     and `prefix_length` is a fuzzy parameter with nothing to do without it.
 *   - `phrase_prefix` needs every field to be analyzed - a keyword field has no
 *     position data, and one in the list fails the whole clause.
 *   - `phrase` gets away with a keyword field only while no analyzer is named;
 *     naming one turns it into a real phrase query, which then needs positions.
 *
 * Repairing rather than rejecting keeps the move: an operator that flipped a
 * type has found something worth trying, and throwing the individual away over
 * a parameter it did not choose would waste the trial. `fitness` still treats an
 * Elasticsearch rejection as lethal, so anything missed here is caught, just
 * more expensively.
 */
export function repair(shape) {
    for (const { clause } of sites(shape)) {
        if (clause.kind !== "multiMatch") continue;
        if (["cross_fields", "phrase", "phrase_prefix"].includes(clause.type)) {
            delete clause.fuzziness;
            delete clause.prefixLength;
        }
        const analyzed = clause.fields.every(({ field }) => isText(field));
        if (clause.type === "phrase_prefix" && !analyzed) clause.type = "bool_prefix";
        if (clause.type === "phrase" && !analyzed) delete clause.analyzer;
    }
    return shape;
}

/** How big a shape is, which is what parsimony pressure is charged against. */
export function nodeCount(shape) {
    return sites(shape).length + (shape.rescore ? 1 : 0);
}

/**
 * A shape as a stable string, for deduplicating a population.
 *
 * Two genomes that differ only in key order are the same query, and a population
 * that lets them both take a slot is a population doing half the work. Sorting
 * keys makes the hash structural; sorting `multi_match` field lists does not,
 * because Elasticsearch reads that order.
 */
export function canonical(value) {
    if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
    if (value && typeof value === "object") {
        return `{${Object.keys(value)
            .sort()
            .map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`)
            .join(",")}}`;
    }
    return JSON.stringify(value);
}

export const clone = (value) => structuredClone(value);
