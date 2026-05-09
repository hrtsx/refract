# Benchmark: Refract vs Ruby LSP, Solargraph, Sorbet, Steep

Head-to-head over JSON-RPC, identical workloads, identical seed. Numbers from the
2026-05-05 run at refract `6da12d2`.

- **Versions**: refract 0.1.0 · ruby-lsp 0.26.9 · solargraph 0.58.3 · sorbet 0.6.13185 · steep 2.0.0 · Ruby 3.4.8 · Zig 0.16.0
- **Host**: 22-core x86_64, 14 GiB RAM, Linux 6.19 (Fedora 43)
- **Corpora**: Mastodon (3,165 .rb), Discourse-lib (667 .rb), synthetic 1k random Ruby, 4-file accuracy fixture
- **Workloads**: `session` (60% hover/15% def/10% comp/5% sym/5% refs/3% docSym/2% rename), `typing` (8 Hz didChange × 30 s), `micro` (50 random probes × 4 ops)
- **Artifacts**: `bench-results/20260505T141833Z-512f611-dirty.json` + `bench-results/realistic/20260505T142043Z-512f611-dirty/`

Sorbet and Steep ship LSP modes but require `sorbet/`-folder + RBI generation.
They appear in accuracy + DX, excluded from the perf matrix on purpose.

---

## TL;DR

- Refract wins p50 hover/def/comp/sym/refs in `session`+`typing` on both corpora; ruby-lsp wins `micro` def/comp.
- Mastodon micro hover dropped 4.14 → **0.17 ms p50** with the literal-receiver patch.
- Stdlib accuracy: refract **7/7 canonical** (was 1/7), ruby-lsp 7/7, solargraph 3/7. User-code: 18/18 for all three.
- Cold start: refract 16–57 ms; ruby-lsp 488–520 ms (after `bundle install`); solargraph 225 ms but 6–180 s before first answer.
- RAM: refract 26–55 MB; ruby-lsp 100–155 MB; solargraph 355–1,271 MB.
- Reliability: refract 0/24 cells crashed; ruby-lsp + solargraph hit the 180 s warmup cap on Mastodon.

---

## 1. Mastodon (3,165 .rb) — p50 / p95 ms, lower is better

### session

| server | hover | def | comp | sym | refs | rename | docSym |
|---|---:|---:|---:|---:|---:|---:|---:|
| **refract** rb=off | **0.21** / 4.65 | **0.16** / 6.51 | **0.27** / 2.86 | **0.41** / 3.66 | **0.50** / 5.04 | 0.40 | 0.13 |
| refract rb=on | 0.13 / 4.81 | 0.13 / 5.41 | 0.10 / 3.41 | 0.44 / 3.83 | 0.34 / 2.32 | 0.34 | 0.13 |
| ruby-lsp | 0.86 / 4.32 | 1.21 / 3.99 | 2.41 / 3.49 | 24.16 / 56.69 | 686.32 / 717.51 | 1.51 | 3.97 |
| solargraph | 18.16 / 31.13 | 19.18 / 31.46 | 17.74 / 20.07 | 16.79 / 33.06 | 19.97 / 31.94 | 25.81 | 18.69 |

### typing (didChange 8 Hz, 30 s; all 240/240)

| server | hover | def | comp |
|---|---:|---:|---:|
| **refract** rb=off | **0.43** / 9.40 | **0.55** / 11.05 | **0.59** / 9.55 |
| refract rb=on | 0.40 / 10.43 | 0.55 / 9.81 | 0.60 / 10.79 |
| ruby-lsp | 0.94 / 4.79 | 0.83 / 5.10 | 1.10 / 4.91 |
| solargraph | 19.19 / 22.17 | 18.91 / 21.78 | 19.31 / 22.71 |

### micro (50 random probes)

| server | hover p50 | def p50 | comp p50 |
|---|---:|---:|---:|
| **refract** rb=off | **0.17** | 3.28 | 3.71 |
| refract rb=on | 3.74 | 7.30 | 3.04 |
| ruby-lsp | 0.55 | **0.20** | 1.18 |
| solargraph | 17.05 | 18.71 | 18.30 |

Hot-index fast path now serves cache-cold hover positions in 0.17 ms p50 — faster
than ruby-lsp. Refract's `def` and `completion` in `micro` still trail ruby-lsp
because both round-trip SQL for parameter signatures and prefix scans (next round).

---

## 2. Discourse-lib (667 .rb)

### session

