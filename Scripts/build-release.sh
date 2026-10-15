#!/bin/zsh
# Builds a Release .app without signing credentials (Phase 11, Bible Part 17).
# Output: build/C2DTerminal.app and build/C2DTerminal-<version>-unsigned.zip
# Signing/notarization need a Developer ID certificate the owner has not provided yet (ADR-003);
# this script never pretends otherwise: the artifact is ad-hoc signed and will not pass Gatekeeper.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen" >&2; exit 1; }
xcodegen generate -q
rm -rf build && mkdir -p build
xcodebuild build -project C2DTerminal.xcodeproj -scheme C2DTerminal -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=YES | grep -E "error|warning: |BUILD" || true
APP=build/DerivedData/Build/Products/Release/C2DTerminal.app
test -d "$APP" || { echo "no app produced" >&2; exit 1; }
cp -R "$APP" build/
VERSION=$(defaults read "$PWD/build/C2DTerminal.app/Contents/Info" CFBundleShortVersionString)
ARCHS=$(lipo -archs build/C2DTerminal.app/Contents/MacOS/C2DTerminal)
( cd build && ditto -c -k --keepParent C2DTerminal.app "C2DTerminal-$VERSION-unsigned.zip" )
echo "built build/C2DTerminal.app version=$VERSION archs=$ARCHS"
echo "signature:"; codesign -dv --verbose=1 build/C2DTerminal.app 2>&1 | grep -E "Identifier|Signature|TeamIdentifier|flags" || true
echo "gatekeeper (expected to be rejected without Developer ID):"; spctl --assess --type execute build/C2DTerminal.app 2>&1 || true
