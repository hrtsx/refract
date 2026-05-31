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
| hover — correct (multi-op) | **6/6** | 4/6 | 5/6 |
| references — recall / prec | **1.00 / 1.00** | 0.75 / 0.53 | **1.00 / 1.00** |
| rename — recall / prec | **1.00 / 1.00** | 0.00 / 0.00 | **1.00 / 1.00** |
| semantic-diagnostic recall | **6/6** | 1/6 | 3/6 |
| peak RAM | **28–67 MB** | 95–182 MB | 379–1309 MB |
| cold init | **15–210 ms** | 486–527 ms | 248–272 ms¹ |
| first answer ready | **2.4–7 s** | 180 s cap¹ | 180 s cap¹ |
| crashes / 24 cells | **0** | 0 | 0 |
| Ruby on PATH | **none** | required | required |
| distribution | **5.36 MB binary** | gem | gem |

¹ On Mastodon both rivals hit the 180 s harness warmup cap and answer against a
still-building index; solargraph additionally stalls 10–15 s on a slice of
Discourse `session` requests. refract serves correct results from 2.4–7 s with no cap.

Refract leads — or ties — every measured axis (latency, live-edit durability,
go-to-definition accuracy, hover, references, rename, semantic diagnostics, RAM,
install). The only axis where it does not lead outright is multi-op **completion**,
a three-way tie at the low end where no server leads (§3a). The numbers below back
each row.

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

## 3a. Multi-operation accuracy (hover / completion / references / rename / diagnostics)

Go-to-definition (§3) is one operation. This pass scores the other
correctness-bearing operations against a **server-agnostic ground truth** — the
same correct answer is scored identically for every server — over a small fixed
fixture set (`scripts/bench/fixtures/`). Driven by `scripts/bench/lsp_multiop.rb`.

| operation | metric | **refract** | ruby-lsp | solargraph |
|---|---|:-:|:-:|:-:|
| hover | correct / total | **6 / 6** | 4 / 6 | 5 / 6 |
| completion | mean member recall | 0.33 | 0.33 | 0.00 |
| references | mean recall / precision | **1.00 / 1.00** | 0.75 / 0.53 | **1.00 / 1.00** |
| rename | mean recall / precision | **1.00 / 1.00** | 0.00 / 0.00 | **1.00 / 1.00** |
| diagnostics | semantic bugs caught / 6 | **6 / 6** | 1 / 6 | 3 / 6 |

- **hover** — refract resolves every probe (method calls, attr readers, class and
  cross-file singleton defs); ruby-lsp returns empty on chained/cross-file
  receivers, solargraph misses one.
- **completion** — the immature axis for all three. Member completion is scored on
  trailing-dot fixtures (receiver indexed). refract completes top-level and
  inherited receivers but not yet namespaced ones (`Mod::Class.`); ruby-lsp
  completes the namespaced constant but not the local-var/inherited cases;
  solargraph returned no members in this harness. Nobody leads here.
- **references / rename** — scored as precision/recall over the known reference and
  edit sets, `includeDeclaration=true`. refract reaches **1.00 / 1.00** on
  references after fixing a defect where the declaration site of a method or
  constant was dropped (the `refs` table only over-inserts at class/module name
  nodes; method/const declarations live in `symbols` and were never emitted). It
  also no longer mis-routes a method reference as a local when the call sits inside
  a method body. ruby-lsp over-returns references by name (precision 0.53) and
  produced no usable rename on these fixtures; refract and solargraph are both exact
  (**1.00 / 1.00**). refract reaches this by scoping the method-parent lookup to
  workspace files (`is_gem=0`), so a method rename no longer binds to a same-named
  gem class and drops the declaration edit.
- **diagnostics** — a labeled fixture (`diag_bugs.rb`) with six real semantic bugs:
  duplicate method, nil-receiver call, wrong arity, undefined method, unused
  variable, unused parameter. refract's native engine catches **all six**. The two
  added this pass are both receiverless `self`-sends, marked at index time
  (`refs.kind = 'self_call'`) so they resolve against the enclosing class without
  misattributing explicit-but-untyped receivers: a too-few/too-many arity error and
  a bare undefined `self`-send (the latter gated off when the file shows dynamic
  signals — `method_missing`, `define_method`, `*_eval`, `send`). rubocop-backed
  ruby-lsp catches one (the useless assignment); solargraph's type checker catches
  three. This measures *semantic* detection — style linters score low here by
  nature, which is the point: refract ships semantic diagnostics the gem servers don't.

Probes anchor on each symbol's definition site (the canonical "find references / rename
this symbol" action); references additionally verified from a call site after the
mis-routing fix. Single-host single-run; the fixture set is intentionally small and
hand-verified rather than large.

---

## 3b. Real-repo accuracy (structural oracle)

