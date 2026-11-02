#!/bin/zsh
# Generates appcast.xml for Sparkle from a folder of update archives (ADR-039).
#
#   ./Scripts/make-appcast.sh <updates_dir> [download-url-prefix]
#
# Signing key, first match wins: C2D_SPARKLE_PRIVATE_KEY_FILE (CI: secret written to a temp file) →
# C2D_SPARKLE_KEY_ACCOUNT (Keychain account name) → default Keychain entry made by sparkle-keys.sh generate.
# Keep the folder across releases so generate_appcast can emit delta updates. Output: <updates_dir>/appcast.xml.
# Publishing = copying appcast.xml to the feed URL (Website/appcast.xml on c2dterminal.com) — this script never uploads.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/sparkle-tools.sh
BIN=$(sparkle_bin)
DIR=${1:?updates dir}
VERSION=$(grep -E '^\s*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
PREFIX=${2:-https://github.com/cemozbeyy/c2d-terminal/releases/download/v$VERSION/}
key=()
if [[ -n ${C2D_SPARKLE_PRIVATE_KEY_FILE:-} ]]; then key=(--ed-key-file "$C2D_SPARKLE_PRIVATE_KEY_FILE")
elif [[ -n ${C2D_SPARKLE_KEY_ACCOUNT:-} ]]; then key=(--account "$C2D_SPARKLE_KEY_ACCOUNT"); fi
"$BIN/generate_appcast" "${key[@]}" --download-url-prefix "$PREFIX" --link "https://c2dterminal.com/changelog" \
  -o "$DIR/appcast.xml" "$DIR"
echo "appcast: $DIR/appcast.xml"
grep -oE 'sparkle:(version|shortVersionString|edSignature)="[^"]*"|url="[^"]*"' "$DIR/appcast.xml" | sed 's/^/  /'
