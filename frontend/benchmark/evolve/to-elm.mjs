#!/usr/bin/env node
/**
 * Render a champion shape as the Elm literal that goes into `Query.elm`.
 *
 * Usage:
 *   node benchmark/evolve/to-elm.mjs <champion.json> [--name defaultPackagesShape]
 *
 * The search's output is JSON and the app's input is Elm, so something has to
 * cross that gap. Doing it by hand is exactly the transcription error this whole
 * exercise exists to remove, so it is done here - and then checked, because a
 * generator is only trustworthy if something disagrees with it when it is wrong.
 * `check-shape.mjs --shape <champion.json>` renders both the committed JSON and
 * the Elm literal to request bodies and asserts they match, which is what makes
 * the tables below safe to keep in JavaScript.
 *
 * The output is deliberately a plain literal rather than a rebuild of
 * `Query.elm`'s helpers. A champion is whatever the search found; expressing it
 * through `crossFieldsClause` and friends would mean the helpers had to still
 * fit, and when they do not the temptation is to round the champion off until
 * they do.
 */

import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";

const { values: args, positionals } = parseArgs({
    args: process.argv.slice(2),
    allowPositionals: true,
    options: { name: { type: "string" } },
});

if (positionals.length !== 1) {
    throw new Error("usage: to-elm.mjs <champion.json>|- [--name <function>]");
}

// `-` reads stdin, so a shape can be piped in without being written down first.
const saved = JSON.parse(readFileSync(positionals[0] === "-" ? 0 : positionals[0], "utf8"));
const shape = saved.shape ?? saved;
const name =
    args.name ??
    (saved.track === "options" ? "defaultOptionsShape" : "defaultPackagesShape");

// -- NAME TABLES ------------------------------------------------------------
//
// The Elasticsearch name of every field is what the genome carries, because
// that is the name a human reads in a body. Elm carries constructors. These are
// the two directions of the same table; `Search.QueryShape` holds the other one.

/** Subfield suffix -> the `PathSub` / `EdgeSub` naming it. */
const PATH_SUBS = {
    "": "PathBase",
    ".edge": "PathEdge",
    ".attr_path": "AttrPath",
    ".attr_path_reverse": "AttrPathReverse",
    ".*": "PathAll",
};

const EDGE_SUBS = { "": "EdgeBase", ".edge": "Edge", ".*": "EdgeAll" };

const PATH_FIELDS = { package_attr_name: "PackageAttrName", option_name: "OptionName" };

const EDGED_FIELDS = {
    package_pname: "PackagePname",
    package_programs: "PackagePrograms",
    package_mainProgram: "PackageMainProgram",
    package_attr_set: "PackageAttrSet",
    package_description: "PackageDescription",
    package_longDescription: "PackageLongDescription",
    option_description: "OptionDescription",
    service_package: "ServicePackage",
    service_packages: "ServicePackages",
};

const PLAIN_FIELDS = { flake_name: "FlakeName", flake_description: "FlakeDescription" };

const PATH_KW_SUBS = {
    "": "KwBase",
    ".attr_path": "KwAttrPath",
    ".attr_path_reverse": "KwAttrPathReverse",
    ".edge": "KwEdge",
};

const PATH_KW = { package_attr_name: "KwAttrName", option_name: "KwOptionName" };

const PLAIN_KW = {
    package_pname: "KwPname",
    package_programs: "KwPrograms",
    package_mainProgram: "KwMainProgram",
    package_attr_set: "KwAttrSet",
    service_package: "KwServicePackage",
    service_packages: "KwServicePackages",
};

const RANK_FEATURE_FIELDS = {
    package_dep_count: "PackageDepCount",
    package_repology_repos: "PackageRepologyRepos",
};

const DOC_VALUE_FIELDS = {
    package_attr_name: "DocPackageAttrName",
    option_name: "DocOptionName",
    package_pname: "DocPackagePname",
    package_mainProgram: "DocPackageMainProgram",
    package_attr_set: "DocPackageAttrSet",
};

const MULTI_MATCH_KINDS = {
    best_fields: "BestFields",
    most_fields: "MostFields",
    cross_fields: "CrossFields",
    phrase: "Phrase",
    phrase_prefix: "PhrasePrefix",
    bool_prefix: "BoolPrefix",
};

const ANALYZERS = {
    whitespace: "Whitespace",
    standard: "Standard",
    simple: "Simple",
    keyword: "KeywordAnalyzer",
    lowercase: "LowercaseAnalyzer",
};

const GLUES = { concat: "Concat", dash: "Dash", underscore: "Underscore" };

const CLAUSE_CONSTRUCTORS = {
    bool: "Bool_",
    disMax: "DisMax",
    constantScore: "ConstantScore",
    multiMatch: "MultiMatch",
    match: "MatchQ",
    term: "TermQ",
    prefix: "PrefixQ",
    wildcard: "WildcardQ",
    rankFeature: "RankFeatureQ",
};

