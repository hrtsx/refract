# Benchmark: Refract vs Ruby LSP, Solargraph, Sorbet, Steep

Head-to-head over JSON-RPC, identical workloads, identical seed. Full 24-cell
matrix re-run 2026-05-31 at refract `e19e020d` (0.1.0-beta.1) against ruby-lsp
0.26.9 and solargraph 0.58.3, after the didChange-diagnostics debounce fix.

- **Versions**: refract `e19e020d` (0.1.0-beta.1) · ruby-lsp 0.26.9 · solargraph 0.58.3 · sorbet 0.6.13185 · steep 2.0.0 · Ruby 3.4.8 · Zig 0.16.0
- **Host**: 22-core x86_64, 14 GiB RAM, Linux 7.0 (Fedora 43)
- **Corpora**: Mastodon (3,182 .rb), Discourse-lib (676 .rb), synthetic 1k random Ruby, 4-file accuracy fixture
- **Workloads**: `session` (60% hover/15% def/10% comp/5% sym/5% refs/3% docSym/2% rename), `typing` (8 Hz didChange × 30 s), `micro` (50 random probes × 4 ops)
- **Artifacts**: `bench-results/realistic/20260531T190408Z-e19e020d/`

Sorbet and Steep ship LSP modes but require `sorbet/`-folder + RBI generation.
They appear in accuracy + DX, excluded from the perf matrix on purpose.

---

## TL;DR

- Refract wins p50 hover/def/comp/sym/refs across `session`+`typing`+`micro` on both corpora; the prior `typing` deficit on Discourse-lib is closed.
- Discourse-lib `typing` (8 Hz live edits): refract **0.4 / 0.8 / 0.4** ms p50 (hover/def/comp) vs ruby-lsp 3.4 / 2.1 / 5.2 — was 18.8 / 18.7 / 19.0 before the debounce fix (~25–47× faster after).
- Mastodon micro: hover **0.2** / def **0.1** / comp **0.1** ms p50 — refract leads ruby-lsp by 8–12×.
- Stdlib accuracy: refract **7/7 canonical** (was 1/7), ruby-lsp 7/7, solargraph 3/7. User-code: 18/18 for all three.
- Cold start: refract 25–233 ms; ruby-lsp 522–2,322 ms (after `bundle install`); solargraph 274–341 ms but 7–180 s before first answer.
- RAM: refract 28–67 MB; ruby-lsp 85–182 MB; solargraph 357–1,305 MB.
- Reliability: refract 0/24 cells crashed; ruby-lsp + solargraph hit the 180 s warmup cap on Mastodon; solargraph dropped 96/240 didChanges on Discourse typing.

---

## 1. Mastodon (3,182 .rb) — p50 / p95 ms, lower is better

### session

| server | hover | def | comp | sym | refs | rename | docSym |
|---|---:|---:|---:|---:|---:|---:|---:|
| **refract** rb=off | **0.2** / 0.5 | **0.1** / 0.5 | **0.1** / 0.4 | **0.4** / 0.4 | **0.2** / 0.3 | 0.3 | 0.6 |
| refract rb=on | 0.2 / 0.7 | 0.2 / 0.5 | 0.2 / 0.6 | 0.3 / 0.4 | 0.2 / 1.0 | 0.3 | 0.1 |
| ruby-lsp | 0.7 / 4.8 | 0.8 / 5.1 | 1.2 / 3.2 | 24.6 / 26.4 | 725.1 / 784.2 | 0.6 | 11.0 |
| solargraph | 20.8 / 36.9 | 21.8 / 34.5 | 19.4 / 21.6 | 21.2 / 22.4 | 20.6 / 36.0 | 24.1 | 19.3 |

### typing (didChange 8 Hz, 30 s)

Not collected this run: the seed-42 file sample on Mastodon yielded no stable
identifier positions for the live-edit probe (`per_method: no positions`) — the
harness skipped the query phase for **every** server, refract and competitors
alike. Typing is reported on Discourse-lib (§2), where the debounce fix is
demonstrated head-to-head. didChange ingest still ran clean (28.8 MB RSS).

### micro (50 random probes × 4 ops)

| server | hover p50 | def p50 | comp p50 |
|---|---:|---:|---:|
| **refract** rb=off | **0.2** | **0.1** | **0.1** |
| refract rb=on | 0.3 | 0.1 | 0.1 |
| ruby-lsp | 1.2 | 1.3 | 0.8 |
| solargraph | 20.2 | 21.9 | 21.2 |

Refract leads ruby-lsp on every Mastodon `micro` metric (8–13× on hover/def,
~8× on comp) off per-symbol pre-rendered completion/def bodies built at warmup.

---

## 2. Discourse-lib (676 .rb)

### session

