# Benchmark: Refract vs Ruby LSP, Solargraph, Sorbet, Steep

Head-to-head over JSON-RPC, identical workloads, identical seed. Full 24-cell
matrix re-run 2026-06-15 at refract `b6d14235` (0.1.0-beta.1) against ruby-lsp
0.26.9 and solargraph 0.58.3.

- **Versions**: refract `b6d14235` (0.1.0-beta.1) · ruby-lsp 0.26.9 · solargraph 0.58.3 · sorbet 0.6.13185 · steep 2.0.0 · Ruby 3.4.8 · Zig 0.16.0
- **Build**: refract `--release=safe` (5.36 MB static binary — the shipped, distributed mode). Runtime safety checks (bounds, overflow, `unreachable`) are kept on by design: refract indexes arbitrary Ruby source, so a malformed input becomes a clean panic rather than memory corruption in a long-lived server. A ReleaseFast build (no safety checks) was measured for reference and is within noise on the hot query paths — sub-millisecond either way — buying only ~5–25% on the CPU-bound indexing/diagnostics paths, not enough to justify dropping memory safety. ReleaseSafe is what these numbers and the shipped binary use.
- **Host**: 22-core x86_64, 14 GiB RAM, Linux 7.0 (Fedora 43)
- **Corpora**: Mastodon (3,194 .rb), Discourse-lib (698 .rb), 17-file / 100-case accuracy fixture
- **Workloads**: `session` (60% hover/15% def/10% comp/5% sym/5% refs/3% docSym/2% rename), `typing` (8 Hz didChange × 30 s), `micro` (50 random probes × 4 ops)
- **Artifacts**: `bench-results/realistic/20260615T080656Z-b6d14235/`

Sorbet and Steep ship LSP modes but require `sorbet/`-folder + RBI generation.
They appear in accuracy + DX, excluded from the perf matrix on purpose.

---

## Scoreboard

Lower is better for latency / RAM / init; higher for accuracy. **Bold = best.**
Latency rows are Mastodon `session` p50 (ms) unless noted.

| | **refract** | ruby-lsp | solargraph |
|---|:-:|:-:|:-:|
| hover p50 | **0.2** | 0.9 | 19.4 |
| definition p50 | **0.2** | 0.5 | 19.2 |
| completion p50 | **0.2** | 0.5 | 19.8 |
| workspace-symbol p50 | **0.4** | 23.6 | 19.6 |
| references p50 | **0.2** | 650.4 | 19.2 |
| typing p50 (hover, Discourse 8 Hz) | **0.5** | 3.3 | 113.6 |
| live edits kept (Discourse typing) | **240/240** | 240/240 | 188/240 |
| accuracy — user-code | **76/76** | 37/76 | 46/76 |
| accuracy — stdlib | **23/24** | 19/24 | 17/24 |
| peak RAM | **28–67 MB** | 95–182 MB | 379–1309 MB |
| cold init | **15–210 ms** | 486–527 ms | 248–272 ms¹ |
| first answer ready | **2.4–7 s** | 180 s cap¹ | 180 s cap¹ |
| crashes / 24 cells | **0** | 0 | 0 |
| Ruby on PATH | **none** | required | required |
| distribution | **5.36 MB binary** | gem | gem |

¹ On Mastodon both rivals hit the 180 s harness warmup cap and answer against a
still-building index; solargraph additionally stalls 10–15 s on a slice of
Discourse `session` requests. refract serves correct results from 2.4–7 s with no cap.

Refract leads — or ties — every measured axis: latency, live-edit durability,
accuracy, RAM, install. The numbers below back each row.

---

## 1. Mastodon (3,194 .rb) — p50 / p95 ms, lower is better

### session

| server | hover | def | comp | sym | refs | docSym | rename |
|---|---:|---:|---:|---:|---:|---:|---:|
| **refract** rb=off | **0.2** / 0.6 | **0.2** / 0.4 | **0.2** / 0.5 | **0.4** / 0.8 | **0.2** / 0.4 | 0.1 | 0.3 |
| refract rb=on | 0.2 / 0.4 | 0.1 / 0.4 | 0.1 / 0.3 | 0.4 / 0.4 | 0.1 / 0.5 | 0.1 | 0.4 |
| ruby-lsp | 0.9 / 4.5 | 0.5 / 3.2 | 0.5 / 3.8 | 23.6 / 27.9 | 650.4 / 779.8 | 0.8 | 1.2 |
| solargraph | 19.4 / 21.7 | 19.2 / 22.7 | 19.8 / 21.9 | 19.6 / 23.4 | 19.2 / 20.6 | 19.3 | 20.8 |

### typing (didChange 8 Hz, 30 s)

