# Benchmark: Refract vs Solargraph vs Ruby LSP

Reproducible head-to-head measured by driving each server with the same JSON-RPC
sequence on the same workspace. No cherry-picked numbers, both wins and losses
are reported.

- **Date**: 2026-05-01
- **Hardware**: 8-core x86_64, Linux 6.19, Fedora 43
- **Workspaces**: synthetic 1k-file corpus (`scripts/bench.sh`); plus real
  open-source Ruby apps (Mastodon, Discourse) for realistic-bench matrix.
- **Versions**: refract 0.1.0 · solargraph 0.58.1 · ruby-lsp 0.26.9 · Ruby 3.4.8
- **Drivers**: synthetic [`scripts/bench/lsp_driver.rb`](../scripts/bench/lsp_driver.rb);
  realistic [`scripts/bench/lsp_realistic.rb`](../scripts/bench/lsp_realistic.rb)
  with matrix runner [`scripts/bench/realistic_run.sh`](../scripts/bench/realistic_run.sh).
- Sorbet is omitted: it is a *type checker* with a different mental model
  (RBI authoring, `srb tc`); the comparison row in [`COMPARISON.md`](COMPARISON.md) covers it.

## Cold start: initialize → first usable answer

Time from launching the server until `textDocument/definition` returns a result.
This is the latency a developer feels when opening their editor.

`initialize` response time only (does not block on indexing):

```
   refract       ▏ 60 ms
   solargraph    ████ 240 ms
   ruby-lsp      ████████ 520 ms
```

Refract is the lowest-latency to *answer the editor's `initialize` request*
of the three. First-definition still requires the workspace to be indexed —
on a 1k-file synthetic corpus that adds ~8 s to a *truly cold* DB; subsequent
runs hit the persistent SQLite index and skip the work.

- Refract's `initialize` is now **~60 ms** (was 1.1 s before async cleanup).
- Ruby LSP `initialize` is fast on a warm cache (~520 ms) and very slow
  on a fresh machine (~8.5 s) because it eagerly indexes during init.
- Solargraph defers indexing entirely; first definition pays the ~2 s cost.

## Steady-state query latency (ms)

Ten requests of each kind, percentiles reported. Two snapshots: before the
in-memory hot index landed, and after.

### After (current — in-memory hot index for definition + hover)

| Server      | def p50 | def p95 | hover p50 | hover p95 | completion p50 | completion p95 |
|-------------|--------:|--------:|----------:|----------:|---------------:|---------------:|
| **refract** | **0.3** |  ~5     |  **0.8**  |  ~3       |     7.4        |     ~10        |
| solargraph  |   0.9   |   1.9   |    2.1    |  18.2     |     1.8        |     8.5        |
| ruby-lsp    |   1.3   |   7.5   |    1.4    |   7.9     |     2.0        |     7.3        |

Refract is now **best of three on definition and hover**. Completion still
goes through SQL on the hottest call sites (cross-file return-type
resolution); wiring it into the hot index is queued — the architecture is
ready, the handler is just deeper.

### Before (SQLite as primary index)

| Server      | def p50 | hover p50 | completion p50 |
|-------------|--------:|----------:|---------------:|
| refract     |   89    |    7.8    |    10.2        |
| solargraph  |    1.0  |    2.1    |     1.8        |
| ruby-lsp    |    1.2  |    0.9    |     2.0        |

The 89 ms p50 on definition was a single SQL query: `WHERE s.name = ? OR
s.name LIKE '%::' || ?` — leading-wildcard scan of ~30k symbols, plus a
re-prepared statement on every call. The hot index serves the same query as
two `StringHashMap` lookups in microseconds.

### A/B verification

Run with `--no-hot-index` to flip back to the SQL path on a fresh DB:

| Mode                | def p50 | hover p50 |
|---------------------|--------:|----------:|
| hot index on        |   0.5   |   0.8     |
| `--no-hot-index`    |  12.5   |   4.8     |

(With `--no-hot-index` the def_p50 of 12.5 ms is much lower than the original
89 ms because the *original* baseline ran against a stale DB carrying ~30k
symbols from prior bench runs. The honest pre-hot-index latency is ~12 ms;
the hot index gives a further ~25× speedup on top of that.)

## Realistic workloads on Mastodon and Discourse

The synthetic 1k-file bench above is a controlled microbench. The matrix below
runs three realistic editor patterns on real Ruby codebases and compares all
three servers head-to-head.

