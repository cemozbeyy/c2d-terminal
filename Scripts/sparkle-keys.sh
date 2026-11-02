#!/bin/zsh
# EdDSA key management for Sparkle updates (ADR-039). The PRIVATE key never enters the repo: generate_keys stores it in
# the login Keychain of the Mac that runs it; export it ONLY to move it into the CI secret C2D_SPARKLE_PRIVATE_KEY.
#
#   ./Scripts/sparkle-keys.sh generate [--account NAME]   # once, by the release owner → prints the PUBLIC key
#   ./Scripts/sparkle-keys.sh show     [--account NAME]   # print the public key again
#   ./Scripts/sparkle-keys.sh export <file> [--account NAME]   # private key → file (chmod 600); paste into the CI secret, then shred
#   ./Scripts/sparkle-keys.sh import <file> [--account NAME]   # private key file → Keychain (another release Mac)
#
# The public key goes into builds as C2D_SPARKLE_PUBLIC_KEY (build setting → Info.plist SUPublicEDKey).
# Losing the private key means every installed copy stops accepting updates: back it up offline.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/sparkle-tools.sh
BIN=$(sparkle_bin)
cmd=${1:?generate|show|export|import}; shift
acct=()
args=("$@")
for ((i=1; i<=${#args}; i++)); do [[ ${args[i]} == --account ]] && acct=(--account "${args[i+1]}"); done
case $cmd in
  generate|show) "$BIN/generate_keys" "${acct[@]}" ;;
  export) f=${1:?file}; "$BIN/generate_keys" "${acct[@]}" -x "$f"; chmod 600 "$f"; echo "private key written to $f — move it to the CI secret, then delete the file" ;;
  import) f=${1:?file}; "$BIN/generate_keys" "${acct[@]}" -f "$f" ;;
  *) echo "unknown command $cmd" >&2; exit 2 ;;
esac