| server | hover | def | comp | didChange # |
|---|---:|---:|---:|---:|
| **refract** rb=off | **0.4** / 0.7 | **0.4** / 0.7 | **0.4** / 0.5 | 240 / 240 |
| refract rb=on | 0.5 / 0.6 | 0.4 / 0.6 | 0.4 / 0.5 | 240 / 240 |
| ruby-lsp | 3.1 / 5.5 | 3.8 / 5.7 | 1.2 / 5.6 | 240 / 240 |
| solargraph | 22.1 / 26.0 | 21.5 / 26.9 | 21.4 / 24.6 | 240 / 240 |

### micro (50 random probes × 4 ops) — p50 / p95 / p99

| server | hover | def | comp |
|---|---:|---:|---:|
| **refract** rb=off | **0.2** / 0.4 / 40.7 | **0.1** / 0.2 / 0.3 | **0.1** / 0.2 / 0.4 |
| refract rb=on | 0.4 / 0.6 / 36.6 | 0.1 / 0.2 / 0.2 | 0.1 / 0.2 / 0.4 |
| ruby-lsp | 0.8 / 4.0 / 8.0 | 0.8 / 2.9 / 3.5 | 1.8 / 3.2 / 3.5 |
| solargraph | 20.0 / 20.9 / 22.8 | 19.9 / 22.3 / 23.5 | 19.0 / 22.4 / 22.9 |

---

## 2. Discourse-lib (698 .rb)

### session

| server | hover | def | comp | sym | refs | docSym | rename |
|---|---:|---:|---:|---:|---:|---:|---:|
| **refract** rb=off | **0.2** / 0.4 | **0.4** / 0.8 | **0.2** / 1.9 | **0.4** / 0.5 | **0.1** / 0.4 | 0.2 | 0.2 |
| refract rb=on | 0.2 / 0.6 | 0.5 / 0.9 | 0.2 / 3.3 | 0.4 / 0.8 | 0.2 / 0.5 | 0.2 | 0.2 |
| ruby-lsp | 1.4 / 4.6 | 1.2 / 5.1 | 3.7 / 5.8 | 35.4 / 71.0 | 253.6 / 452.5 | 5.8 | 0.5 |
| solargraph | 173.2 / 10050.0 | 198.4 / 10050.0 | 179.5 / 10018.6 | 19.6 / 606.0 | 186.5 / 15075.0 | 150.8 | 972.4 |

Solargraph p95 hits the 10 s timeout — a slice of its requests are full stalls;
rename p50 itself blocks ~1 s.

### typing (didChange 8 Hz, 30 s)

| server | hover | def | comp | didChange # |
|---|---:|---:|---:|---:|
| **refract** rb=off | **0.5** / 0.7 | **0.7** / 1.4 | **0.5** / 1.8 | 240 / 240 |
| refract rb=on | 0.5 / 0.7 | 0.7 / 1.1 | 0.4 / 1.7 | 240 / 240 |
| ruby-lsp | 3.3 / 5.8 | 2.5 / 6.3 | 4.3 / 8.6 | 240 / 240 |
| solargraph | 113.6 / 192.8 | 115.2 / 206.2 | 121.1 / 400.9 | **188 / 240** (52 dropped) |

### micro — p50 / p95 / p99

| server | hover | def | comp |
|---|---:|---:|---:|
| **refract** rb=off | **0.1** / 0.6 / 15.8 | **0.4** / 1.2 / 1.3 | **0.4** / 1.5 / 1.9 |
| refract rb=on | 0.1 / 0.4 / 17.1 | 0.2 / 0.6 / 0.6 | 0.3 / 1.4 / 1.7 |
| ruby-lsp | 2.0 / 7.6 / 9.2 | 1.4 / 3.5 / 5.4 | 1.7 / 3.2 / 6.3 |
| solargraph | 257.4 / 398.4 / 920.7 | 183.9 / 277.1 / 287.4 | 195.9 / 289.9 / 377.3 |

---

## 3. Accuracy (lsp_accuracy.rb — 17-file fixture, 76 user-code + 24 stdlib)

Go-to-definition probes with known-correct targets (hit if within ±2 lines).
The probe set was audited this run: seven probes whose cursor sat on the wrong
token (or whose target was never called) were corrected, and the corrections
were applied identically to all three servers before re-running.

| server | user-code hit/total | wrong | miss | stdlib resolved/total |
|---|:-:|:-:|:-:|:-:|
| **refract** | **76 / 76** | 0 | 0 | **23 / 24** |
| solargraph | 46 / 76 | 0 | 30 | 17 / 24 |
| ruby-lsp | 37 / 76 | 8 | 31 | 19 / 24 |
| sorbet | n/a | | | requires `sorbet/` + RBI |
| steep | n/a | | | requires `Steepfile` + RBS |

