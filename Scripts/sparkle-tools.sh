# Sourced by the Sparkle scripts: locates the tools that ship with the Sparkle SPM artifact (no separate download).
# Override with C2D_SPARKLE_BIN=/path/to/Sparkle/bin.
sparkle_bin() {
  if [[ -n ${C2D_SPARKLE_BIN:-} && -x $C2D_SPARKLE_BIN/generate_appcast ]]; then print -r -- "$C2D_SPARKLE_BIN"; return; fi
  local d
  [[ -x build/release/sparkle-bin/generate_appcast ]] && { print -r -- "build/release/sparkle-bin"; return; }   # left by build-release.sh
  for d in build/release/DerivedData ~/Library/Developer/Xcode/DerivedData/C2DTerminal-*; do
    [[ -x $d/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast ]] && { print -r -- "$d/SourcePackages/artifacts/sparkle/Sparkle/bin"; return; }
  done
  echo "Sparkle tools not found — build the app once (they arrive with the package), or set C2D_SPARKLE_BIN" >&2; return 1
}