/** Split `package_attr_name.edge` into its field and its suffix. */
function split(full, fields) {
    for (const base of Object.keys(fields)) {
        if (full === base) return [base, ""];
        if (full.startsWith(`${base}.`)) return [base, full.slice(base.length)];
    }
    return [null, null];
}

function fieldRef(full) {
    const [pathBase, pathSub] = split(full, PATH_FIELDS);
    if (pathBase) return `Path ${PATH_FIELDS[pathBase]} ${lookup(PATH_SUBS, pathSub, full)}`;

    const [edgedBase, edgeSub] = split(full, EDGED_FIELDS);
    if (edgedBase) return `Edged ${EDGED_FIELDS[edgedBase]} ${lookup(EDGE_SUBS, edgeSub, full)}`;

    if (full in PLAIN_FIELDS) return `Plain ${PLAIN_FIELDS[full]}`;
    throw new Error(`no FieldRef for ${full}`);
}

function keywordTarget(full) {
    const [base, sub] = split(full, PATH_KW);
    if (base) return `${PATH_KW[base]} ${lookup(PATH_KW_SUBS, sub, full)}`;
    if (full in PLAIN_KW) return PLAIN_KW[full];
    throw new Error(`no KeywordTarget for ${full}`);
}

const lookup = (table, key, context) => {
    if (!(key in table)) throw new Error(`no constructor for "${key}" in ${context}`);
    return table[key];
};

// -- RENDERING --------------------------------------------------------------
//
// Elm is indentation-sensitive, so every renderer below returns a block whose
// first line sits at relative column 0 and whose continuation lines are indented
// relative to that. A caller that drops a block somewhere other than the start
// of a line shifts it with `pad`, which is what keeps the layout right however
// deeply shapes nest. Getting it exactly `elm-format`'s layout is not the job -
// `nix fmt` is the arbiter and will settle the details.

function renderShape(shape, functionName) {
    const body = record([
        ["must", nonempty(shape.must)],
        ["should", list(shape.should.map(clause))],
        ["minimumShouldMatch", maybe(shape.minimumShouldMatch, msm)],
        ["rescore", maybe(shape.rescore, rescore)],
    ]);
    return `${functionName} : Shape\n${functionName} =\n    ${pad(body, 4)}\n`;
}

/** `Nonempty first [ rest ]`, which is how a `must` list is built. */
function nonempty(clauses) {
    if (clauses.length === 0) throw new Error("a Nonempty cannot be empty");
    const [first, ...rest] = clauses;
    const head = `    (${pad(clause(first), 5)})`;
    const tail = `    ${pad(list(rest.map(clause)), 4)}`;
    return `Nonempty\n${head}\n${tail}`;
}

function clause(node) {
    const constructor = lookup(CLAUSE_CONSTRUCTORS, node.kind, "clause");
    return `${constructor} ${pad(clauseBody(node), constructor.length + 1)}`;
}

function clauseBody(node) {
    switch (node.kind) {
        case "bool":
            return record([
                ["must", list(node.must.map(clause))],
                ["should", list(node.should.map(clause))],
                ["mustNot", list(node.mustNot.map(clause))],
                ["minimumShouldMatch", maybe(node.minimumShouldMatch, msm)],
                ["boost", maybe(node.boost, boost)],
            ]);

        case "disMax":
            return record([
                ["tieBreaker", maybe(node.tieBreaker, (v) => `QueryShape.unit ${float(v)}`)],
                ["queries", nonempty(node.queries)],
                ["boost", maybe(node.boost, boost)],
            ]);

        case "constantScore":
            return record([
                ["filter", clause(node.filter)],
                ["boost", boost(node.boost)],
            ]);

        case "multiMatch":
            return record([
                ["kind", lookup(MULTI_MATCH_KINDS, node.type, "multi_match type")],
                ["term", term(node.term)],
                ["analyzer", maybe(node.analyzer, (a) => lookup(ANALYZERS, a, "analyzer"))],
                [
                    "autoGenerateSynonymsPhraseQuery",
                    maybe(node.autoGenerateSynonymsPhraseQuery, bool),
                ],
                ["fuzziness", maybe(node.fuzziness, fuzziness)],
                ["prefixLength", maybe(node.prefixLength, String)],
                ["operator", maybe(node.operator, operator)],
                ["minimumShouldMatch", maybe(node.minimumShouldMatch, msm)],
                ["name", clauseName(node.name)],
                [
                    "fields",
                    list(node.fields.map((f) => `( ${fieldRef(f.field)}, ${boost(f.boost)} )`)),
                ],
                ["boost", maybe(node.boost, boost)],
            ]);

        case "match":
            return record([
                ["field", fieldRef(node.field)],
                ["term", term(node.term)],
                ["analyzer", maybe(node.analyzer, (a) => lookup(ANALYZERS, a, "analyzer"))],
                ["fuzziness", maybe(node.fuzziness, fuzziness)],
                ["prefixLength", maybe(node.prefixLength, String)],
                ["operator", maybe(node.operator, operator)],
                ["minimumShouldMatch", maybe(node.minimumShouldMatch, msm)],
                ["name", clauseName(node.name)],
                ["boost", maybe(node.boost, boost)],
            ]);

        case "term":
        case "prefix":
        case "wildcard":
            return record([
                ["target", keywordTarget(node.target)],
                ["term", term(node.term)],
                ["boost", maybe(node.boost, boost)],
                ["caseInsensitive", maybe(node.caseInsensitive, bool)],
                ["name", clauseName(node.name)],
            ]);

        case "rankFeature":
            return record([
                ["field", lookup(RANK_FEATURE_FIELDS, node.field, "rank_feature field")],
                ["boost", maybe(node.boost, boost)],
                ["name", clauseName(node.name)],
                ["fn", rankFeatureFn(node.fn)],
            ]);

        default:
            throw new Error(`unknown clause kind ${node.kind}`);
    }
}