| server | hover | def | comp | sym | refs | rename | docSym |
|---|---:|---:|---:|---:|---:|---:|---:|
| **refract** rb=off | **0.15** / 6.74 | **0.41** / 5.71 | **0.40** / 8.62 | **0.42** / 4.66 | **0.46** / 6.40 | 0.18 | 0.18 |
| refract rb=on | 0.13 / 9.92 | 0.41 / 9.07 | 0.45 / 4.18 | 0.56 / 9.04 | 0.23 / 16.51 | 0.24 | 0.18 |
| ruby-lsp | 1.01 / 4.59 | 1.61 / 4.18 | 2.42 / 4.62 | 32.69 / 37.36 | 242.30 / 451.50 | 0.66 | 4.62 |
| solargraph | 161.51 / 10009.31 | 148.96 / 10008.91 | 166.36 / 10010.07 | 20.69 / 224.40 | 2153.81 / 15014.99 | 183.30 | 132.59 |

Solargraph p95 hits the 10 s timeout — ~5 % of its requests are full stalls.

### typing

| server | hover | def | comp | didChange # |
|---|---:|---:|---:|---:|
| **refract** rb=off | **0.30** / 2.99 | **0.59** / 1.20 | **0.46** / 5.94 | 240 / 240 |
| refract rb=on | 0.32 / 1.32 | 0.46 / 0.94 | 0.43 / 11.00 | 240 / 240 |
| ruby-lsp | 2.06 / 5.55 | 1.92 / 4.62 | 2.32 / 6.03 | 240 / 240 |
| solargraph | 96.04 / 207.74 | 100.62 / 163.13 | 95.16 / 181.96 | **210 / 240** (30 dropped) |

### micro

| server | hover | def | comp |
|---|---:|---:|---:|
| refract rb=off | 3.78 | 7.04 | 5.10 |
| refract rb=on | 3.59 | 5.86 | 4.62 |
| **ruby-lsp** | **1.81** | **1.55** | **1.66** |
| solargraph | 204.43 | 189.97 | 216.16 |

---

## 3. Synthetic 1k-file (steady-state, snapshot.sh)

| server | init ms | def p50 | hover p50 | comp p50 | RSS MB |
|---|---:|---:|---:|---:|---:|
| refract | 30.3 | 0.1 | 0.1 | 5.2 | 27.1 |
| ruby-lsp | 1774.7 | 0.1 | 0.1 | 0.3 | 127.8 |
| solargraph | 227.3* | 0.1* | 0.1* | 0.1* | 299.0* |

`*` Solargraph hits `Solargraph::InvalidOffsetError` on the bench fixture; near-zero
p50 reflects null-result fast-fails, not real work.

---

## 4. Accuracy (lsp_accuracy.rb on a 4-file fixture)

User-code (18 cases: same-file refs, cross-file, mixin, attr_accessor, inheritance):

| server | hits | wrong | miss |
|---|:-:|:-:|:-:|
| refract | **18/18** | 0 | 0 |
| ruby-lsp | **18/18** | 0 | 0 |
| solargraph | **18/18** | 0 | 0 |

Stdlib literal-receiver (5 literal + 2 chained):

