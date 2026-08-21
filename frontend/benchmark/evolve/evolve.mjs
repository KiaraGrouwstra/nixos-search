#!/usr/bin/env node
/**
 * Search for a better query shape.
 *
 * Usage:
 *   node benchmark/evolve/evolve.mjs --track packages|options [--pop <n>]
 *       [--gens <n>] [--hours <h>] [--seed <n>] [--out <path>] [--index <name>]
 *       [--cache <path>] [--msearch <n>] [--resume]
 *
 * A generational EA with tournament selection. The genome is a
 * `Search.QueryShape` shape as JSON; the fitness is the benchmark's own metrics
 * over the benchmark's own curated queries; the champion is a shape that can be
 * pasted into `Query.elm`.
 *
 * Three things about the setup matter more than the algorithm:
 *
 * **It starts from the incumbent.** Generation 0 is the shape the app ships
 * with, mutants of it, and a handful of random draws for diversity. So the
 * search cannot report an improvement it did not make - the incumbent is in the
 * population, and if nothing beats it, it wins.
 *
 * **It is scored through Elm.** A candidate becomes a request body by going
 * through `Search.QueryShape.decoder` and `Search.Query`, the same path the
 * browser takes. What is being tuned is what would ship, not a model of it.
 *
 * **It is judged on queries it never saw.** 351 curated queries against a search
 * with dozens of movable parameters will overfit, so each category is split
 * 70/30 and the search only ever selects on the 70. The 30 is scored every
 * generation and never selected on, which makes the gap between the two curves
 * readable as it opens. A champion that wins on train and not on test is not a
 * champion.
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";

import { openCache } from "../lib/cache.mjs";
import { esClient, esConfigFromEnv } from "../lib/es.mjs";
import { WEIGHTS, checkWeights } from "../lib/weights.mjs";
import { bootWorker } from "../lib/worker.mjs";
import { canonical, drawShape, makeRng, nodeCount } from "./grammar.mjs";
import { makeFitness, splitQueries } from "./fitness.mjs";
import { crossover, mutate } from "./ops.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const BENCHMARK_DIR = resolve(__dirname, "..");

const { values: args } = parseArgs({
    args: process.argv.slice(2),
    options: {
        track: { type: "string" },
        pop: { type: "string", default: "60" },
        gens: { type: "string", default: "200" },
        hours: { type: "string" },
        seed: { type: "string", default: "1" },
        out: { type: "string" },
        index: { type: "string" },
        cache: { type: "string" },
        msearch: { type: "string", default: "20" },
        k: { type: "string", default: "10" },
        resume: { type: "boolean", default: false },
    },
});

const TRACK = args.track;
if (TRACK !== "packages" && TRACK !== "options") {
    throw new Error("--track must be `packages` or `options`");
}

// An alias moves when a new nixpkgs evaluation lands, and a fitness function
// that changes underneath a running search is not one. The index is named.
if (!args.index) {
    throw new Error("--index is required: a search against a moving alias means nothing");
}

const POP = parseInt(args.pop, 10);
const GENS = parseInt(args.gens, 10);
const K = parseInt(args.k, 10);
const SEED = parseInt(args.seed, 10);
const ELITES = 2;
const TOURNAMENT = 3;
const CROSSOVER_RATE = 0.3;
const RANDOM_SEEDS = Math.min(6, Math.max(0, POP - ELITES - 1));
const DEADLINE = args.hours ? Date.now() + parseFloat(args.hours) * 3600_000 : Infinity;
const OUT = resolve(args.out ?? join(__dirname, `champion-${TRACK}.json`));

const log = (message) => console.error(`[evolve:${TRACK}] ${message}`);

// -- SETUP ------------------------------------------------------------------

const queries = JSON.parse(
    readFileSync(join(BENCHMARK_DIR, `queries-${TRACK}.json`), "utf8"),
);
const weights = WEIGHTS[TRACK];
checkWeights(TRACK, queries, weights);

// The split is drawn from its own generator, so the same `--seed` splits the
// same way at any population size and two runs stay comparable.
const { train, test } = splitQueries(queries, makeRng(SEED ^ 0x5f5f5f5f));
log(`${queries.length} queries: ${train.length} train, ${test.length} test`);

const rng = makeRng(SEED);
const worker = bootWorker({ label: `evolve-${TRACK}`, log });
const es = esClient({ ...esConfigFromEnv(), index: args.index, log: () => {} });
const cache = args.cache ? openCache(args.cache) : null;

const common = { worker, es, cache, track: TRACK, weights, k: K, batch: parseInt(args.msearch, 10) };
const onTrain = makeFitness({ ...common, queries: train });
const onTest = makeFitness({ ...common, queries: test });

const incumbent = (await worker.defaultShapes())[TRACK];
const incumbentTrain = await onTrain.evaluate(incumbent);
const incumbentTest = await onTest.evaluate(incumbent);
log(
    `incumbent: train ${fmt(incumbentTrain)} | test ${fmt(incumbentTest)} | ${nodeCount(incumbent)} nodes`,
);

// The floor is the incumbent's own reach on each split, so nothing wins by
// answering fewer queries than the shape it would replace.
const trainFloor = incumbentTrain.success;
const testFloor = incumbentTest.success;

// -- POPULATION -------------------------------------------------------------

/**
 * Generation 0: the incumbent, mutants of it, and a few shapes from nowhere.
 *
 * Mutants of the incumbent are where the immediate gains are - the shape is
 * already good and its neighbourhood is unexplored. The random draws are
 * insurance against that neighbourhood being a bowl: they are almost all bad,
 * but they carry structure the incumbent cannot reach by single mutations, and
 * crossover can lift a branch out of one without inheriting the rest.
 */
