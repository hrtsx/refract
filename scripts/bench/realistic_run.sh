#!/usr/bin/env bash
# Realistic-bench orchestrator. Runs the matrix:
#   corpora   : mastodon, discourse-lib (override with REALISTIC_CORPORA)
#   workloads : session, typing, micro
#   servers   : refract, solargraph, ruby-lsp
#   rubocop   : refract is run with both on/off; others use their default
# Captures one JSON per cell to bench-results/realistic/<ts>/<corpus>__<server>__<workload>[__rubocop].json
# Prints a one-line summary per cell.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DRIVER_DIR="$REPO_ROOT/scripts/bench"
REFRACT="${REFRACT:-$REPO_ROOT/zig-out/bin/refract}"
PILOT_DIR="${REFRACT_PILOT_DIR:-$REPO_ROOT/corpora}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
if ! git -C "$REPO_ROOT" diff --quiet 2>/dev/null || \
   ! git -C "$REPO_ROOT" diff --quiet --cached 2>/dev/null; then
  GIT_SHA="${GIT_SHA}-dirty"
fi
OUT_DIR="${REFRACT_REALISTIC_OUT:-$REPO_ROOT/bench-results/realistic/${TS}-${GIT_SHA}}"
mkdir -p "$OUT_DIR"

# Refuse a Debug refract — it runs queries ~5-6x slower and fakes a regression.
# ReleaseSafe is stripped; Debug carries debug_info / is not stripped.
if [[ -x "$REFRACT" ]] && file "$REFRACT" 2>/dev/null | grep -q 'not stripped\|with debug_info'; then
  echo "refract at $REFRACT is a Debug build — perf numbers would be bogus." >&2
  echo "rebuild release first: zig build --release=safe" >&2
  exit 2
fi

CORPORA_RAW="${REALISTIC_CORPORA:-mastodon discourse-lib}"
WORKLOADS_RAW="${REALISTIC_WORKLOADS:-session typing micro}"
SERVERS_RAW="${REALISTIC_SERVERS:-refract solargraph ruby-lsp}"

corpus_root() {
  case "$1" in
    mastodon)        echo "$PILOT_DIR/mastodon" ;;
    discourse-lib)   echo "$PILOT_DIR/discourse/lib" ;;
    discourse)       echo "$PILOT_DIR/discourse" ;;
    homebrew)        echo "$PILOT_DIR/homebrew/Library/Homebrew" ;;
    solidus)         echo "$PILOT_DIR/solidus" ;;
    gitlabhq)        echo "$PILOT_DIR/gitlabhq" ;;
    *)               echo "$1" ;;  # treat unknown name as a literal path
  esac
}

reset_refract_db() {
  local root="$1"
  local db
  db="$(cd "$root" && "$REFRACT" --print-db-path 2>/dev/null)"
  [[ -n "$db" ]] && rm -f "$db" "$db-wal" "$db-shm" 2>/dev/null
}

run_cell() {
  local corpus="$1" server="$2" workload="$3" rubocop="$4" reset_db="${5:-no}"
  local root; root="$(corpus_root "$corpus")"
  if [[ ! -d "$root" ]]; then
    echo "SKIP $corpus $server $workload (root missing: $root)" >&2
    return
  fi

  local cmd_args=()
  case "$server" in
    refract)
      [[ "$reset_db" == "yes" ]] && reset_refract_db "$root"
      cmd_args=("$REFRACT")
      [[ "$rubocop" == "off" ]] && cmd_args+=("--disable-rubocop")
      ;;
    solargraph)  cmd_args=(solargraph stdio) ;;
    ruby-lsp)    cmd_args=(ruby-lsp) ;;
    *)           echo "unknown server: $server" >&2; return 1 ;;
  esac

  local label="${corpus}__${server}__${workload}"
  [[ "$server" == "refract" ]] && label+="__rubocop-${rubocop}"
  local out_json="$OUT_DIR/${label}.json"
  local out_log="$OUT_DIR/${label}.log"

  echo ">>> $label" >&2
  ROOT="$root" WORKLOAD="$workload" SEED="${REALISTIC_SEED:-42}" \
    timeout 600 ruby "$DRIVER_DIR/lsp_realistic.rb" "$server" "${cmd_args[@]}" \
    > "$out_json" 2> "$out_log"
  local rc=$?
  if (( rc != 0 )); then
    echo "    FAIL rc=$rc, see $out_log" >&2
    return
  fi

  # One-line summary
  local summary
  summary=$(jq -r '
    "init=" + (.initialize_ms|tostring) + "ms" +
    "  warm=" + (.warmup_first_def_ms|tostring) + "ms" +
    "  rss=" + (.peak_rss_mb|tostring) + "MB" +
    "  hover_p50=" + ((.per_method.hover.p50_ms // "-")|tostring) +
    "  def_p50=" + ((.per_method.definition.p50_ms // "-")|tostring) +
    "  comp_p50=" + ((.per_method.completion.p50_ms // "-")|tostring) +
    "  sym_p50=" + ((.per_method.symbol.p50_ms // "-")|tostring) +
    "  refs_p50=" + ((.per_method.references.p50_ms // "-")|tostring) +
    "  diagF_p50=" + ((.per_method.diag_first_ms.p50_ms // "-")|tostring) +
    "  diagS_p50=" + ((.per_method.diag_settle_ms.p50_ms // "-")|tostring)
  ' "$out_json" 2>/dev/null)
  echo "    $summary" >&2
}

read -ra CORPORA <<< "$CORPORA_RAW"
read -ra WORKLOADS <<< "$WORKLOADS_RAW"
read -ra SERVERS <<< "$SERVERS_RAW"

echo "# Realistic bench"
echo "out_dir : $OUT_DIR"
echo "corpora : ${CORPORA[*]}"
echo "workloads: ${WORKLOADS[*]}"
echo "servers : ${SERVERS[*]}"
echo "git_sha : $GIT_SHA"
echo

for corpus in "${CORPORA[@]}"; do
  for server in "${SERVERS[@]}"; do
    if [[ "$server" == "refract" ]]; then
      # rubocop=off: reset DB once, then run all 3 workloads warm
      first="yes"
      for workload in "${WORKLOADS[@]}"; do
        run_cell "$corpus" "$server" "$workload" "off" "$first"
        first="no"
      done
      # rubocop=on: reset DB once, then run all 3 workloads warm
      first="yes"
      for workload in "${WORKLOADS[@]}"; do
        run_cell "$corpus" "$server" "$workload" "on" "$first"
        first="no"
      done
    else
      for workload in "${WORKLOADS[@]}"; do
        run_cell "$corpus" "$server" "$workload" "n/a" "no"
      done
    fi
  done
done

echo
echo "results in: $OUT_DIR"