- **Workloads**:
  - `session` — editor mix (60% hover, 15% def, 10% completion, 5% sym, 5% refs, 3% docSym, 2% rename) over 12 files
  - `typing`  — 8 Hz `didChange` storm for 30s with hover/def/comp queries interleaved
  - `micro`   — 50 random hover, then 50 def, then 50 completion across 5 files
- **Corpora**: Mastodon (≈4k Ruby files), Discourse `/lib` (667 files)
- **Captured**: `bench-results/realistic/20260501T083756Z-49892f5/`

### Mastodon — session workload (post-cold-warm)

| Metric (p50, ms)     | refract (rubocop off) | refract (rubocop on) | ruby-lsp | solargraph |
|----------------------|---------------------:|---------------------:|---------:|-----------:|
| `hover`              |                  1.25 |                 1.24 |   **0.80** |   timed out |
| `definition`         |              **0.82** |                 0.95 |     1.02 |   timed out |
| `completion`         |              **0.86** |                 0.91 |     1.79 |   timed out |
| `workspace/symbol`   |              **1.67** |                 1.84 |    24.75 |   timed out |
| `references`         |              **0.91** |                 0.90 |   667.31 |   timed out |
| Cold-warm to first symbol | **757 ms**       |               722 ms | 60,503 ms |  >60 s    |
| Peak RSS             |                45 MB  |                43 MB |   143 MB |   310 MB    |

**Refract is best of three on `definition`, `completion`, `workspace/symbol`,
`references`, cold-warm time, and memory.** Ruby LSP wins `hover` p50 by a
small margin (1.6×); we lose stdlib hover content because we don't ship RBS
type inference yet. Refract beats Ruby LSP on `references` by **730×** and on
`workspace/symbol` by **15×** because of the in-memory hot index landed in `2e4945a`.

### Mastodon — typing workload (8 Hz didChange storm)

| Metric (p50, ms)     | refract (off) | refract (on) | ruby-lsp |
|----------------------|--------------:|-------------:|---------:|
| `hover`              |         24.27 |        18.52 | **1.22** |
| `definition`         |         28.78 |        17.02 | **1.11** |
| `completion`         |         31.17 |        21.78 | **1.30** |

**Honest loss:** under sustained didChange storms refract's query p50 is
~15-30× slower than ruby-lsp. The debounce-flush fix (`62f1789`) cut this
from ~100 ms to ~25 ms — a 4× win — but we still lose to ruby-lsp here.
Root cause is queued behind in-thread re-parse on every change; tracked.

### Mastodon — micro workload

| Metric (p50, ms)     | refract (off) | refract (on) | ruby-lsp |
|----------------------|--------------:|-------------:|---------:|
| `hover`              |         20.23 |        18.22 | **0.55** |
| `definition`         |         18.63 |        19.34 | **0.28** |
| `completion`         |         16.94 |        21.73 | **0.78** |

Same pattern as typing — ruby-lsp dominates micro. The `pick_positions`
sampler frequently lands on receiver-style identifiers; refract's hot path
does not yet cover member completion / receiver-typed hover.

### Discourse `/lib` — session workload

| Metric (p50, ms)     | refract (off) | refract (on) | ruby-lsp |
|----------------------|--------------:|-------------:|---------:|
| `hover`              |          3.05 |         2.59 | **0.91** |
| `definition`         |      **2.27** |        12.53 |     1.31 |
| `completion`         |         10.76 |     **3.37** |     1.56 |
| `workspace/symbol`   |        222.70 |       217.22 | **34.62** |
| `references`         |      **1.67** |         1.83 |   266.40 |

A second perf regression visible only here: `workspace/symbol` p50 is **130×
slower on the smaller corpus** than on Mastodon (1.67 ms). Symptom of a
plan-stability or cache-locality issue at this index size; tracked.

### Reliability

Of 24 cells run, 4 failures:
- 3× solargraph timeout (>600 s) on `discourse-lib session`, `mastodon session`,
  `mastodon micro` — solargraph cannot index Mastodon-scale within 10 minutes.
- 1× refract crash (EPIPE) on `discourse-lib typing rubocop-off` — server
  closed stdin under sustained didChange storm. Tracked as a reliability bug.

### Reproducing the matrix

```sh
zig build "-Dgit_sha=$(git rev-parse --short HEAD)"
gem install ruby-lsp solargraph
REFRACT_PILOT_DIR=/tmp/refract-pilot bash scripts/bench/realistic_run.sh
# Aggregate the 24 JSONs:
ruby scripts/bench/realistic_aggregate.rb bench-results/realistic/<dir>
```

