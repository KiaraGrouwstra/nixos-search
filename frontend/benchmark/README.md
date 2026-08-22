# Relevance benchmark

`run.mjs` scores the frontend's Elasticsearch query - the one `Search/Query.elm`
builds - against the deployed index, over two curated query files:

- `queries-packages.json`, scored against `package_attr_name`
- `queries-options.json`, scored against `option_name`

Run it with `npm --prefix frontend run benchmark`. It prints a markdown report,
or the same numbers as JSON with `--json`; the metric definitions are footnotes
at the bottom of that report, and the query file format is documented at the top
of `run.mjs`.

`run.mjs` is the report. What it reports on is shared with everything else here:
`lib/metrics.mjs` holds every metric, `lib/weights.mjs` the category weights,
`lib/es.mjs` the Elasticsearch client and its `_msearch` batching, `lib/cache.mjs`
an on-disk cache of results keyed by index and body, and `lib/worker.mjs` the
compiled `Benchmark.elm` that turns a query into the body the browser would send.
One definition each, so a search cannot be tuned against a metric the report does
not print.

## The aggregate is weighted by category

Curated queries are not a sample of anything. They were written down rather than
observed, so an unweighted mean answers "how do we do on the mix we happened to
invent", not "how do we do on the mix users actually type" - and those two mixes
are far apart. The curated files were 37:63 packages-to-options where real
traffic is 64:35, and had no attribute-path package queries at all against an
observed 6.2%.

So each `(track, category)` pair carries a weight in `WEIGHTS` in
`lib/weights.mjs`, and
the six `Overall` figures are weighted means over the per-category means. The
`By category` table stays unweighted - a category's mean is what it is - and
carries a `weight` column showing how `Overall` was composed.

Weighting per category rather than per query is what keeps the query files
growable: a category contributes a fixed share split evenly across its members,
so adding a query sharpens that category's estimate without disturbing the mix.
Aim for at least a dozen queries in a category before trusting its row.

## Where the weights come from

`corpus/observed-queries.json` is a dated snapshot of real queries, mined from
shared `search.nixos.org/...?query=` links in public GitHub issues and pull
requests by `corpus/mine.mjs`. Nothing in our own stack records query text: the
cluster is Elasticsearch 7.10.2 OSS, so there is no behavioral-analytics
collection and no query-log index, and the frontend has no tracker. Shared links
are the only public place the text survives.

Re-run the miner when the weights are up for review:

```
GITHUB_TOKEN=$(gh auth token) node frontend/benchmark/corpus/mine.mjs
```

It rewrites the snapshot and prints the shape distribution the `WEIGHTS`
comments cite - a per-track split into `plain` / `dotted` / `cased` /
`versioned` / `multiterm`, plus token counts and a dotted-depth histogram. It is
deliberately not wired into CI: it needs a token, it hits the search rate limit,
and GitHub search is not deterministic. The committed snapshot is what CI-side
readers see.

**The corpus has a bias the weights have to respect.** A shared link is a link
that _worked_ - nobody pastes a search that found nothing. So the corpus can
price the shape mix of successful queries, and it is blind to typos,
misspellings and failed natural-language queries. It cannot be used to argue the
`typo` or `intent` weight down to its observed floor, and those two weights are
set by stated judgement instead. Every entry in `WEIGHTS` says which of the two
it is.

The last snapshot, mined 2026-08-19, holds 1255 queries: 64.4% packages, 34.7%
options, 0.9% flakes. Packages split plain 84.5%, dotted 6.2%, cased 4.8%,
multiterm 2.4%, versioned 2.1%. Options split plain 45.4%, dotted 41.1% (109 at
depth 1, 58 at depth 2, 18 deeper), cased 8.0%, multiterm 5.5%, and 20.6% carry
an uppercase letter somewhere.

The `flakes` track is not benchmarked. At 0.9% of observed queries it is not
worth a curated file yet.

## Categories

A query's `category` is the one axis it exists to exercise. Where a query fits
more than one, the rarer axis wins - an uppercase name is `cased` before it is
`exact`, and a bare last segment is `leaf` before it is `cased`.

Shared across both tracks:

| category    | what it tests                                                    |
| ----------- | ---------------------------------------------------------------- |
| `exact`     | the full name, spelled correctly                                 |
| `prefix`    | a name typed part-way, as the typeahead sees it                  |
| `typo`      | a name misspelled                                                |
| `multiterm` | two or more words                                                |
| `intent`    | a description of the thing rather than its name                  |
| `cased`     | mixed-case input: `MusicFree`, `services.postgresql.enableTCPIP` |

Packages only:

| category    | what it tests                                                      |
| ----------- | ------------------------------------------------------------------ |
| `attrpath`  | an attribute path into a package set: `vimPlugins.nvim-treesitter` |
| `versioned` | a version-suffixed attr name: `nodejs_24`, `lua5_3_compat`         |

Options only:

| category | what it tests                                              |
| -------- | ---------------------------------------------------------- |
| `dotted` | a literal attribute path: `services.paperless.domain`      |
| `scoped` | a module plus the setting inside it: `nginx virtual hosts` |
| `leaf`   | a bare last segment with no path: `systemPackages`         |

Ids are block-allocated per category, so a new category takes a fresh block and
adding a query never renumbers an existing one:

| block  | category    |
| ------ | ----------- |
| `g001` | `exact`     |
| `g100` | `prefix`    |
| `g150` | `typo`      |
| `g200` | `multiterm` |
| `g250` | `intent`    |
| `g300` | `cased`     |
| `g350` | `attrpath`  |
| `g400` | `versioned` |
| `g450` | `dotted`    |
| `g500` | `scoped`    |
| `g550` | `leaf`      |

