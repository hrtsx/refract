#!/usr/bin/env bash
# Fetch benchmark corpora pinned to fixed release tags for reproducibility.
#   mastodon, discourse, homebrew, solidus  (gitlabhq behind INCLUDE_GITLAB=1)
#   + synth-10k (generated)
# Idempotent: skips clones if directories already exist. Writes a manifest with
# the resolved commit SHA + .rb count per corpus.
# Usage: ./scripts/bench/fetch-corpora.sh   [INCLUDE_GITLAB=1]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORPORA_DIR="$REPO_ROOT/corpora"
MANIFEST="$CORPORA_DIR/CORPORA_MANIFEST.json"

# name -> "url|ref"  (ref is a tag; pinned for reproducibility)
declare -A CORPUS=(
  [mastodon]="https://github.com/mastodon/mastodon|v4.5.11"
  [discourse]="https://github.com/discourse/discourse|v2026.5.0"
  [homebrew]="https://github.com/Homebrew/brew|6.0.2"
  [solidus]="https://github.com/solidusio/solidus|v4.7.0"
  [gitlabhq]="https://github.com/gitlabhq/gitlabhq|v18.0.0-ee"
)

MANIFEST_ROWS=()

manifest_add() {
  local name="$1" url="$2" ref="$3" sha="$4" count="$5"
  MANIFEST_ROWS+=("$(printf '{"name":"%s","url":"%s","ref":"%s","sha":"%s","rb_files":%s}' \
    "$name" "$url" "$ref" "$sha" "$count")")
}

rb_count() { find "$1" -maxdepth 20 -name "*.rb" -type f 2>/dev/null | wc -l; }

fetch_corpus() {
  local name="$1"
  local spec="${CORPUS[$name]}"
  local url="${spec%%|*}" ref="${spec##*|}"
  local target_dir="$CORPORA_DIR/$name"

  if [[ -d "$target_dir/.git" ]]; then
    echo "✓ $name already exists, skipping clone"
  else
    echo "→ Cloning $name @ $ref ..."
    mkdir -p "$CORPORA_DIR"
    # Shallow clone of the exact tag (single revision, no full history).
    if ! git clone --depth=1 --branch "$ref" --quiet "$url" "$target_dir" 2>&1; then
      echo "✗ Clone failed for $name ($url @ $ref)" >&2
      return 1
    fi
  fi

  local sha count
  sha="$(git -C "$target_dir" rev-parse HEAD 2>/dev/null || echo unknown)"
  count="$(rb_count "$target_dir")"
  echo "  $name @ ${sha:0:12}: $count .rb files"
  manifest_add "$name" "$url" "$ref" "$sha" "$count"
}

generate_synth() {
  local target_dir="$CORPORA_DIR/synth-10k"
  if [[ -d "$target_dir" ]]; then
    echo "✓ synth-10k already exists, skipping generation"
  else
    echo "→ Generating synth-10k corpus..."
    mkdir -p "$CORPORA_DIR"
    if ! "$REPO_ROOT/scripts/bench/synth_corpus.rb" "$target_dir" 10000 2>&1; then
      echo "✗ Synth generation failed" >&2
      return 1
    fi
  fi
  local count; count="$(find "$target_dir" -maxdepth 1 -name "*.rb" -type f 2>/dev/null | wc -l)"
  echo "  synth-10k: $count .rb files"
  manifest_add "synth-10k" "(generated)" "n/a" "n/a" "$count"
}

echo "Fetching benchmark corpora..."
echo
fetch_corpus "mastodon"
fetch_corpus "discourse"
fetch_corpus "homebrew"
fetch_corpus "solidus"
if [[ "${INCLUDE_GITLAB:-0}" == "1" ]]; then
  fetch_corpus "gitlabhq"
fi
generate_synth

# Emit manifest.
{
  echo "["
  for i in "${!MANIFEST_ROWS[@]}"; do
    sep=","; [[ "$i" -eq $(( ${#MANIFEST_ROWS[@]} - 1 )) ]] && sep=""
    echo "  ${MANIFEST_ROWS[$i]}$sep"
  done
  echo "]"
} > "$MANIFEST"

echo
echo "manifest: $MANIFEST"
echo "All corpora ready."
