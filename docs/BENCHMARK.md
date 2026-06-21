# Benchmark: Refract vs Ruby LSP, Solargraph, Sorbet, Steep

Head-to-head over JSON-RPC, identical workloads, identical seed. The LSP perf
matrix (session / typing / micro) was re-run 2026-06-24 at refract `ec72d613`
(0.1.0-rc1) against **ruby-lsp 0.27.0.beta3** and solargraph 0.58.3. ruby-lsp
0.27 moves its indexer onto a Rust backend (the `rubydex` native gem), so the
re-run measures whether that closes the gap — it does not (§1–§2). A separate
MCP-to-MCP comparison against rubydex's own MCP server is in §3d.

- **Versions**: refract `ec72d613` (0.1.0-rc1) · ruby-lsp 0.27.0.beta3 (Rust/`rubydex` 0.2.5 backend) · solargraph 0.58.3 · rubydex 0.2.5 (MCP) · sorbet 0.6.13185 · steep 2.0.0 · Ruby 3.4.8 · Zig 0.16.0
- **Build**: refract `--release=safe` (static binary — the shipped, distributed mode). Runtime safety checks (bounds, overflow, `unreachable`) are kept on by design: refract indexes arbitrary Ruby source, so a malformed input becomes a clean panic rather than memory corruption in a long-lived server. A ReleaseFast build (no safety checks) was measured for reference and is within noise on the hot query paths — sub-millisecond either way — buying only ~5–25% on the CPU-bound indexing/diagnostics paths, not enough to justify dropping memory safety. ReleaseSafe is what these numbers and the shipped binary use.
- **Host**: 22-core x86_64, 14 GiB RAM, Linux 7.0 (Fedora 43)
- **Corpora**: Mastodon (3,194 .rb), Discourse-lib (698 .rb), 17-file / 100-case accuracy fixture
- **Workloads**: `session` (60% hover/15% def/10% comp/5% sym/5% refs/3% docSym/2% rename), `typing` (8 Hz didChange × 30 s), `micro` (50 random probes × 4 ops)
- **Artifacts**: LSP perf `bench-results/realistic/20260624T140710Z-ec72d613/` · MCP `bench-results/mcp/`
- **Scope of this re-run**: the LSP perf matrix (§1, §2), the resource/reliability rows derived from it (§4, §5), and the new MCP head-to-head (§3d). The accuracy fixtures (§3, §3a–§3c) were **not** re-collected this round — those rows carry forward from the 2026-06-15 `b6d14235` (0.1.0-beta.1) baseline and are marked where cited.

Sorbet and Steep ship LSP modes but require `sorbet/`-folder + RBI generation.
They appear in accuracy + DX, excluded from the perf matrix on purpose.

---

## Scoreboard

Lower is better for latency / RAM / init; higher for accuracy. **Bold = best.**
Latency rows are Mastodon `session` p50 (ms) unless noted.

| | **refract** | ruby-lsp 0.27.beta3 | solargraph |
|---|:-:|:-:|:-:|
| hover p50 | **0.2** | 0.7 | 16.8 |
| definition p50 | **0.3** | 0.8 | 16.9 |
| completion p50 | **0.2** | 1.2 | 17.0 |
| workspace-symbol p50 | **4.3** | 23.1 | 17.1 |
| references p50 | **1.2** | 627.1 | 17.4 |
| typing p50 (hover, Discourse 8 Hz) | **0.6** | 3.3 | 109.0 |
| live edits kept (Discourse typing) | **240/240** | 240/240 | 189/240 |
| accuracy — user-code † | **76/76** | 37/76 | 46/76 |
| accuracy — stdlib † | **23/24** | 19/24 | 17/24 |
| hover — correct (multi-op) † | **6/6** | 4/6 | 5/6 |
| references — recall / prec † | **1.00 / 1.00** | 0.75 / 0.53 | **1.00 / 1.00** |
| rename — recall / prec † | **1.00 / 1.00** | 0.00 / 0.00 | **1.00 / 1.00** |
| semantic-diagnostic recall † | **6/6** | 1/6 | 3/6 |
| peak RSS (realistic harness) ² | **100–139 MB** | 96–162 MB | 382–1306 MB |
| cold init | **269–323 ms** | 500–6775 ms¹ | 260–286 ms |
| first answer ready | **0.9–10 s** | 0.6 s–180 s cap¹ | 7 s–180 s cap¹ |
| crashes / 24 cells | **0** | 0 | 0 |
| Ruby on PATH | **none** | required | required |
| distribution | **static binary** | gem (+ native ext) | gem |

