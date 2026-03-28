#!/usr/bin/env bash
# Updates packaging/homebrew/refract.rb with SHAs of the just-released binaries.
# Usage: ./scripts/bump-formula.sh <version> <sha-x86_64-linux> <sha-aarch64-linux> <sha-x86_64-macos> <sha-aarch64-macos>
# Output: prints the rewritten formula content to stdout.
set -euo pipefail

VERSION="${1:?missing version}"
SHA_LX64="${2:?missing x86_64-linux sha}"
SHA_LARM="${3:?missing aarch64-linux sha}"
SHA_MX64="${4:?missing x86_64-macos sha}"
SHA_MARM="${5:?missing aarch64-macos sha}"

FORMULA="${REFRACT_FORMULA_PATH:-packaging/homebrew/refract.rb}"

if [[ ! -f "$FORMULA" ]]; then
  echo "formula not found: $FORMULA" >&2
  exit 1
fi

# Strip leading 'v' from version if present (tag is v0.1.0; formula stores 0.1.0)
VERSION="${VERSION#v}"

awk -v ver="$VERSION" -v sl64="$SHA_LX64" -v slarm="$SHA_LARM" -v smx64="$SHA_MX64" -v smarm="$SHA_MARM" '
  /version "/ { sub(/"[^"]*"/, "\"" ver "\""); print; next }
  /aarch64-macos.*sha256/ || (in_marm && /sha256/) { sub(/"[a-f0-9]+"/, "\"" smarm "\""); print; in_marm=0; next }
  /x86_64-macos.*sha256/ || (in_mx64 && /sha256/) { sub(/"[a-f0-9]+"/, "\"" smx64 "\""); print; in_mx64=0; next }
  /aarch64-linux.*sha256/ || (in_larm && /sha256/) { sub(/"[a-f0-9]+"/, "\"" slarm "\""); print; in_larm=0; next }
  /x86_64-linux.*sha256/ || (in_lx64 && /sha256/) { sub(/"[a-f0-9]+"/, "\"" sl64 "\""); print; in_lx64=0; next }
  /aarch64-macos/ { in_marm=1 }
  /x86_64-macos/  { in_mx64=1 }
  /aarch64-linux/ { in_larm=1 }
  /x86_64-linux/  { in_lx64=1 }
  { print }
' "$FORMULA"