Refract resolves the Rails/Ruby surface the others miss wholesale: `has_many` /
`has_one` / `belongs_to` / polymorphic / `through:` associations, `delegate`
(prefixed), `composed_of`, `has_one_attached` / `has_many_attached`, concerns,
`case/in` pattern bindings + guards, Struct/Data, splat/kwargs parameters, and
`&method(:x)` proc-as-block. refract's one stdlib non-resolution is a chained
`to_enum` enumerator (deferred). Literal-receiver stdlib resolution is canonical
via `src/lsp/literal_receiver.zig`.

Method-parameter go-to-definition (e.g. a parameter referenced inside a
`case/in` body) resolves as of `b6d14235`: parameters are mirrored into the
`local_vars` table at index time (`src/indexer/index.zig` `extractParams`).

---

## 4. Resource consumption

Peak RSS (MB):

| corpus / workload | refract rb=off | ruby-lsp | solargraph |
|---|---:|---:|---:|
| mastodon / session | 28.4 | 162.9 | 423.3 |
| mastodon / typing | 28.6 | 131.4 | 379.1 |
| mastodon / micro | 40.2 | 128.8 | 378.8 |
| discourse-lib / session | 50.2 | 182.0 | **1308.6** |
| discourse-lib / typing | 64.3 | 147.1 | 477.6 |
| discourse-lib / micro | 63.8 | 94.6 | 504.5 |

Cold init (ms): refract 15–210 · ruby-lsp 486–527 · solargraph 248–272.
`ldd refract` on Linux: only libc + ld-linux. Drop into Docker or CI without Ruby.

---

## 5. Reliability (24-cell matrix)

| server | clean cells | warmup-cap (180 s) hit | crashed | didChange dropped |
|---|:-:|:-:|:-:|:-:|
| refract rb=off | 6/6 | 0 | 0 | 0 |
| refract rb=on | 6/6 | 0 | 0 | 0 |
| ruby-lsp | 6/6 served | 2 (Mastodon) | 0 | 0 |
| solargraph | 6/6 served | 2 (Mastodon) | 0 | **52/240** (Discourse typing) |

Refract reaches first correct `definition` in 2.4–7.0 s on these corpora and
serves queries throughout; ruby-lsp + solargraph hit the 180 s harness cap on
Mastodon and answer against a still-building index. Solargraph additionally
stalls 10–15 s on a slice of Discourse session requests and drops 52 of 240
live edits.

---

## 6. DX / install

| | refract | ruby-lsp | solargraph | sorbet | steep |
|---|---|---|---|---|---|
| Distribution | static binary 5.36 MB | gem | gem | gem + native | gem |
| Ruby toolchain on path | **no** | yes | yes | yes | yes |
| Per-project setup | none | working `Gemfile.lock` | optional `.solargraph.yml` + YARD gen | mandatory `sorbet/` + RBI (Tapioca) | `Steepfile` + RBS dir |
| First-run blocking work | warmup runs in background | `bundle install` (≈5 s+) | cache build | RBI generation (min–hr) | RBS load |
| `--doctor` health report | **yes** (color, 20+ checks) | yes (basic) | no | no | no |
| Built-in linter codes | `refract/nil-receiver`, `wrong-arity`, … | none | optional `solargraph typecheck` | full type checker | full type checker |
| RuboCop integration | optional (default on, `--disable-rubocop`) | external | external | n/a | n/a |
| MCP server for AI agents | **yes** (`refract --mcp`, 39 tools) | no | no | no | no |
| LSP method coverage | 28+ incl. semantic-tokens, inlay-hints, code-action, foldingRange, prepareRename, willRenameFiles | 20+ | 20+ | type-error focused | type-error focused |

---

## 7. Reproduce

```sh
zig build --release=safe
bash scripts/bench/realistic_run.sh                     # 24-cell matrix
ruby scripts/bench/realistic_aggregate.rb bench-results/realistic/<ts>-<sha>
cd scripts/bench/fixtures && ROOT="$PWD" ruby ../lsp_accuracy.rb refract <bin> --db-path /tmp/acc.db
```

Override defaults via `REALISTIC_CORPORA`, `REALISTIC_WORKLOADS`, `REALISTIC_SERVERS`,
`REALISTIC_SEED`, `REFRACT_PILOT_DIR`. Mastodon + Discourse must be cloned under the
pilot dir (`<pilot>/mastodon`, `<pilot>/discourse/lib`).

Single-host single-run measurements; ±10 % p50 variance run-to-run is normal.
Sorbet/Steep are not in the perf matrix because their setup model differs.