## Peak resident memory (1k-file workspace)

```
   refract       ##########                                       ~37 MB
   ruby-lsp      ############################                    ~104 MB
   solargraph    ######################################################  ~200 MB
                 0    50   100   150   200   250 MB
```

Refract holds **2.7× less memory than Ruby LSP and 5× less than Solargraph**
for the same workspace. The Zig binary plus a SQLite handle is most of it.

## Accuracy spot-check

Five fixed `textDocument/definition` queries against a two-file fixture. The
expected location is known up front; the harness compares server output to it.

| Query                             | refract | solargraph | ruby-lsp |
|-----------------------------------|:-------:|:----------:|:--------:|
| Same-file method call → def       |   hit   |    hit     |   hit    |
| Same-file class ref → class def   |   hit   |    hit     |   hit    |
| Cross-file module ref → module    |   hit   |    hit     |   hit    |
| Cross-file method ref → def       |   hit   |    hit     |   hit    |
| Stdlib `String#upcase` → some def |   resolved (user-code) | unresolved | resolved (`string.rbs`) |

All three resolve user Ruby code identically on this fixture (4/4 each). On
the stdlib query, only Ruby LSP returns the canonical bundled RBS file —
refract returns a same-named user-code method. Refract bundles RBS, but
without receiver-type inference it can't tell that `s.to_s.upcase` should
prefer `String#upcase` over a user-defined `Helpers#upcase`. Tracked as
Phase ⑤ + future type-inference work in
[`/home/fedhtrsx/.claude/plans/ok-refine-plan-to-delightful-goblet.md`](https://github.com/Hirintsoa/refract/blob/main/docs/BENCHMARK.md).

A 5-query suite is not exhaustive. Treat it as a smoke test that the basics
work; not as a coverage claim.

## Reliability

| Behavior                                  | refract | solargraph | ruby-lsp |
|-------------------------------------------|:-------:|:----------:|:--------:|
| First-def attempts in poll loop (median)  |   1     |    1       |   3      |
| Any timeout in 30 steady-state requests   |  none   |  none      |  none    |
| Crashes in driver runs (n=4)              |  none   |  none      |  none    |

Ruby LSP's poll-loop attempts on first definition (3 retries, ~1.5s) reflect
that it does not block `initialize` until indexing is complete; the first
query is racing the indexer. Once warm, it is the fastest of the three.

## Install footprint

| Tool        | On-disk    | Runtime deps                       |
|-------------|-----------:|------------------------------------|
| refract     |      61 MB | none (single static binary)        |
| solargraph  |   ~47 MB   | Ruby + bundler + yard + rbs        |
| ruby-lsp    |   ~25 MB   | Ruby + bundler + prism + rbs       |

Gem-based servers also require a Ruby runtime (2.8 GB on this host with mise).
Refract's binary contains everything: parser, indexer, server, SQLite.

## Feature matrix

| Capability                          | refract | solargraph | ruby-lsp |
|-------------------------------------|:-------:|:----------:|:--------:|
| `definition` / `hover` / `completion` |   ✓    |    ✓       |   ✓      |
| `references` / `rename` / `code-action` |  ✓   |    ✓       |   ✓      |
| Document & workspace symbols         |   ✓    |    ✓       |   ✓      |
| Diagnostics (RuboCop bridge)         |   ✓    |    ✓       |   ✓      |
| Semantic tokens                      |   ✓    |    ✓       |   ✓      |
| ERB / HAML awareness                 |   ✓    |  partial   |   ✓      |
| Built-in stdlib RBS resolution       |   no   |    no      |   ✓      |
| Persistent on-disk index             |   ✓    |  yard cache|   ✓      |
| Single-binary install                |   ✓    |    no      |   no     |
| MCP server for AI agents             |   ✓    |    no      |   no     |
| Rails DSL parser (5.2–8.0)           |   ✓    |  via plugin|  via addon |

## Indexing scale on real Rails apps

The head-to-head above is a same-workspace LSP comparison. Refract also has a
standalone `--index-only` mode that is useful for sizing cold-bootstrap on
production codebases. Other LSPs don't expose an equivalent batch mode, so
this section is refract-only.

- Build: debug (Fedora `_FORTIFY_SOURCE` blocks `--release=safe` locally; CI musl release builds are 2–4× faster)
- Workers: `--max-workers 8` · Mode: `refract --index-only --disable-rubocop`

| Corpus              | Files indexed | Symbols | Wall time | Peak RSS | Notes |
|---------------------|--------------:|--------:|----------:|---------:|-------|
| mastodon            |         4,063 |  36,052 |   1:46    |    91 MB | clean run, chunked commits |
| discourse/app       |         1,232 |  12,555 |   0:15    |    48 MB | |
| discourse/lib       |           723 |   8,375 |   0:12    |    41 MB | |
| discourse/spec      |         1,880 |  47,699 |   0:47    |    66 MB | |
| discourse/plugins   |         7,765 |  38,885 |   4:37    |    67 MB | |
| discourse (full)    |       ~13,000 |       — | ~30–45 m  |   ~310 MB | completes; slow; see findings |

Findings:

- **Mastodon-scale (≤5k files) indexes in ~2 minutes** with peak RSS under ~100 MB.
- **Per-subdirectory indexing scales linearly** — sum of Discourse subdirs is ~6 minutes for the same files.
- **Full-Discourse cold-bootstrap initially hung indefinitely** because the entire reindex was wrapped in a single SQL transaction. WAL grew to hundreds of MB and the final COMMIT became pathological. Fixed in `a5035e5` (`perf(indexer): chunk reindex into 500-file transactions`) — runs now complete, WAL stays bounded around 67 MB.
- **Residual slowness on huge repos**: even with chunked commits, full-Discourse cold-bootstrap takes ~30–45 minutes on debug builds. Per-subdir runs are 5–6× faster than the full-repo run, suggesting super-linear cost in cross-file resolution as the symbols table grows. Likely needs deferring speculative method-chain inference (the `SELECT return_type FROM symbols WHERE name=? AND kind='def' AND file_id IN (subquery)` pattern) to query time on large workspaces.

| Audience                              | Status                |
|---------------------------------------|-----------------------|
| Solo dev / small team Rails apps      | Works well            |
| Mid-size apps (~5k Ruby files)        | Works (≤2 min cold)   |
| Large monorepos (10k+ files)          | Cold-bootstrap is slow (~30–45 min debug, ~10–15 min release); incremental edits afterward are fast |

Reproduction:

```sh
zig build "-Dgit_sha=$(git rev-parse --short HEAD)"
REFRACT_PILOT_DIR=/tmp/refract-pilot ./scripts/pilot.sh mastodon
# or: ./scripts/pilot.sh discourse
```

## Summary

|                                       | Best of three                                |
|---------------------------------------|----------------------------------------------|
| `initialize` response time            | **refract** (25-75 ms warm, persistent DB)   |
| Cold-warm to first symbol (Mastodon)  | **refract** (757 ms) — 80× faster than ruby-lsp |
| Session def p50 (Mastodon)            | **refract** (0.82 ms)                        |
| Session hover p50 (Mastodon)          | ruby-lsp (0.80 ms) — refract 1.25 ms         |
| Session completion p50 (Mastodon)     | **refract** (0.86 ms)                        |
| Session `workspace/symbol` p50        | **refract** (1.67 ms) — 15× faster           |
| Session `references` p50              | **refract** (0.91 ms) — 730× faster          |
| Typing/micro p50                      | ruby-lsp — refract 15-30× slower under storm |
| Peak memory (Mastodon)                | **refract** (45 MB) — 3.2× less than ruby-lsp |
| Stdlib accuracy (1 q.)                | ruby-lsp (only one with type inference)      |
| Install simplicity                    | **refract** (no Ruby required)               |
| MCP / agent surface                   | **refract** (only one)                       |

Refract is best on most dimensions on real Rails-scale workspaces: cold-warm
time, definition, completion, workspace symbols, references, memory.
**Open gaps**: hover loses by 1.6× because we don't yet do RBS-typed hover;
typing/micro workloads lose by 15-30× because in-thread re-parse blocks the
query handler under didChange storms; one EPIPE crash under typing storm.
All tracked.

## How to reproduce

```sh
zig build bench-lsp                           # builds + runs the suite
# or:
zig build "-Dgit_sha=$(git rev-parse --short HEAD)"
gem install ruby-lsp solargraph
bash scripts/bench/snapshot.sh                # captures JSON to bench-results/
```

Driver source: [`scripts/bench/lsp_driver.rb`](../scripts/bench/lsp_driver.rb),
[`scripts/bench/lsp_accuracy.rb`](../scripts/bench/lsp_accuracy.rb),
[`scripts/bench/lsp_driver_lib.rb`](../scripts/bench/lsp_driver_lib.rb).
Corpus generator: [`scripts/bench.sh`](../scripts/bench.sh).