A query that appears in both files carries the same id in both, which is what
pairs the `pkg` and `opt` rows for one query in the per-query table. Two
different queries must never share an id.

## The query is a value, and it was searched for

`Search/QueryShape.elm` is the ranking half of the Elasticsearch query as a
type: which clauses, over which fields, at which boosts. The envelope around it -
`from`, `size`, `sort`, the aggregations, the `type` and bucket filters, the
`must_not` for negated words - stays in `Search/Query.elm` and is not part of the
shape, matching that module's split between ranking and filtering.

The type is built so that only valid, sensible queries are representable. Fields
are enums drawn from the live mapping, with subfields attached to the field that
has them, so there is no way to name `package_description.attr_path`. Boosts are
a newtype with a clamping constructor, so an out-of-range boost is not
constructible. `DisMax.queries` is non-empty by construction. The query text is a
hole rather than a string - `Whole`, `Glued Dash`, `LastWord`, `DottedPlus
".enable"` and so on - so no clause can be handed a literal the user did not type
except through `Fixed`.

`defaultPackagesShape` and `defaultOptionsShape` in `Search/Query.elm` are what
the app ships with. Neither was chosen by hand: `evolve/` searched for both, and
`evolve/champion-packages.json` and `evolve/champion-options.json` are the
checkpoints they came from.

The packages champion carries a `reverted` list naming three clauses changed
after the search stopped, each measured on its own against the full corpus. Two
moved no metric at all - the search has no gradient toward removing something
inert, so it leaves such clauses lying around - and the third traded 0.0017 RBP
for the 34 ms per query that a `wildcard` over an edge-ngram subfield was
costing. The `asFound` block holds what the search itself reported, so the
edit is visible rather than folded into the champion's own numbers.

- `evolve/grammar.mjs` is the JS mirror of the Elm type - node kinds, their
  parameters, value domains, and the per-track field pool. `QueryShape.decoder`
  is what keeps it honest: a genome the decoder rejects is a grammar bug, and it
  fails loudly rather than scoring badly.
- `evolve/ops.mjs` mutates and crosses over within the grammar.
- `evolve/fitness.mjs` renders candidates through the same Elm the browser runs,
  `_msearch`es them, and scores `0.8 * nDCG@10 + 0.2 * RBP(p=0.8)`,
  category-weighted, minus a parsimony term on node count.
- `evolve/evolve.mjs` runs the search.
- `evolve/to-elm.mjs` renders a champion as the Elm literal to paste back.

```
node benchmark/evolve/evolve.mjs --track packages --index <pinned index> \
    --pop 60 --hours 10 --seed 1 --cache /var/tmp/evolve.ndjson
```

`--index` is required and an alias will not do: a fitness function that changes
underneath a running search is not one. Checkpoints are written every generation
and `--resume` picks one up. `--seed` is enough to repeat a run, since every draw
and every operator takes its randomness as an argument.

**The number to read is the held-out one.** 351 curated queries against a ranking
with dozens of movable parameters will overfit. Each category is split 70/30;
the search only ever selects on the 70, scores the 30 every generation, and
accepts a champion only if it beats the incumbent there too. The exit status says
which happened.

That split is drawn from `--seed`, so two runs seeded differently partition the
queries differently and their fitness numbers cannot be compared to each other -
they are not measured against the same test set. What compares them is the
report, which scores a champion over every curated query against the index the
app really answers from:

```
node benchmark/run.mjs --index <pinned index> --shape evolve/champion-options.json
```

One `--shape` per track, and a track left unnamed keeps the shape the app ships,
so scoring a candidate for one track does not disturb the other's figures. Those
numbers are the generous ones - they include the queries the search selected on -
so they belong beside the held-out figure rather than in place of it.

Two properties of the fitness are worth keeping in mind when reading a result.
RBP's denominator is the page actually returned, so a candidate can raise it by
answering fewer queries - which is what the hard `Success@10` floor, set at the
incumbent's own reach, is there to forbid. And RBP is only defined for
`exhaustive` queries, 52 of 138 packages and 124 of 213 options, so that 0.2
slice is decided by a subset.

## Proving a shape change did not change the query

```
node benchmark/check-shape.mjs --reference HEAD~1
node benchmark/check-shape.mjs --shape benchmark/evolve/champion-packages.json \
    --shape benchmark/evolve/champion-options.json
```

Both compare request bodies byte-for-byte over every curated query, with no
Elasticsearch involved - it is the encoder under test. The first is for
refactoring `Search/Query.elm` or `Search/QueryShape.elm`, where the bodies must
not move at all. The second is the guard against codegen drift: `to-elm.mjs`
transcribes JSON into Elm through hand-maintained name tables, and this is what
fails when a table is wrong or the literal is later edited away from the JSON it
came from.

## Adding a category

1. Add the queries, taking their text from `corpus/observed-queries.json` where
   you can, so the category describes something users do rather than something
   we imagined. Give it a fresh id block.
2. Add its weight to that track's table in `WEIGHTS`, taking the weight back out
   of the categories it is carving from so the table still sums to 1. Say in the
   comment whether the number is observed or judgement.
3. Run the benchmark. `run.mjs` fails up front if a category has no weight, a
   weight has no queries, or a table does not sum to 1.
4. Check the new rows against the live index by hand before trusting them. A
   0.000 in a new category is more often a real ranking finding than a bad gold
   set - `python3Packages.absl-py` returns nothing because the index carries
   only the versioned package sets, and that is worth knowing.