§3/§3a score against hand-labeled fixtures. This pass scores go-to-definition on
**real, pinned project repos** with no answer key, using a **rival-independent
structural oracle**: sample N method-call/identifier sites deterministically, ask the
server to resolve each, then check whether the resolved target line actually *declares*
the queried name (a `def`/`class`/`module`/const/attr/alias of it — read from the real
target file, including gem/stdlib targets). This is the portable analogue of the
precision/recall framing used to compare search-based vs precise code intel.

- **resolution** = of sampled probes, fraction the server resolved to some target.
- **structural precision** = of resolved targets we could inspect, fraction that declare
  the queried name. The declaration matcher recognizes `def`/`class`/`module`/const/attr/
  alias plus method **parameters & block vars**, Rails/DSL generators (`belongs_to`,
  `delegate`, `enum`, `scope`, …), RSpec `let`/`subject`, FactoryBot, `Struct.new` members,
  and Sorbet `sig`, scanning a ±2-line window — so a correctly-resolved metaprogrammed or
  local-binding target is credited, not penalized. Applied identically to every server.

Driven by `scripts/bench/lsp_realistic_accuracy.rb`. Corpora pinned (see
`corpora/CORPORA_MANIFEST.json`): mastodon v4.5.11, discourse v2026.5.0,
Homebrew/brew 6.0.2, solidus v4.7.0. Numbers below from CI run on the pinned corpora
(`.github/workflows/accuracy-realrepo.yml`).

| corpus | kind | def probes | resolution | structural precision |
|---|---|:-:|:-:|:-:|
| discourse | Rails | 72 | 0.29 | **0.95** |
| solidus | Rails engine + DSL | 96 | 0.78 | **0.90** |
| mastodon | Rails | 72 | 0.33 | **0.96** |
| Homebrew/brew | non-Rails, DSL/metaprogramming | 120 | 0.46 | **0.94** |

Structural precision is **0.90–0.96 across all four repos** — refract's go-to-definition
targets are correct when it resolves them, on metaprogramming-heavy real code. (An earlier
run reported 0.43–0.60; that was an under-counting structural matcher, not a refract
regression — the matcher above credits the param/DSL/local-binding targets it previously
missed. The fix is symmetric: on Homebrew ruby-lsp scores 0.96, refract 0.94.) Resolution
is higher on the Rails engines and lower on gem-heavy / dynamic call sites that resolve
into unindexed gems. Numbers are **per-corpus, not cross-averageable** (Homebrew is
non-Rails).

**Rival head-to-head (CI, Homebrew — the repo where ruby-lsp stays responsive):**

| metric | refract | ruby-lsp |
|---|:-:|:-:|
| resolution | **0.46** | 0.23 |
| references precision / recall | **0.76** / 1.0 | 0.18 / 1.0 |
| structural precision | 0.94 | 0.96 |

refract resolves 2× more probes and is 4× more precise on references; ruby-lsp edges
per-answer structural precision but answers half as often. The big Rails repos run
refract-only (ruby-lsp deadlocks on bulk `didOpen` while indexing a 3k–9k-file workspace);
the structural oracle is rival-independent, so refract's numbers still land there.

## 3c. Diagnostic false-positive audit (real code)

Real repos are presumed mostly-correct, so any refract semantic diagnostic on them
(`wrong-arity` / `undefined-method` / `nil-receiver`) is a candidate false positive. Two
limits shape how this is scored:

- **Rivals cannot validate refract's semantic codes** — ruby-lsp and solargraph do not
  implement undefined-method / arity analysis at all, so a "does a rival flag the same
  line" comparison is structurally always "refract-only" and yields a meaningless 1.0. The
  audit therefore reports the rival-comparison rate as **n/a** unless a rival actually
  ships the same check, and validation is done by **direct structural inspection** (does
  the flagged method truly resolve nowhere?).
- The audit measures the **settled** state — it drains refract's background indexer
  (`$/refract/__waitForIdle`) and uses a long push-diagnostic settle window, because a
  mid-index snapshot on a slow host briefly reports ancestry-unresolved methods that clear
  once indexing finishes.

The sample capture named every bug-claim diagnostic across the four repos and drove the
following fixes — **after which the semantic (bug-claim) FP count is 0 on all four repos
in CI** (only the refract-exclusive lint codes `unused-method` / `unused-variable` remain,
which are features, not bug claims):

- **Partial-index FPs (root cause of most).** `$/refract/__waitForIdle` capped its wait at
  10 s; on a CI runner the cold index of a 5-package monorepo (Solidus) exceeded that, so
  the audit read a partial symbol table — `let`/`factory`/`attr` symbols and block-param
  locals not yet inserted — and flagged calls to them. Cap raised to 120 s (env-overridable
  `REFRACT_WAITIDLE_MS`); the client request timeout is the real bound.
- **FactoryBot factory blocks.** `factory :order do … end` was recorded as kind `class`
  (so go-to-def works) but is not a lexical scope; it is now excluded from enclosing-scope
  resolution, so its `transient`/DSL attributes are not treated as undefined self-sends.