function term(node) {
    switch (node.kind) {
        case "whole":
            return "Whole";
        case "multiWordWhole":
            return "MultiWordWhole";
        case "glued":
            return `Glued ${lookup(GLUES, node.glue, "glue")}`;
        case "dotted":
            return "Dotted";
        case "dottedPlus":
            return `DottedPlus ${string(node.suffix)}`;
        case "lastWord":
            return "LastWord";
        case "allButLast":
            return "AllButLast";
        case "fixed":
            return `Fixed ${string(node.value)}`;
        case "perWord":
            return `PerWord { variants = ${bool(node.variants)}, wrap = ${
                node.wrap === "surround" ? "Surround" : "PlainWord"
            } }`;
        default:
            throw new Error(`unknown term kind ${node.kind}`);
    }
}

function clauseName(node) {
    switch (node.kind) {
        case "unnamed":
            return "Unnamed";
        case "named":
            return `Named ${string(node.value)}`;
        case "namedWithWords":
            return `NamedWithWords ${string(node.prefix)}`;
        default:
            throw new Error(`unknown name kind ${node.kind}`);
    }
}

function rankFeatureFn(node) {
    switch (node.kind) {
        case "saturation":
            return `Saturation (QueryShape.positive ${float(node.pivot)})`;
        case "log":
            return `Log (QueryShape.positive ${float(node.scalingFactor)})`;
        case "sigmoid":
            return `Sigmoid (QueryShape.positive ${float(node.pivot)}) (QueryShape.unit ${float(node.exponent)})`;
        default:
            throw new Error(`unknown rank_feature function ${node.kind}`);
    }
}

function rescore(node) {
    const field = lookup(DOC_VALUE_FIELDS, node.fn.field, "rescore field");
    return record([
        ["windowSize", String(node.windowSize)],
        ["weight", boost(node.weight)],
        ["fn", `InverseFieldLength ${field}`],
    ]);
}

const msm = (node) =>
    node.kind === "percent" ? `MsmPercent ${node.value}` : `MsmCount ${node.value}`;

const operator = (value) => (value === "and" ? "And" : "Or");

const fuzziness = (value) => (value === "AUTO" ? "Auto" : `(Edits ${parseInt(value, 10)})`);

// Qualified, because `Query.elm` imports `QueryShape` qualified and exposes only
// its types. Bare `boost 3.0` would not resolve there.
const boost = (value) => `QueryShape.boost ${float(value)}`;

const bool = (value) => (value ? "True" : "False");

/** Elm has no implicit int-to-float, so a whole number still needs its `.0`. */
const float = (value) => (Number.isInteger(value) ? `${value}.0` : String(value));

const string = (value) => JSON.stringify(value);

function maybe(value, render) {
    if (value === undefined || value === null) return "Nothing";
    return `Just ${parenthesize(render(value))}`;
}

/**
 * Parenthesize a block that is about to become an argument.
 *
 * An application (`boost 2.0`) needs the parentheses; a bare constructor, a
 * record and a list are already single expressions and reading `Just ({ ... })`
 * is worse than reading `Just { ... }`.
 */
function parenthesize(text) {
    if (/^[({[]/.test(text) || !/[ \n]/.test(text)) return text;
    return `(${pad(text, 1)})`;
}

/**
 * Shift every line but the first, which is already sitting at its column.
 *
 * Blocks are built at relative column 0 and moved into place by whoever puts
 * them somewhere, so this is the only place indentation is decided.
 */
function pad(text, columns) {
    return text.split("\n").join(`\n${" ".repeat(columns)}`);
}

function record(entries) {
    const lines = entries.map(([key, value]) => {
        const head = `${key} = `;
        return head + pad(value, 2 + head.length);
    });
    return `{ ${lines.join("\n, ")}\n}`;
}

function list(items) {
    if (items.length === 0) return "[]";
    return `[ ${items.map((item) => pad(item, 2)).join("\n, ")}\n]`;
}

// Last, so that every table above it is initialized before anything reads one.
console.log(renderShape(shape, name));
