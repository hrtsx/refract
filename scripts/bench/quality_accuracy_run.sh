#!/usr/bin/env bash
# Real-repo accuracy + DX runner. For each corpus: one consensus-accuracy pass
# (all servers together, writes per-corpus JSON + oracle cache), then a per-server
# DX pass that replays the cached oracle. Mirrors realistic_run.sh conventions.
#
# Usage: ./scripts/bench/quality_accuracy_run.sh [out-dir]
# Env:   REALISTIC_CORPORA="mastodon discourse homebrew solidus"
#        REFRACT_PILOT_DIR (default $REPO_ROOT/corpora)  PROBES_LIMIT (default 300)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DRIVER_DIR="$REPO_ROOT/scripts/bench"
REFRACT="${REFRACT:-$REPO_ROOT/zig-out/bin/refract}"
PILOT_DIR="${REFRACT_PILOT_DIR:-$REPO_ROOT/corpora}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
OUT_DIR="${1:-$REPO_ROOT/bench-results/accuracy/${TS}-${GIT_SHA}}"
mkdir -p "$OUT_DIR"

CORPORA_RAW="${REALISTIC_CORPORA:-mastodon discourse homebrew solidus}"
SKIP_SERVERS="${SKIP_SERVERS:-}"
SERVERS=()
for s in refract ruby-lsp solargraph; do
  [[ " $SKIP_SERVERS " == *" $s "* ]] || SERVERS+=("$s")
done

corpus_root() {
  case "$1" in
    mastodon)      echo "$PILOT_DIR/mastodon" ;;
    discourse)     echo "$PILOT_DIR/discourse" ;;
    discourse-lib) echo "$PILOT_DIR/discourse/lib" ;;
    homebrew)      echo "$PILOT_DIR/homebrew/Library/Homebrew" ;;
    solidus)       echo "$PILOT_DIR/solidus" ;;
    gitlabhq)      echo "$PILOT_DIR/gitlabhq" ;;
    *)             echo "$1" ;;
  esac
}

# Diagnostic FP audit only on the metaprogramming-heavy repos.
diag_audit_for() { case "$1" in homebrew|solidus) echo 1 ;; *) echo 0 ;; esac; }

# Per-repo upper bound on probes. The big Rails apps (3k-9k .rb files) make the
# rivals re-resolve a huge workspace per query; capping probes keeps each repo
# inside the driver's soft deadline so it emits complete data rather than getting
# killed mid-run. Effective limit = min(PROBES_LIMIT, cap).
probe_cap()  { case "$1" in mastodon|discourse|gitlabhq) echo 90 ;; solidus) echo 120 ;; *) echo 100000 ;; esac; }
min() { (( $1 < $2 )) && echo "$1" || echo "$2"; }

# Sampled-file count per repo. The largest repos (discourse, gitlabhq) need fewer
# didOpen'd files so refract's setup (index drain + warm) fits the deadline.
max_files_for() { case "$1" in discourse|gitlabhq) echo 20 ;; mastodon) echo 30 ;; *) echo 40 ;; esac; }

# Per-repo deadline override. discourse is the biggest indexed tree; give its
# refract cold-index more room. Falls back to the global ACC_DEADLINE_S.
deadline_for() { case "$1" in discourse|gitlabhq) echo "${BIG_DEADLINE_S:-1500}" ;; *) echo "$ACC_DEADLINE_S" ;; esac; }

# Rivals (esp. ruby-lsp) deadlock on bulk didOpen while indexing a 3k-9k-file
# Rails workspace: they stop draining stdin, the driver blocks on a full pipe and
# is killed before producing anything (confirmed on mastodon/discourse/solidus,
# each hung the full external timeout). Run those repos refract-only — the
# structural oracle is rival-independent, so refract's resolution/precision still
# land. homebrew is small enough that ruby-lsp keeps draining → keep the
# head-to-head there. Override per repo with RIVALS_OK_REPOS.
RIVALS_OK_REPOS="${RIVALS_OK_REPOS:-homebrew}"
rivals_ok() { [[ " $RIVALS_OK_REPOS " == *" $1 "* ]] && echo 1 || echo 0; }

# Knobs (env-overridable). The driver enforces ACC_DEADLINE_S itself and exits 0
# with partial data; the external `timeout` is a hard backstop set above it.
ACC_DEADLINE_S="${ACC_DEADLINE_S:-1100}"
ACC_TIMEOUT_S="${ACC_TIMEOUT_S:-1500}"
DX_TIMEOUT_S="${DX_TIMEOUT_S:-600}"

have() { command -v "$1" >/dev/null 2>&1; }

echo "# Real-repo accuracy + DX"
echo "out_dir : $OUT_DIR"
echo "corpora : $CORPORA_RAW"
echo "git_sha : $GIT_SHA"
echo

