#!/usr/bin/env bash
# Capture a single bench snapshot (perf + accuracy across all three LSPs)
# into bench-results/<git-sha>-<timestamp>.json. Prints a one-line summary
# and a delta vs the most recent prior snapshot, if one exists.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESULTS_DIR="${REFRACT_BENCH_RESULTS:-$REPO_ROOT/bench-results}"
RUN_ALL="$REPO_ROOT/scripts/bench/run_all.sh"

if [[ ! -x "$RUN_ALL" ]]; then
  echo "missing or non-executable: $RUN_ALL" >&2
  exit 2
fi

mkdir -p "$RESULTS_DIR"

git_sha=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "nogit")
if ! git -C "$REPO_ROOT" diff --quiet 2>/dev/null || \
   ! git -C "$REPO_ROOT" diff --quiet --cached 2>/dev/null; then
  git_sha="${git_sha}-dirty"
fi
ts=$(date -u +%Y%m%dT%H%M%SZ)
out_file="$RESULTS_DIR/${ts}-${git_sha}.json"
raw_log=$(mktemp)

echo "snapshotting → $out_file" >&2
"$RUN_ALL" > "$raw_log" 2>&1
rc=$?
if (( rc != 0 )); then
  echo "run_all.sh failed (rc=$rc); raw log preserved at $raw_log" >&2
  exit "$rc"
fi

# Extract JSON blocks under each "=== name: tool ===" header and merge.
# run_all.sh prints headers like:
#   === perf: refract ===
#   { ...json... }
# We awk-split into per-block files keyed by header, then jq-merge.
work=$(mktemp -d)
trap 'rm -rf "$work" "$raw_log"' EXIT

awk -v out="$work" '
  /^=== / {
    sub(/^=== /, ""); sub(/ ===$/, "");
    gsub(/[^a-zA-Z0-9_]/, "_", $0);
    cur = out "/" $0 ".json";
    capturing = 0;
    next;
  }
  /^\{/ { capturing = 1 }
  capturing { print > cur }
  /^\}/ { capturing = 0 }
' "$raw_log"

# Build the merged document.
jq_args=()
for f in "$work"/*.json; do
  [[ -s "$f" ]] || continue
  key=$(basename "$f" .json)
  jq_args+=(--slurpfile "$key" "$f")
done

# Compose final structure: { meta: {...}, perf: {...}, accuracy: {...} }
{
  echo "{"
  echo "  \"meta\": {"
  echo "    \"git_sha\": \"$git_sha\","
  echo "    \"timestamp\": \"$ts\","
  echo "    \"host\": \"$(uname -srm | tr -d '\n')\","
  echo "    \"refract_version\": \"$("$REPO_ROOT/zig-out/bin/refract" --version 2>/dev/null | head -1 || echo unknown)\""
  echo "  },"
  echo "  \"perf\": {"
  for tool in refract solargraph ruby_lsp; do
    file="$work/perf__$tool.json"
    [[ -s "$file" ]] || file="$work/perf__${tool//_/-}.json"
    [[ -s "$file" ]] || continue
    label="${tool//_/-}"
    sep=","; [[ "$tool" == "ruby_lsp" ]] && sep=""
    echo "    \"$label\": $(cat "$file")$sep"
  done
  echo "  },"
  echo "  \"accuracy\": {"
  for tool in refract solargraph ruby_lsp; do
    file="$work/accuracy__$tool.json"
    [[ -s "$file" ]] || file="$work/accuracy__${tool//_/-}.json"
    [[ -s "$file" ]] || continue
    label="${tool//_/-}"
    sep=","; [[ "$tool" == "ruby_lsp" ]] && sep=""
    echo "    \"$label\": $(cat "$file")$sep"
  done
  echo "  }"
  echo "}"
} > "$out_file"

# Validate JSON; if invalid, leave the file but warn.
if command -v jq >/dev/null 2>&1; then
  if ! jq . "$out_file" >/dev/null 2>&1; then
    echo "warning: $out_file is not valid JSON; raw log at $raw_log" >&2
    trap - EXIT
    exit 1
  fi
fi

# One-line summary
echo
echo "── snapshot ${ts} (${git_sha}) ──────────────────────────────────────"
if command -v jq >/dev/null 2>&1; then
  jq -r '
    .perf as $p |
    "  refract:    init=" + ($p.refract.initialize_ms | tostring) + "ms  cold→def=" + ($p.refract.cold_to_first_def_ms | tostring) + "ms  def_p50=" + ($p.refract.def_p50_ms | tostring) + "ms  rss=" + ($p.refract.peak_rss_mb | tostring) + "MB",
    "  solargraph: init=" + ($p.solargraph.initialize_ms | tostring) + "ms  cold→def=" + ($p.solargraph.cold_to_first_def_ms | tostring) + "ms  def_p50=" + ($p.solargraph.def_p50_ms | tostring) + "ms  rss=" + ($p.solargraph.peak_rss_mb | tostring) + "MB",
    "  ruby-lsp:   init=" + ($p["ruby-lsp"].initialize_ms | tostring) + "ms  cold→def=" + ($p["ruby-lsp"].cold_to_first_def_ms | tostring) + "ms  def_p50=" + ($p["ruby-lsp"].def_p50_ms | tostring) + "ms  rss=" + ($p["ruby-lsp"].peak_rss_mb | tostring) + "MB"
  ' "$out_file"
fi

# Delta vs prior snapshot
prev=$(ls -1 "$RESULTS_DIR"/*.json 2>/dev/null | grep -v "$(basename "$out_file")" | sort | tail -1 || true)
if [[ -n "$prev" ]] && command -v jq >/dev/null 2>&1; then
  echo
  echo "── delta vs $(basename "$prev") ──"
  jq -n --slurpfile a "$prev" --slurpfile b "$out_file" '
    def fmt(x): if x == null then "n/a" else (x|tostring) end;
    def delta(was; now):
      if was == null or now == null then "n/a"
      elif was == 0 then "0→" + (now|tostring)
      else "" + (was|tostring) + "→" + (now|tostring) + " (" + (((now-was)/was*100)|round|tostring) + "%)"
      end;
    "  refract def_p50:        " + delta($a[0].perf.refract.def_p50_ms; $b[0].perf.refract.def_p50_ms),
    "  refract hover_p50:      " + delta($a[0].perf.refract.hover_p50_ms; $b[0].perf.refract.hover_p50_ms),
    "  refract completion_p50: " + delta($a[0].perf.refract.completion_p50_ms; $b[0].perf.refract.completion_p50_ms),
    "  refract initialize:     " + delta($a[0].perf.refract.initialize_ms; $b[0].perf.refract.initialize_ms),
    "  refract peak_rss_mb:    " + delta($a[0].perf.refract.peak_rss_mb; $b[0].perf.refract.peak_rss_mb)
  '
fi

trap - EXIT
rm -rf "$work" "$raw_log"
echo
echo "wrote $out_file"
