#!/bin/zsh
# Build and launch the Debug app for PERSONAL USE on this Mac.
# No signing, no notarization, no CI, no distribution — just a one-command local launch.
#
#   ./Scripts/run-debug.sh                 # build + launch
#   ./Scripts/run-debug.sh /path/to/project  # build + launch and open that project
#
# Env:
#   C2D_DERIVED=<dir>   use a specific DerivedData dir (used by the clean-build check)
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen missing — install it: brew install xcodegen" >&2; exit 1; }
xcodegen generate -q

derived_args=()
[[ -n "${C2D_DERIVED:-}" ]] && derived_args=(-derivedDataPath "$C2D_DERIVED")

echo "Building Debug (this can take a minute on a clean checkout)…"
xcodebuild build -project C2DTerminal.xcodeproj -scheme C2DTerminal -configuration Debug \
  -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation "${derived_args[@]}" \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

# Resolve the built .app path from the build settings — no DerivedData wildcard guessing.
settings=$(xcodebuild -project C2DTerminal.xcodeproj -scheme C2DTerminal -configuration Debug \
  -destination 'platform=macOS' "${derived_args[@]}" -showBuildSettings 2>/dev/null)
dir=$(print -r -- "$settings" | grep -E '^ *BUILT_PRODUCTS_DIR = ' | head -1 | sed 's/^[^=]*= //')
name=$(print -r -- "$settings" | grep -E '^ *FULL_PRODUCT_NAME = ' | head -1 | sed 's/^[^=]*= //')
APP="$dir/$name"

[[ -d "$APP" ]] || { echo "build produced no app (looked at: $APP)" >&2; exit 1; }
echo "Built: $APP"

if [[ -n "${1:-}" ]]; then
  open "$APP" --args -c2dOpenProject "$1"
else
  open "$APP"
fi
echo "Launched. (Quit with ⌘Q; it asks before stopping any live shells.)"