for corpus in $CORPORA_RAW; do
  root="$(corpus_root "$corpus")"
  if [[ ! -d "$root" ]]; then
    echo "SKIP $corpus (root missing: $root)" >&2
    continue
  fi

  # Per-corpus server skip: the global SKIP_SERVERS, plus rivals forced off on the
  # big Rails repos where they deadlock. corpus_skip drives both the accuracy
  # driver and the DX loop below.
  corpus_skip="$SKIP_SERVERS"
  if [[ "$(rivals_ok "$corpus")" != 1 ]]; then
    corpus_skip="$corpus_skip ruby-lsp solargraph"
    echo "    ($corpus: refract-only — rivals deadlock on this repo)" >&2
  fi

  # Rival setup: bundle install where a Gemfile exists (outside timing). Skip it
  # entirely when this repo runs refract-only. Failure is non-fatal.
  if [[ "$(rivals_ok "$corpus")" == 1 ]] && [[ -f "$root/Gemfile" ]] && have bundle; then
    echo ">>> bundle install ($corpus)" >&2
    ( cd "$root" && timeout 600 bundle install --quiet >/dev/null 2>&1 ) || \
      echo "    bundle install failed for $corpus (continuing)" >&2
  fi

  # NOTE: refract's gem-method recall is proven hermetically in the Zig test suite
  # ("go-to-def resolves a method defined in an indexed gem file"), not via a CI
  # `bundle install` — native gem builds fail on bare runners and only add noise.

  oracle="$OUT_DIR/${corpus}__oracle.json"
  acc_json="$OUT_DIR/${corpus}__accuracy.json"
  eff_probes="$(min "${PROBES_LIMIT:-300}" "$(probe_cap "$corpus")")"
  eff_deadline="$(deadline_for "$corpus")"
  eff_maxfiles="$(max_files_for "$corpus")"
  # External hard backstop sits above the per-repo soft deadline.
  eff_timeout=$(( eff_deadline + 400 )); (( eff_timeout < ACC_TIMEOUT_S )) && eff_timeout="$ACC_TIMEOUT_S"
  echo ">>> accuracy: $corpus (probes=$eff_probes files=$eff_maxfiles deadline=${eff_deadline}s skip='$corpus_skip')" >&2
  ROOT="$root" SEED="${REALISTIC_SEED:-42}" PROBES_LIMIT="$eff_probes" MAX_FILES="$eff_maxfiles" \
    REFRACT="$REFRACT" DIAG_AUDIT="$(diag_audit_for "$corpus")" ORACLE_CACHE="$oracle" \
    ACC_DEADLINE_S="$eff_deadline" SKIP_SERVERS="$corpus_skip" \
    LSP_STDERR_LOG="$OUT_DIR/${corpus}__refract.stderr.log" \
    timeout --preserve-status -k 30 "$eff_timeout" ruby "$DRIVER_DIR/lsp_realistic_accuracy.rb" \
    > "$acc_json" 2> "$OUT_DIR/${corpus}__accuracy.log"
  rc=$?
  # rc 0 = clean (possibly partial via soft deadline); the driver also traps TERM
  # and emits partial data on the hard backstop. Treat a non-empty JSON as usable.
  if [[ ! -s "$acc_json" ]]; then
    echo "    FAIL accuracy $corpus rc=$rc (empty output; see ${corpus}__accuracy.log)" >&2
    continue
  fi
  (( rc != 0 )) && echo "    WARN accuracy $corpus exited rc=$rc (partial data kept)" >&2

  # Surface completion member-recall immediately (full table comes from the
  # aggregator). Rival-independent, so it lands even on refract-only repos.
  comp_line="$(ruby -rjson -e 'c=(JSON.parse(File.read(ARGV[0]))["completion"]||{})["refract"]; puts(c ? "completion(refract): recall=#{c["member_recall"]} resolution=#{c["resolution_rate"]} probes=#{c["probes"]}" : "completion: n/a")' "$acc_json" 2>/dev/null)"
  [[ -n "$comp_line" ]] && echo "    $comp_line" >&2

  [[ -f "$oracle" ]] || { echo "    no oracle cache for $corpus, skipping DX" >&2; continue; }

  for srv in "${SERVERS[@]}"; do
    [[ " $corpus_skip " == *" $srv "* ]] && continue
    case "$srv" in
      refract)    have "$REFRACT" || { echo "    skip DX refract (absent)" >&2; continue; }; cmd=("$REFRACT" --disable-rubocop) ;;
      ruby-lsp)   have ruby-lsp   || { echo "    skip DX ruby-lsp (absent)" >&2; continue; }; cmd=(ruby-lsp) ;;
      solargraph) have solargraph || { echo "    skip DX solargraph (absent)" >&2; continue; }; cmd=(solargraph stdio) ;;
    esac
    echo ">>> dx: $corpus / $srv" >&2
    ROOT="$root" ORACLE_CACHE="$oracle" \
      timeout "$DX_TIMEOUT_S" ruby "$DRIVER_DIR/lsp_dx_realistic.rb" "$srv" "${cmd[@]}" \
      > "$OUT_DIR/${corpus}__${srv}__dx.json" 2> "$OUT_DIR/${corpus}__${srv}__dx.log"
    (( $? != 0 )) && echo "    FAIL dx $corpus/$srv" >&2
  done
done

echo
echo "results in: $OUT_DIR"
