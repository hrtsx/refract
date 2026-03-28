#!/usr/bin/env bash
# Downloads the latest released binary from GitHub and validates --version + --check.
# Usage: ./scripts/smoke-install.sh [version-tag]
#        REFRACT_OWNER=hrtsx ./scripts/smoke-install.sh
set -uo pipefail

OWNER="${REFRACT_OWNER:-hrtsx}"
REPO="${REFRACT_REPO:-refract}"
TAG="${1:-latest}"

OS_RAW=$(uname -s)
ARCH_RAW=$(uname -m)
case "$OS_RAW" in
  Linux)  OS=linux ;;
  Darwin) OS=macos ;;
  *) echo "unsupported OS: $OS_RAW" >&2; exit 2 ;;
esac
case "$ARCH_RAW" in
  x86_64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *) echo "unsupported arch: $ARCH_RAW" >&2; exit 2 ;;
esac

if [[ "$TAG" == "latest" ]]; then
  URL="https://github.com/${OWNER}/${REPO}/releases/latest/download/refract-${ARCH}-${OS}"
else
  URL="https://github.com/${OWNER}/${REPO}/releases/download/${TAG}/refract-${ARCH}-${OS}"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "downloading: $URL"
if ! curl -fsL "$URL" -o "$WORK/refract"; then
  echo "FAIL: download failed" >&2
  exit 1
fi
chmod +x "$WORK/refract"

echo "--- version ---"
"$WORK/refract" --version || { echo "FAIL: --version returned non-zero"; exit 1; }

echo "--- doctor ---"
"$WORK/refract" --doctor | head -20 || true

echo "--- check (against tiny fixture) ---"
mkdir -p "$WORK/fixture"
cat > "$WORK/fixture/sample.rb" <<'RB'
class Sample
  def hello
    "world"
  end
end
RB

DB="$WORK/smoke.db"
( cd "$WORK/fixture" && "$WORK/refract" --db-path "$DB" --index-only --disable-rubocop ) || {
  echo "FAIL: --index-only returned non-zero" >&2
  exit 1
}

if "$WORK/refract" --db-path "$DB" --check; then
  echo
  echo "smoke install OK"
  exit 0
else
  echo "FAIL: --check returned non-zero" >&2
  exit 1
fi