function seedPopulation() {
    const population = [incumbent];
    while (population.length < POP - RANDOM_SEEDS) {
        population.push(mutate(rng, TRACK, incumbent));
    }
    while (population.length < POP) {
        population.push(drawShape(rng, TRACK));
    }
    return population;
}

/** Best of `TOURNAMENT` random draws, which is selection pressure you can tune. */
function tournament(scored) {
    let best = null;
    for (let i = 0; i < TOURNAMENT; i++) {
        const pick = scored[Math.floor(rng() * scored.length)];
        if (best === null || pick.train.fitness > best.train.fitness) best = pick;
    }
    return best;
}

/**
 * Score a whole generation, reusing the score of anything already seen.
 *
 * Elites survive unchanged and mutation frequently lands back on a shape that
 * has already been evaluated, so the same genome recurs constantly. Hashing the
 * canonical form catches those - including two genomes that differ only in key
 * order - and each one costs a batch of Elasticsearch queries, so it is worth
 * catching.
 */
async function scoreGeneration(population, seen) {
    const scored = [];
    for (const shape of population) {
        const key = canonical(shape);
        if (!seen.has(key)) {
            seen.set(key, {
                shape,
                train: await onTrain.evaluate(shape),
                test: await onTest.evaluate(shape),
            });
        }
        scored.push(seen.get(key));
    }
    return scored;
}

// -- RUN --------------------------------------------------------------------

const history = [];
const seen = new Map();
let population = seedPopulation();
let champion = { shape: incumbent, train: incumbentTrain, test: incumbentTest };
let generation = 0;

if (args.resume && existsSync(OUT)) {
    const saved = JSON.parse(readFileSync(OUT, "utf8"));
    population = saved.population ?? population;
    champion = { shape: saved.shape, ...saved.champion };
    history.push(...(saved.history ?? []));
    generation = history.length;
    log(`resumed at generation ${generation} from ${OUT}`);
}

for (; generation < GENS; generation++) {
    if (Date.now() > DEADLINE) {
        log(`time budget reached at generation ${generation}`);
        break;
    }

    const scored = await scoreGeneration(population, seen);
    scored.sort((a, b) => b.train.fitness - a.train.fitness);

    // The best *admissible* individual, not simply the best one: a shape below
    // the incumbent's reach may top the population and still not be a champion.
    const best = scored.find((c) => onTrain.passesFloor(c.train, trainFloor)) ?? scored[0];
    if (best.train.fitness > champion.train.fitness) champion = best;

    // Metrics only, not shapes: the curve is what a run is read from, and 200
    // generations of two genomes apiece would bury it.
    const median = scored[scored.length >> 1].train.fitness;
    history.push({
        generation,
        train: best.train,
        test: best.test,
        median,
        championTrain: champion.train.fitness,
        championTest: champion.test.fitness,
        evaluated: seen.size,
    });
    log(
        `gen ${String(generation).padStart(3)} | best ${fmt(best.train)} | test ${fmt(best.test)} | median ${median.toFixed(4)} | ${seen.size} evaluated`,
    );
    checkpoint(population);

    // Elites carry the top of the population forward untouched, so the best
    // shape found can never be lost to an unlucky generation.
    const next = scored.slice(0, ELITES).map((c) => c.shape);
    while (next.length < POP) {
        const parent = tournament(scored);
        const child =
            rng() < CROSSOVER_RATE
                ? crossover(rng, parent.shape, tournament(scored).shape)
                : mutate(rng, TRACK, parent.shape);
        next.push(child);
    }
    population = next;
}

// -- RESULT -----------------------------------------------------------------

/**
 * The accept condition, and the whole point of the held-out split.
 *
 * A champion has to beat the incumbent on queries the search never selected on.
 * Winning on train alone means the search found the gold set's idiosyncrasies,
 * not a better ranking, and that is the failure this is here to catch.
 */
const moved = canonical(champion.shape) !== canonical(incumbent);
const accepted =
    moved &&
    champion.test.fitness > incumbentTest.fitness &&
    onTest.passesFloor(champion.test, testFloor);

checkpoint(population);
log("");
log(`incumbent train ${fmt(incumbentTrain)} | test ${fmt(incumbentTest)}`);
log(`champion  train ${fmt(champion.train)} | test ${fmt(champion.test)}`);
log(`nodes ${nodeCount(incumbent)} -> ${nodeCount(champion.shape)}`);
log(
    accepted
        ? `ACCEPTED: champion wins on held-out queries. ${OUT}`
        : `REJECTED: no held-out win, so the incumbent stands. ${OUT}`,
);

cache?.close();
worker.cleanup();
process.exitCode = accepted ? 0 : 1;

// -- HELPERS ----------------------------------------------------------------

/** Everything a later run needs to resume, and a human needs to judge. */
function checkpoint(population) {
    mkdirSync(dirname(OUT), { recursive: true });
    writeFileSync(
        OUT,
        `${JSON.stringify(
            {
                track: TRACK,
                seed: SEED,
                index: es.index,
                pop: POP,
                generations: history.length,
                incumbent: { shape: incumbent, train: incumbentTrain, test: incumbentTest },
                champion: { train: champion.train, test: champion.test },
                shape: champion.shape,
                history,
                population,
            },
            null,
            2,
        )}\n`,
    );
}

function fmt(score) {
    if (score.rejected) return "rejected";
    return `fit ${score.fitness.toFixed(4)} ndcg ${score.ndcg.toFixed(4)} rbp ${(score.rbp ?? 0).toFixed(4)} succ ${score.success.toFixed(4)}`;
}
