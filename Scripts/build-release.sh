#!/bin/zsh
# Release pipeline (ADR-039, Bible Part 17). One script, two outcomes that are never confused:
#
#   UNSIGNED (default)  ad-hoc signature, Hardened Runtime on, every file name ends in "-unsigned".
#                       Gatekeeper REFUSES it on other Macs. For local/CI smoke tests only — never a download.
#   SIGNED              Developer ID + (optionally) notarization + staple. Needs the env below. No suffix.
#
# Env — signing:     C2D_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"   C2D_TEAM_ID=<TEAMID>
# Env — notarize:    C2D_NOTARY_PROFILE=<notarytool keychain profile>   (requires signing)
# Env — Sparkle:     C2D_SPARKLE_PUBLIC_KEY=<base64 EdDSA public key>  → embedded as SUPublicEDKey; absent → updates disabled
# Env — misc:        C2D_BUILD_NUMBER (default: git rev-list --count HEAD; must grow every release — Sparkle compares it)
#                    C2D_OUT (default build/release)   C2D_SKIP_DMG=1
#
# Output (in $C2D_OUT): C2DTerminal.app, C2DTerminal-<v>[-unsigned].dmg, updates/C2DTerminal-<v>[-unsigned].zip
#                       (the zip is the Sparkle update archive), SHA256SUMS, RELEASE_INFO.txt
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen" >&2; exit 1; }

SIGNED=0; SUFFIX=-unsigned
if [[ -n ${C2D_SIGN_IDENTITY:-} ]]; then
  [[ -n ${C2D_TEAM_ID:-} ]] || { echo "C2D_SIGN_IDENTITY set but C2D_TEAM_ID missing" >&2; exit 1; }
  IDS=$(security find-identity -v -p codesigning)   # no grep -q on a pipe: with pipefail its early exit fails the pipe
  [[ $IDS == *"$C2D_SIGN_IDENTITY"* ]] || { echo "identity not in keychain: $C2D_SIGN_IDENTITY" >&2; exit 1; }
  SIGNED=1; SUFFIX=""
fi
if [[ -n ${C2D_NOTARY_PROFILE:-} && $SIGNED == 0 ]]; then echo "notarization needs a Developer ID signature (C2D_SIGN_IDENTITY)" >&2; exit 1; fi

VERSION=$(grep -E '^\s*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
BUILD=${C2D_BUILD_NUMBER:-$(git rev-list --count HEAD)}
OUT=${C2D_OUT:-build/release}; rm -rf "$OUT"; mkdir -p "$OUT/updates"
ARCHIVE=$OUT/C2DTerminal.xcarchive
echo "== C2D Terminal $VERSION ($BUILD) — $([[ $SIGNED == 1 ]] && echo SIGNED || echo UNSIGNED) release build"

xcodegen generate -q
sign_args=(CODE_SIGN_STYLE=Manual)
if [[ $SIGNED == 1 ]]; then
  sign_args+=(CODE_SIGN_IDENTITY="$C2D_SIGN_IDENTITY" DEVELOPMENT_TEAM="$C2D_TEAM_ID" OTHER_CODE_SIGN_FLAGS="--timestamp")
else
  # Ad-hoc has no Team ID, so library validation would refuse Sparkle.framework at launch (verified: dyld abort 2026-11-02).
  sign_args+=(CODE_SIGN_IDENTITY="-" CODE_SIGN_ENTITLEMENTS="$PWD/Packaging/unsigned.entitlements")
fi
# Archive (not plain build) so the embedded helper and frameworks land where a Developer ID export expects them.
xcodebuild archive -project C2DTerminal.xcodeproj -scheme C2DTerminal -configuration Release -destination 'platform=macOS' \
  -archivePath "$ARCHIVE" -derivedDataPath "$OUT/DerivedData" -skipPackagePluginValidation -skipMacroValidation \
  CURRENT_PROJECT_VERSION="$BUILD" C2D_SPARKLE_PUBLIC_KEY="${C2D_SPARKLE_PUBLIC_KEY:-}" "${sign_args[@]}" \
  2>&1 | grep -E "error:|warning: .*(sign|entitle)|ARCHIVE (SUCCEEDED|FAILED)" || true
[[ -d $ARCHIVE/Products/Applications/C2DTerminal.app ]] || { echo "archive failed" >&2; exit 1; }

if [[ $SIGNED == 1 ]]; then
  sed "s/TEAMID/$C2D_TEAM_ID/" Packaging/ExportOptions.plist > "$OUT/ExportOptions.plist"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" \
    2>&1 | grep -E "error:|EXPORT (SUCCEEDED|FAILED)" || true
  [[ -d $OUT/export/C2DTerminal.app ]] || { echo "export failed" >&2; exit 1; }
  mv "$OUT/export/C2DTerminal.app" "$OUT/C2DTerminal.app"
else
  cp -R "$ARCHIVE/Products/Applications/C2DTerminal.app" "$OUT/C2DTerminal.app"
fi
APP=$OUT/C2DTerminal.app

echo "== verify bundle"
BIN=$APP/Contents/MacOS/C2DTerminal
ARCHS=$(lipo -archs "$BIN"); [[ $ARCHS == arm64 ]] || { echo "unexpected archs: $ARCHS" >&2; exit 1; }
[[ -x $APP/Contents/MacOS/c2d-token-helper ]] || { echo "token helper missing from bundle" >&2; exit 1; }
[[ -d $APP/Contents/Frameworks/Sparkle.framework ]] || { echo "Sparkle.framework missing" >&2; exit 1; }
for k in CFBundleShortVersionString CFBundleVersion SUFeedURL SUPublicEDKey LSMinimumSystemVersion; do
  printf '  %-26s %s\n' "$k" "$(plutil -extract $k raw -o - "$APP/Contents/Info.plist" 2>/dev/null || echo '(empty)')"
done
[[ "$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" == "$BUILD" ]] || { echo "CFBundleVersion != $BUILD" >&2; exit 1; }
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
codesign -dv --verbose=1 "$APP" 2>&1 | grep -E "Identifier=|TeamIdentifier|flags=" | sed 's/^/  /'
ENT=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null | grep -oE '"[a-z.-]+" => ' | tr -d '" =>' | paste -sd, -)
echo "  entitlements: ${ENT:-none}"
if [[ $SIGNED == 1 && $ENT == *disable-library-validation* ]]; then echo "signed build must not disable library validation" >&2; exit 1; fi
FLAGS=$(codesign -dv "$APP" 2>&1 | grep "flags=" || true)   # no grep -q here: with pipefail its early exit fails the pipe
[[ $FLAGS == *runtime* ]] && echo "  hardened runtime: on" || { echo "hardened runtime OFF — Release must have it ($FLAGS)" >&2; exit 1; }