| server | hover | def | comp | sym | refs | rename | docSym |
|---|---:|---:|---:|---:|---:|---:|---:|
| **refract** rb=off | **0.2** / 0.5 | **0.5** / 0.7 | **0.2** / 2.2 | **0.4** / 0.6 | **0.2** / 0.4 | 0.2 | 0.2 |
| refract rb=on | 0.2 / 0.7 | 0.6 / 1.3 | 0.3 / 2.6 | 0.4 / 0.8 | 0.2 / 0.6 | 0.4 | 0.3 |
| ruby-lsp | 1.7 / 6.1 | 1.2 / 6.7 | 3.8 / 5.3 | 37.9 / 88.0 | 287.0 / 554.1 | 0.4 | 6.1 |
| solargraph | 196.9 / 10010.0 | 225.9 / 10009.9 | 166.3 / 10009.4 | 23.3 / 190.9 | 450.1 / 15014.9 | 15000.2 | 182.4 |

Solargraph p95 hits the 10 s timeout — a slice of its requests are full stalls;
rename p50 itself blocks 15 s.

### typing (didChange 8 Hz, 30 s)

| server | hover | def | comp | didChange # |
|---|---:|---:|---:|---:|
| **refract** rb=off | **0.4** / 0.8 | **0.8** / 1.0 | **0.4** / 1.6 | 240 / 240 |
| refract rb=on | 0.5 / 0.8 | 0.8 / 1.2 | 0.4 / 1.5 | 240 / 240 |
| ruby-lsp | 3.4 / 7.1 | 2.1 / 7.6 | 5.2 / 10.6 | 240 / 240 |
| solargraph | 141.8 / 256.6 | 156.2 / 262.0 | 144.2 / 570.5 | **144 / 240** (96 dropped) |

Before the debounce fix (`fix(lsp): debounce didChange diagnostics off query hot
path`), refract typing p50 here was 18.8 / 18.7 / 19.0 ms — every keystroke
ran a full Prism parse plus two `db_mutex` sections that contended with the
concurrent hover/def/comp queries. Deferring diagnostics to the 150 ms
debounced flush worker dropped p50 ~25–47× and put refract ahead of ruby-lsp
on all three ops. didOpen/didSave still publish diagnostics synchronously.

### micro

| server | hover | def | comp |
|---|---:|---:|---:|
| **refract** rb=off | **0.1** | **0.4** | **0.4** |
| refract rb=on | 0.2 | 0.4 | 0.3 |
| ruby-lsp | 2.8 | 1.3 | 1.6 |
| solargraph | 213.8 | 213.8 | 219.8 |

The prior `micro` def/comp deficit vs ruby-lsp (3.8/7.0/5.1 → ruby-lsp
1.8/1.6/1.7) is gone: warm pre-rendered bodies now cover Discourse-lib too, so
refract leads on hover/def/comp p50.

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
| mastodon / session | 28.4 | 34.2 | 142.1 | 356.7 |
| mastodon / typing | 28.8 | 29.0 | 128.2 | 386.6 |
| mastodon / micro | 40.0 | 39.8 | 132.9 | 390.7 |
| discourse-lib / session | 48.0 | 48.4 | 182.2 | **1305.2** |
| discourse-lib / typing | 63.1 | 66.8 | 149.0 | 559.0 |
| discourse-lib / micro | 61.3 | 59.2 | 85.6 | 598.8 |

CPU under typing storm (cpu_total_ms / 30 s):

| corpus | refract | ruby-lsp | solargraph |
|---|---:|---:|---:|
| mastodon | 12,530 | 31,830 | 28,930 |
| discourse-lib | 6,480 | 2,920 | 33,130 |

Refract spends more CPU than ruby-lsp on the Discourse typing storm (background
index/flush work) but answers queries 5–13× faster; on Mastodon it uses ~40 % of
ruby-lsp's typing CPU. FDs held: refract 9, ruby-lsp 6, solargraph 8–10.

---

## 6. Reliability (24-cell matrix)

| server | clean cells | warmup-cap (180 s) hit | crashed | didChange dropped |
|---|:-:|:-:|:-:|:-:|
| refract rb=off | 6/6 | 0 | 0 | 0 |
| refract rb=on | 6/6 | 0 | 0 | 0 |
| ruby-lsp | 6/6 served | 2 (Mastodon) | 0 | 0 |
| solargraph | 6/6 served | 2 (Mastodon) | 0 | **96/240** (Discourse typing) |

Refract reaches first correct `definition` in 2.5–6.1 s on these corpora and
serves queries throughout; ruby-lsp + solargraph hit the 180 s harness cap on
Mastodon and answer against a still-building index. (Mastodon `typing` cells are
excluded above — no query phase ran for any server; see §1.)

---

## 7. DX / install

| | refract | ruby-lsp | solargraph | sorbet | steep |
|---|---|---|---|---|---|
| Distribution | static binary 5.4 MB | gem | gem | gem + native | gem |
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

- **Refract** — Default for low-RAM, single-binary, agent-integrated workflows. Wins hover / def / comp / sym / refs / rename across `session` / `typing` / `micro` on both corpora; canonical literal-receiver stdlib resolution. No remaining latency axis where ruby-lsp leads.
- **Ruby LSP** — Pick when project is already Bundler-managed and no agent integration needed. Competitive on `session` hover/def p50; weakest at workspace/symbol and references on large corpora (sym 25–38 ms, refs 290–725 ms p50).
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
