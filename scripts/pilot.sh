#!/usr/bin/env bash
# Pilot harness: index well-known Rails apps, capture index time, peak RSS, file/symbol counts.
# Usage: ./scripts/pilot.sh [discourse|mastodon|gitlabhq] ...
#        REFRACT_PILOT_DIR=/path  ./scripts/pilot.sh
#        REFRACT=./zig-out/bin/refract  ./scripts/pilot.sh
set -uo pipefail

PILOT_DIR="${REFRACT_PILOT_DIR:-/tmp/refract-pilot}"
REFRACT_BIN="${REFRACT:-$(pwd)/zig-out/bin/refract}"

if [[ ! -x "$REFRACT_BIN" ]]; then
  echo "refract binary not executable at: $REFRACT_BIN" >&2
  echo "build first with: zig build" >&2
  exit 1
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "warning: pilot harness uses GNU time (-v); macOS support is degraded" >&2
fi

declare -A CORPORA=(
  [discourse]="https://github.com/discourse/discourse"
  [mastodon]="https://github.com/mastodon/mastodon"
  [gitlabhq]="https://github.com/gitlabhq/gitlabhq"
)

TARGETS=("$@")
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=(discourse mastodon gitlabhq)
fi

mkdir -p "$PILOT_DIR"

emit_header() {
  printf "| corpus | files | symbols | wall sec | peak RSS MB | indexer ms |\n"
  printf "|---|---:|---:|---:|---:|---:|\n"
}

run_corpus() {
  local name="$1"
  local url="${CORPORA[$name]:-}"
  if [[ -z "$url" ]]; then
    echo "unknown corpus: $name (valid: ${!CORPORA[*]})" >&2
    return 1
  fi

  local repo_dir="$PILOT_DIR/$name"
  if [[ ! -d "$repo_dir/.git" ]]; then
    echo "cloning $name from $url ..." >&2
    if ! git clone --depth=1 --quiet "$url" "$repo_dir" 2>&1; then
      echo "clone failed for $name" >&2
      return 1
    fi
  else
    echo "reusing existing clone at $repo_dir" >&2
  fi

  local db_path="$PILOT_DIR/$name.db"
  rm -f "$db_path" "$db_path-wal" "$db_path-shm"

  local time_log
  time_log=$(mktemp)

  ( cd "$repo_dir" && \
    /usr/bin/time -v "$REFRACT_BIN" \
      --db-path "$db_path" \
      --index-only \
      --max-workers 8 \
      --disable-rubocop \
      > "$time_log" 2>&1 )

  local indexer_msg wall_secs peak_rss_kb peak_rss_mb files_out
  indexer_msg=$(grep -E "^Indexed " "$time_log" | head -1 || echo "")
  wall_secs=$(grep -E "Elapsed \(wall clock\) time" "$time_log" | awk -F': ' '{print $NF}' | tr -d ' ' || echo "?")
  peak_rss_kb=$(grep -E "Maximum resident set size" "$time_log" | awk '{print $NF}' || echo 0)
  peak_rss_mb=$((peak_rss_kb / 1024))

  local stats_json files symbols
  stats_json=$("$REFRACT_BIN" --db-path "$db_path" --stats --json 2>/dev/null || echo '{}')
  if command -v jq >/dev/null 2>&1; then
    files=$(echo "$stats_json" | jq -r '.files // 0')
    symbols=$(echo "$stats_json" | jq -r '.symbols // 0')
  else
    files=$(echo "$stats_json" | grep -oE '"files":[0-9]+' | cut -d: -f2 || echo 0)
    symbols=$(echo "$stats_json" | grep -oE '"symbols":[0-9]+' | cut -d: -f2 || echo 0)
  fi

  printf "| %s | %s | %s | %s | %s | %s |\n" \
    "$name" "${files:-0}" "${symbols:-0}" "${wall_secs:-?}" "$peak_rss_mb" \
    "$(echo "$indexer_msg" | grep -oE '[0-9]+ files' | head -1 || echo '?')"

  rm -f "$time_log"
}

echo "# Refract pilot results"
echo
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Binary: $REFRACT_BIN"
echo "Version: $("$REFRACT_BIN" --version 2>/dev/null | head -1)"
echo "Pilot dir: $PILOT_DIR"
echo
emit_header
for t in "${TARGETS[@]}"; do
  run_corpus "$t" || echo "| $t | (failed) |  |  |  |  |"
done
