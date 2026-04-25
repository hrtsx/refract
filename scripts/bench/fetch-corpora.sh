#!/usr/bin/env bash
# Fetch benchmark corpora: mastodon, discourse, and synth-10k.
# Idempotent: skips clones if directories already exist.
# Usage: ./scripts/bench/fetch-corpora.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORPORA_DIR="$REPO_ROOT/corpora"

fetch_corpus() {
  local name="$1"
  local url="$2"
  local target_dir="$CORPORA_DIR/$name"

  if [[ -d "$target_dir/.git" ]]; then
    echo "✓ $name already exists, skipping clone"
    local rb_count
    rb_count=$(find "$target_dir" -maxdepth 20 -name "*.rb" -type f 2>/dev/null | wc -l)
    echo "  $name: $rb_count .rb files"
    return 0
  fi

  echo "→ Cloning $name from $url..."
  mkdir -p "$CORPORA_DIR"
  if ! git clone --depth=1 --quiet "$url" "$target_dir" 2>&1; then
    echo "✗ Clone failed for $name" >&2
    return 1
  fi

  local rb_count
  rb_count=$(find "$target_dir" -maxdepth 20 -name "*.rb" -type f 2>/dev/null | wc -l)
  echo "  $name: $rb_count .rb files"
}

generate_synth() {
  local target_dir="$CORPORA_DIR/synth-10k"

  if [[ -d "$target_dir" ]]; then
    echo "✓ synth-10k already exists, skipping generation"
    local rb_count
    rb_count=$(find "$target_dir" -maxdepth 1 -name "*.rb" -type f 2>/dev/null | wc -l)
    echo "  synth-10k: $rb_count .rb files"
    return 0
  fi

  echo "→ Generating synth-10k corpus..."
  mkdir -p "$CORPORA_DIR"
  if ! "$REPO_ROOT/scripts/bench/synth_corpus.rb" "$target_dir" 10000 2>&1; then
    echo "✗ Synth generation failed" >&2
    return 1
  fi

  local rb_count
  rb_count=$(find "$target_dir" -maxdepth 1 -name "*.rb" -type f 2>/dev/null | wc -l)
  echo "  synth-10k: $rb_count .rb files"
}

echo "Fetching benchmark corpora..."
echo
fetch_corpus "mastodon" "https://github.com/mastodon/mastodon"
fetch_corpus "discourse" "https://github.com/discourse/discourse"
generate_synth
echo
echo "All corpora ready."