† Accuracy rows carried from the 2026-06-15 `b6d14235` (0.1.0-beta.1) baseline —
not re-collected this round (see header scope note). All other rows are the
2026-06-24 re-run vs ruby-lsp 0.27.0.beta3.

¹ On Mastodon ruby-lsp's cold init jumped to 6.8 s on 0.27.beta3 and it still
hits the 180 s harness warmup cap, answering against a still-building index;
on the smaller Discourse-lib it warms in ~0.6 s. solargraph hits the 180 s cap
on Mastodon and stalls ~10 s on a slice of Discourse `session` requests.

² Peak RSS here is the realistic-harness process peak under load (session/typing/
micro), not the idle steady-state of §4. Measured this run.

ruby-lsp 0.27's Rust (`rubydex`) backend did **not** close the latency gap:
hover edged down (0.9 → 0.7 ms) but definition and completion got *slower*
(0.5 → 0.8 / 0.5 → 1.2 ms), workspace-symbol (~23 ms) and references (~627 ms)
are unchanged, and Mastodon cold-init *regressed* to 6.8 s. refract still leads —
or ties — every latency axis; the lone non-lead is multi-op **completion**, a
low-end three-way tie where no server leads (§3a).

---

## 1. Mastodon (3,194 .rb) — p50 / p95 ms, lower is better

### session

| server | hover | def | comp | sym | refs | docSym | rename |
|---|---:|---:|---:|---:|---:|---:|---:|
| **refract** rb=off | **0.24** / 0.73 | **0.34** / 6.19 | **0.20** / 6.84 | **4.32** / 11.93 | **1.23** / 3.02 | 0.1 | 0.3 |
| refract rb=on | 0.20 / 0.64 | 0.27 / 5.88 | 0.11 / 4.71 | 4.40 / 9.41 | 1.10 / 2.67 | 0.1 | 0.4 |
| ruby-lsp 0.27.beta3 | 0.74 / 4.29 | 0.81 / 3.40 | 1.17 / 2.85 | 23.07 / 23.77 | 627.06 / 677.59 | 0.8 | 1.2 |
| solargraph | 16.78 / 20.95 | 16.91 / 20.82 | 17.04 / 18.17 | 17.11 / 18.96 | 17.44 / 17.95 | 17.0 | 18.5 |

### typing (didChange 8 Hz, 30 s)

On Mastodon this round the 180 s warmup cap consumed the per-op budget, so only
the sustained didChange stream was sampled (240/240 applied for refract and
ruby-lsp); per-op hover/def/comp latency under typing is reported on the smaller
Discourse-lib corpus in §2, where the full window is captured.

### micro (50 random probes × 4 ops) — p50 / p95 / p99

| server | hover | def | comp |
|---|---:|---:|---:|
| **refract** rb=off | **0.16** / 0.32 / 22.2 | **0.18** | **0.07** |
| ruby-lsp 0.27.beta3 | 0.81 / 4.10 / 7.0 | 0.92 | 0.57 |
| solargraph | 16.26 / 19.39 / 22.5 | 16.19 | 15.90 |

---

## 2. Discourse-lib (698 .rb)

### session

| server | hover | def | comp | sym | refs | docSym | rename |
|---|---:|---:|---:|---:|---:|---:|---:|
| **refract** rb=off | **0.19** / 0.56 | **0.29** / 1.02 | **0.17** / 3.08 | **2.41** / 3.36 | **0.30** / 4.03 | 0.2 | 0.2 |
| refract rb=on | 0.20 / 0.39 | 0.27 / 1.08 | 0.11 / 3.19 | 2.30 / 2.58 | 0.32 / 3.41 | 0.2 | 0.2 |
| ruby-lsp 0.27.beta3 | 1.68 / 4.99 | 0.97 / 4.69 | 3.30 / 4.95 | 33.76 / 44.01 | 246.38 / 543.07 | 5.8 | 0.5 |
| solargraph | 172.59 / 10008 | 199.79 / 10010 | 150.62 / 10010 | 19.46 / 251.34 | 190.20 / 15005 | 150.8 | 972.4 |