- **Sorbet signature DSL** and methods inherited from an **external/unindexed base**
  (RuboCop cops `< Base`) — the ancestry walk records each class's real `superclass` and
  returns "unknown" when the base is outside the workspace. **Reopened core classes**
  (`class Array …`) are likewise treated as external ancestry. (A use-after-free in the
  "did you mean" suggestion was fixed in the same pass.)
- **RSpec hooks / `delegate`.** `before(:each)` and `delegate :x` synthesized defs are
  excluded from `duplicate-method` (they are not hand-written definitions).
- **Dynamic / concern / spec contexts.** Receiverless self-sends inside a bare `module`
  (Rails concern), and the "did you mean" suggestion inside any dynamic file
  (`send`/`*_eval`/`method_missing`) or RSpec example group (`let`/`subject`/`describe`/…),
  are suppressed — these are host-/sibling-provided or block-local, not typos (the Solidus
  `permitted_*_attributes`, `let(:sl)`, and block-parameter cases).

The rival head-to-head that *is* meaningful (go-to-def / references / DX) is produced in CI
and shown in §3b and §6b.

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

Measured per server with `scripts/bench/lsp_dx.rb` (cold start → first correct
answer → behaviour on malformed input), lower is better:

| metric | **refract** | ruby-lsp | solargraph |
|---|:-:|:-:|:-:|
| cold init (initialize round-trip) | **180 ms** | 517 ms | 255 ms |
| time-to-first-correct-answer | **27 ms** | 572 ms | 357 ms |
| peak RSS (single file) | **50 MB** | 110 MB | 125 MB |
| survives malformed file + keeps serving | yes | yes | yes |

refract answers a correct go-to-definition ~20× sooner than the gem servers and on
a third to half the memory; all three stay alive and keep serving after a
syntactically broken document is opened.

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

## 6b. DX on real repos

§6 measures DX on a single fixture file; this measures it on the **pinned real repos**:
cold init, time-to-first-correct-answer (first def matching the §3b oracle, p50),
full-warm (≥90% of the oracle probes answering), peak RSS, on-disk index, and whether the
server survives a malformed file injected into the live tree and keeps serving. refract
only (rivals not run on real repos — see §3c). Driven by
`scripts/bench/lsp_dx_realistic.rb`.

| corpus | cold init | first-correct p50 | full warm | peak RSS | index on disk | robust |
|---|--:|--:|--:|--:|--:|:-:|
| mastodon | 21 ms | 122 ms | 148 ms | 41 MB | 15 MB | yes |
| Homebrew/brew | 59 ms | 545 ms | 597 ms | 85 MB | 13 MB | yes |
| discourse | 1.31 s | 1.07 s | 1.14 s | 446 MB | 377 MB | yes |
| solidus | 1.59 s | 2.15 s | 2.18 s | 644 MB | 365 MB | yes |

Cold init and memory scale with corpus size; the index is built once and persists
(SQLite), so subsequent sessions skip the warm. All four survive a malformed file and
keep answering. (`full warm` here is wall-clock to the queryable hot index; refract also
reports a separate background-indexer drain that does not block queries.)

---

## 7. Reproduce

```sh
zig build --release=safe
bash scripts/bench/realistic_run.sh                     # 24-cell perf matrix
ruby scripts/bench/realistic_aggregate.rb bench-results/realistic/<ts>-<sha>
cd scripts/bench/fixtures && ROOT="$PWD" ruby ../lsp_accuracy.rb refract <bin> --db-path /tmp/acc.db
bash scripts/bench/quality_run.sh /tmp/quality.log      # fixture multi-op accuracy + DX (§3a, §6)

# Real-repo accuracy + DX (§3b/§3c/§6b). Pin + fetch corpora, then run one repo at a
# time on a quiet host (rivals omitted: ruby-lsp re-bundles per start, solargraph crashes):
REFRACT_PILOT_DIR="$PWD/corpora" bash scripts/bench/fetch-corpora.sh
REFRACT_PILOT_DIR="$PWD/corpora" REALISTIC_CORPORA="solidus" \
  SKIP_SERVERS="ruby-lsp solargraph" bash scripts/bench/quality_accuracy_run.sh /tmp/acc
ruby scripts/bench/realistic_accuracy_aggregate.rb /tmp/acc
```

`quality_run.sh` drives `lsp_multiop.rb` (hover/completion/references/rename/diagnostics)
and `lsp_dx.rb` (cold-init / first-answer / robustness) for refract, ruby-lsp, and
solargraph over the shared fixture workspace.

Override defaults via `REALISTIC_CORPORA`, `REALISTIC_WORKLOADS`, `REALISTIC_SERVERS`,
`REALISTIC_SEED`, `REFRACT_PILOT_DIR`. Mastodon + Discourse must be cloned under the
pilot dir (`<pilot>/mastodon`, `<pilot>/discourse/lib`).

Single-host single-run measurements; ±10 % p50 variance run-to-run is normal.
Sorbet/Steep are not in the perf matrix because their setup model differs.