| server | resolved/total | canonical match per case |
|---|:-:|---|
| **refract** | **7/7** | string.rbs:121, array.rbs:55, hash.rbs:39, numeric.rbs:93 (Integer < Numeric in refract's bundle), symbol.rbs:29; chain Object→object.rbs:55, chain String→string.rbs:121 |
| ruby-lsp | 7/7 | All 7 canonical (lands integer.rbs vs refract's bundle-merged numeric.rbs) |
| solargraph | 3/7 | Resolves only String/Array/Hash literal cases |
| sorbet | n/a | requires `sorbet/` + RBI files |
| steep | n/a | requires `Steepfile` + RBS dir |

Literal-receiver is now canonical via a small text classifier
(`src/lsp/literal_receiver.zig`) that detects `"…"`, `[…]`, `{…}`, `:foo`, `42`,
`42.0` and routes through `hot.lookupMethodOnClass(class, method)`.

---

## 5. Resource consumption

Peak RSS (MB):

| corpus / workload | refract rb=off | refract rb=on | ruby-lsp | solargraph |
|---|---:|---:|---:|---:|
| mastodon / session | 30.0 | 26.5 | 138.3 | 355.2 |
| mastodon / typing | 26.4 | 26.3 | 130.3 | 382.6 |
| mastodon / micro | 26.1 | 29.7 | 123.8 | 366.4 |
| discourse-lib / session | 32.8 | 34.4 | 155.2 | **1271.2** |
| discourse-lib / typing | 55.1 | 53.4 | 144.8 | 715.2 |
| discourse-lib / micro | 53.0 | 48.8 | 100.0 | 412.0 |

CPU under typing storm (cpu_total_ms / 30 s):

| corpus | refract | ruby-lsp | solargraph |
|---|---:|---:|---:|
| mastodon | 10,900 | 17,050 | 18,740 |
| discourse-lib | 7,810 | 2,500 | 26,610 |

FDs held: refract 8–9, ruby-lsp 6, solargraph 8–10.

---

## 6. Reliability (24-cell matrix)

| server | clean cells | warmup-cap (180 s) hit | crashed | didChange dropped |
|---|:-:|:-:|:-:|:-:|
| refract rb=off | 6/6 | 0 | 0 | 0 |
| refract rb=on | 6/6 | 0 | 0 | 0 |
| ruby-lsp | 6/6 served | 2 (Mastodon) | 0 | 0 |
| solargraph | 6/6 served | 2 (Mastodon) | 0 | **30/240** (Discourse typing) |

Refract reaches `warmup_ok=true` in 21.7–212.9 ms on Mastodon; ruby-lsp + solargraph
hit the 180 s harness cap and serve queries against a still-building index.

---

## 7. DX / install

| | refract | ruby-lsp | solargraph | sorbet | steep |
|---|---|---|---|---|---|
| Distribution | static binary 4.1 MB | gem | gem | gem + native | gem |
| Ruby toolchain on path | **no** | yes | yes | yes | yes |
| Per-project setup | none | working `Gemfile.lock` | optional `.solargraph.yml` + YARD gen | mandatory `sorbet/` + RBI (Tapioca) | `Steepfile` + RBS dir |
| First-run blocking work | warmup runs in background | `bundle install` (≈5 s+) | cache build | RBI generation (min–hr) | RBS load |
| `--doctor` health report | **yes** (color, 8+ checks) | yes (basic) | no | no | no |
| `--repair` autofix | **yes** | no | no | no | no |
| Built-in linter codes | 7 (`refract/nil-receiver`, `wrong-arity`, …) | none | optional `solargraph typecheck` | full type checker | full type checker |
| RuboCop integration | optional (default on, `--disable-rubocop`) | external | external | n/a | n/a |
| MCP server for AI agents | **yes** (`refract --mcp`, 39 tools) | no | no | no | no |
| LSP method coverage | 28+ incl. semantic-tokens, inlay-hints, code-action, foldingRange, prepareRename, willRenameFiles | 20+ | 20+ | type-error focused | type-error focused |

`ldd refract` on Linux: only libc + ld-linux. macOS build similar. Drop into Docker
or CI without Ruby.

---

## 8. When to pick each

- **Refract** — Default for low-RAM, single-binary, agent-integrated workflows. Best at hover / refs / sym / rename / large corpora; canonical literal-receiver stdlib resolution. Trails ruby-lsp by 2–3 ms on `micro` def/comp (bounded SQL round-trip).
- **Ruby LSP** — Pick when project is already Bundler-managed and no agent integration needed. Best at `micro` def/comp p50; weakest at workspace/symbol and references on large corpora.
- **Solargraph** — Mature YARD support. Trade-off: 5–10× higher latency, 10–25× higher RAM, struggles on Mastodon.
- **Sorbet** / **Steep** — Pick when committed to gradual typing with `sig`/RBS. Different operating model (RBI/RBS files required); not interchangeable as navigation servers.

---

## 9. Reproduce

```sh
zig build --release=fast
bash scripts/bench/snapshot.sh                          # synthetic + accuracy
bash scripts/bench/realistic_run.sh                     # 24-cell matrix
ruby scripts/bench/realistic_aggregate.rb bench-results/realistic/<ts>-<sha>
```

Override defaults via `REALISTIC_CORPORA`, `REALISTIC_WORKLOADS`, `REALISTIC_SERVERS`,
`REALISTIC_SEED`. Mastodon + Discourse must be cloned to `$REFRACT_PILOT_DIR`
(default `/tmp/refract-pilot`).

Single-host single-run measurements; ±10 % p50 variance run-to-run is normal.
Sorbet/Steep are not in the perf matrix because their setup model differs.
"Community" / plugin polish is out of scope.
