#!/usr/bin/env bash
# Accuracy (multi-op) + DX quality matrix. Captures one log for refract,
# ruby-lsp, and solargraph over an identical fixture workspace.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
REFRACT="${REFRACT:-$REPO_ROOT/zig-out/bin/refract}"
ROOT="$HERE/fixtures"
OUT="${1:-/tmp/refract_quality.log}"
: > "$OUT"

log() { printf '%s\n' "$*" | tee -a "$OUT"; }

# refract runs with native diagnostics only (--disable-rubocop) so the
# diagnostics axis measures the semantic engine, not rubocop style noise.
declare -A CMDS=(
  [refract]="$REFRACT --disable-rubocop"
  [ruby-lsp]="ruby-lsp"
  [solargraph]="solargraph stdio"
)
ORDER=(refract ruby-lsp solargraph)

log "===== STATIC DX FACTS ====="
log "refract binary bytes: $(stat -c%s "$REFRACT" 2>/dev/null)"
log "refract ldd:"; ldd "$REFRACT" 2>&1 | tee -a "$OUT" >/dev/null; ldd "$REFRACT" 2>&1 | sed 's/^/  /' >> "$OUT"
log "refract --doctor exit/lines:"
DOC="$("$REFRACT" --doctor 2>&1)"; log "  exit=$? lines=$(printf '%s\n' "$DOC" | wc -l)"
log "ruby-lsp gem path: $(gem which ruby_lsp 2>/dev/null || echo n/a)"
log "solargraph gem path: $(gem which solargraph 2>/dev/null || echo n/a)"

for srv in "${ORDER[@]}"; do
  log ""
  log "===== MULTI-OP ACCURACY: $srv ====="
  # shellcheck disable=SC2086
  ROOT="$ROOT" timeout 240 ruby "$HERE/lsp_multiop.rb" "$srv" ${CMDS[$srv]} 2>>"$OUT.stderr" | tee -a "$OUT"
done

for srv in "${ORDER[@]}"; do
  log ""
  log "===== DX TIMING: $srv ====="
  # shellcheck disable=SC2086
  ROOT="$ROOT" timeout 180 ruby "$HERE/lsp_dx.rb" "$srv" ${CMDS[$srv]} 2>>"$OUT.stderr" | tee -a "$OUT"
done

log ""
log "===== DONE ====="