if [[ -n ${C2D_NOTARY_PROFILE:-} ]]; then
  echo "== notarize app"
  ditto -c -k --keepParent "$APP" "$OUT/notarize-app.zip"
  xcrun notarytool submit "$OUT/notarize-app.zip" --keychain-profile "$C2D_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"; rm -f "$OUT/notarize-app.zip"
fi

echo "== artifacts"
ZIP=$OUT/updates/C2DTerminal-$VERSION$SUFFIX.zip
ditto -c -k --keepParent "$APP" "$ZIP"      # ditto keeps symlinks + exec bits, which Sparkle needs
echo "  zip: $ZIP ($(du -h "$ZIP" | cut -f1))"
if [[ ${C2D_SKIP_DMG:-0} != 1 ]]; then
  DMG=$OUT/C2DTerminal-$VERSION$SUFFIX.dmg
  ./Scripts/make-dmg.sh "$APP" "$DMG" | sed 's/^/  /'
  if [[ $SIGNED == 1 ]]; then
    codesign --sign "$C2D_SIGN_IDENTITY" --timestamp "$DMG"
    if [[ -n ${C2D_NOTARY_PROFILE:-} ]]; then
      xcrun notarytool submit "$DMG" --keychain-profile "$C2D_NOTARY_PROFILE" --wait && xcrun stapler staple "$DMG"
    fi
  fi
fi
( cd "$OUT" && setopt null_glob && shasum -a 256 *.dmg updates/*.zip > SHA256SUMS && sed 's/^/  /' SHA256SUMS )   # null_glob: no DMG when C2D_SKIP_DMG=1

echo "== gatekeeper"
GK=$(spctl --assess --type execute "$APP" 2>&1 || true)
{
  echo "version=$VERSION build=$BUILD mode=$([[ $SIGNED == 1 ]] && echo signed || echo unsigned) notarized=$([[ -n ${C2D_NOTARY_PROFILE:-} ]] && echo yes || echo no)"
  echo "archs=$ARCHS hardened_runtime=on entitlements=${ENT:-none}"
  echo "gatekeeper: ${GK:-accepted}"
} | tee "$OUT/RELEASE_INFO.txt" | sed 's/^/  /'
if [[ $SIGNED == 0 ]]; then
  echo "  (unsigned build: Gatekeeper rejection above is expected; this artifact is NOT distributable)"
elif [[ -z ${C2D_NOTARY_PROFILE:-} ]]; then
  echo "  (signed, not notarized: Gatekeeper rejects Developer ID apps until they are notarized — set C2D_NOTARY_PROFILE)"
elif [[ $GK == *rejected* ]]; then
  echo "signed + notarized build still rejected by Gatekeeper" >&2; exit 1
fi
# Keep Sparkle's tools (generate_appcast, generate_keys, sign_update) next to the artifacts: CI has no other copy.
cp -R "$OUT/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin" "$OUT/sparkle-bin"
rm -rf "$OUT/DerivedData"
echo "== done: $OUT"