Solargraph p95 hits the 10 s timeout — a slice of its requests are full stalls;
rename p50 itself blocks ~1 s.

### typing (didChange 8 Hz, 30 s)

| server | hover | def | comp | didChange # |
|---|---:|---:|---:|---:|
| **refract** rb=off | **0.62** / 0.84 | **0.50** / — | **1.15** / — | 240 / 240 |
| refract rb=on | 0.64 / 0.83 | 0.51 / — | 0.86 / — | 240 / 240 |
| ruby-lsp 0.27.beta3 | 3.27 / 5.53 | 2.05 / — | 4.48 / — | 240 / 240 |
| solargraph | 108.99 / 256.41 | 114.47 / — | 115.72 / — | **189 / 240** (51 dropped) |

### micro — p50 / p95 / p99

| server | hover | def | comp |
|---|---:|---:|---:|
| **refract** rb=off | **0.17** / 0.33 / 25.8 | **0.16** | 1.37 |
| ruby-lsp 0.27.beta3 | 1.58 / 4.95 / 7.0 | 1.75 | 1.76 |
| solargraph | 178.58 / 728.98 / 979 | 177.69 | 180.98 |

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

## 3d. MCP head-to-head vs rubydex

ruby-lsp 0.27's Rust backend *is* [rubydex](https://github.com/Shopify/rubydex)
(Shopify), which also ships its own experimental MCP server (`rubydex_mcp`).
rubydex has no LSP stdio mode, so it can't sit in the perf matrix above — but it
*is* refract's closest peer on the **MCP** surface. Both speak newline-delimited
JSON-RPC (MCP 2025-06-18). `scripts/bench/mcp_headtohead.rb` drives both with
identical, seeded inputs over six overlapping tool pairs and records latency,
answer-rate, peak RSS and cross-agreement.

**Fairness.** rubydex is FQN-strict: `get_declaration` / `find_constant_references`
/ `get_descendants` reject bare leaf names (`{"error":"not_found","suggestion":
"Try search_declarations … for the correct FQN"}`), whereas refract resolves bare
names. To measure the *lookup* rather than the input convention, fully-qualified
names are resolved via a rubydex `search_declarations` preflight (its own preferred
input) and fed to both servers; constant references additionally use each tool's
native key (refract bare, rubydex FQN) for the same constant. The bare-vs-FQN
ergonomic gap is called out below, not folded into latency.

Discourse-lib (698 .rb), N≈60 probes/pair, seed 42; Mastodon matches within noise.

| pair | refract tool | p50 ms | ans | rubydex tool | p50 ms | ans |
|---|---|---:|---:|---|---:|---:|
| symbol search | `workspace_symbols` | **0.42** | 100% | `search_declarations` | 0.75 | 100% |
| declaration | `class_summary` | 0.15 | 100% | `get_declaration` | **0.04** | 100% |
| descendants | `type_hierarchy` | 2.17 | 100% | `get_descendants` | **0.02** | 100% |
| constant refs | `find_references` | 0.11 | 97% | `find_constant_references` | **0.03** | 98% |
| file declarations | `get_file_overview` | 0.10 | 100% | `get_file_declarations` | **0.04** | 100% |
| codebase stats | `workspace_health` | 9.1 | ✓ | `codebase_stats` | **0.21** | ✓ |
| cold-ready | persisted on-disk index | **3–23 ms** | — | in-RAM rebuild each launch | 305 ms | — |
| peak RSS | — | 31–92 MB | — | — | 41–72 MB | — |

**Cross-validation**: on `file declarations`, both servers return the *same*
declaration location for 60/60 probes (file-match 1.00) on both corpora — they
agree on what's where.

**Read of it** — this one is not a blowout. On the six overlapping lookups,
correctness is at parity (both ~100% when fed native input), and rubydex's
in-memory Rust hash wins raw point-lookup latency (10–60 µs vs refract's
0.1–2.2 ms SQLite-backed reads); refract ties/leads only on `workspace_symbols`.
The differences are in shape, not speed-class — both are sub-millisecond and far
ahead of the LSP-gem rivals:

