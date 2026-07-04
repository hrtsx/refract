#!/usr/bin/env bash
# Shared helpers for the bench runners (realistic_run.sh, quality_accuracy_run.sh).
# Source after PILOT_DIR is set; corpus_root reads it at call time.

# Map a corpus alias to its on-disk root. Unknown names pass through as a literal
# path so callers can point at an arbitrary directory.
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