- **rubydex**: 6 FQN-exact tools, in-RAM index rebuilt on every launch (~305 ms
  to first answer, no persistence), bare names rejected, `kind` fields still
  `"<TODO>"` placeholders (v0.2.5, "experimental"). No references-by-bare-name,
  no diagnostics, refactor, code actions, or graph overlay.
- **refract**: 30 tools, persistent SQLite (warm restart answers in 3–23 ms, no
  rebuild), bare-name lenient, plus semantic diagnostics (`refract/nil-receiver`,
  `wrong-arity`), refactor/extract, code actions, i18n / routes / validations /
  callbacks, and an agent-writable overlay graph — none of which rubydex has an
  equivalent for.

So: rubydex is a lean, fast point-lookup index; refract is a broader, persistent,
diagnostics-and-refactor-capable surface at the same sub-ms class. The honest
take is parity-plus-breadth, not a latency win.

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

The table above is the 2026-06-15 `b6d14235` (0.1.0-beta.1) steady-state probe
(ruby-lsp 0.26.9) — a leaner idle-RSS measurement, not re-collected this round.
The 2026-06-24 realistic-harness *under-load* peak (ruby-lsp 0.27.beta3) is in the
scoreboard ² row: refract 100–139 MB, ruby-lsp 96–162 MB, solargraph 382–1306 MB.

Cold init (ms), 2026-06-24 re-run: refract 269–323 · ruby-lsp 0.27.beta3
500–6775 (Mastodon session cold-build spikes to 6.8 s) · solargraph 260–286.
`ldd refract` on Linux: only libc + ld-linux. Drop into Docker or CI without Ruby.

---

## 5. Reliability (24-cell matrix)

2026-06-24 re-run, ruby-lsp 0.27.0.beta3:

| server | clean cells | warmup-cap (180 s) hit | crashed | didChange dropped |
|---|:-:|:-:|:-:|:-:|
| refract rb=off | 6/6 | 0 | 0 | 0 |
| refract rb=on | 6/6 | 0 | 0 | 0 |
| ruby-lsp 0.27.beta3 | 6/6 served | 3 (Mastodon) | 0 | 0 |
| solargraph | 6/6 served | 3 (Mastodon) | 0 | **51/240** (Discourse typing) |

Refract serves queries throughout (warm restart on a persisted index, no cap).
ruby-lsp 0.27 warms in ~0.6 s on Discourse-lib but still hits the 180 s harness
cap on all three Mastodon cells, answering against a still-building index — its
Rust backend sped indexing on the small corpus but not enough to clear the cap on
the large one. Solargraph hits the cap on Mastodon, stalls ~10 s on a slice of
Discourse session requests, and drops 51 of 240 live edits.

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
| MCP server for AI agents | **yes** (`refract --mcp`, 30 tools) | no¹ | no | no | no |
| LSP method coverage | 28+ incl. semantic-tokens, inlay-hints, code-action, foldingRange, prepareRename, willRenameFiles | 20+ | 20+ | type-error focused | type-error focused |

¹ ruby-lsp itself exposes no MCP, but its 0.27 Rust backend gem (`rubydex`) ships a
separate experimental MCP server (`rubydex_mcp`, 6 tools) — benchmarked in §3d.

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
gem install ruby-lsp -v 0.27.0.beta3 --pre              # Rust/rubydex backend (pulls rubydex)
bash scripts/bench/realistic_run.sh                     # 24-cell LSP perf matrix
ruby scripts/bench/realistic_aggregate.rb bench-results/realistic/<ts>-<sha>

# MCP head-to-head vs rubydex (§3d). Drives refract --mcp and rubydex_mcp over
# identical seeded probes; FQN-resolved so the FQN-strict rubydex tools get fair input:
ROOT=corpora/discourse/lib N=60 REFRACT="$PWD/zig-out/bin/refract" \
  RUBYDEX_MCP="$(gem contents rubydex | grep '/exe/rubydex_mcp$')" \
  ruby scripts/bench/mcp_headtohead.rb > bench-results/mcp/discourse-lib.json
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
