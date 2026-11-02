#!/bin/zsh
# Builds the install DMG (ADR-039): app + Applications shortcut + background, Finder layout from a committed .DS_Store.
#
#   ./Scripts/make-dmg.sh <path/to/C2DTerminal.app> <out.dmg>      # build the compressed, read-only DMG
#   ./Scripts/make-dmg.sh --layout <path/to/C2DTerminal.app>       # (one-off, needs a GUI session) open a RW image,
#                                                                   # let Finder write the layout, save it as Packaging/dmg/DS_Store
#
# hdiutil only — no create-dmg dependency. Signing/notarizing the DMG is the caller's job (build-release.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
VOL="C2D Terminal"            # keep constant: the saved .DS_Store references the background by volume-relative path
BG=Packaging/dmg/background.png
DS=Packaging/dmg/DS_Store

stage() {   # $1 = app → prints staging dir
  local app=$1 s; s=$(mktemp -d)
  cp -R "$app" "$s/"
  ln -s /Applications "$s/Applications"
  mkdir "$s/.background"; cp "$BG" "$s/.background/background.png"
  [[ -f $DS ]] && cp "$DS" "$s/.DS_Store"
  print -r -- "$s"
}

if [[ ${1:-} == --layout ]]; then
  app=${2:?app path}; s=$(stage "$app"); rw=$(mktemp -d)/layout.dmg
  hdiutil create -volname "$VOL" -srcfolder "$s" -ov -format UDRW -fs HFS+ "$rw" >/dev/null
  hdiutil attach "$rw" -mountpoint "/Volumes/$VOL" -noautoopen >/dev/null
  osascript - "$VOL" <<'APPLESCRIPT'
on run argv
  set vol to item 1 of argv
  tell application "Finder"
    tell disk vol
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {200, 120, 860, 520}   -- 660×400, matches background.png
      set opts to icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 112
      set text size of opts to 13
      set background picture of opts to file ".background:background.png"
      set position of item "C2DTerminal.app" of container window to {160, 190}
      set position of item "Applications" of container window to {500, 190}
      close
      open
      update without registering applications
      delay 2
      close
    end tell
  end tell
end run
APPLESCRIPT
  sync; sleep 1
  cp "/Volumes/$VOL/.DS_Store" "$DS"
  hdiutil detach "/Volumes/$VOL" -quiet
  rm -rf "$s" "$(dirname "$rw")"
  echo "saved Finder layout to $DS ($(stat -f %z "$DS") bytes) — commit it"
  exit 0
fi

app=${1:?app path}; out=${2:?out.dmg}
[[ -f $DS ]] || echo "warning: $DS missing — DMG will open with Finder's default layout (run --layout once)" >&2
s=$(stage "$app")
rm -f "$out"
hdiutil create -volname "$VOL" -srcfolder "$s" -ov -format UDZO -imagekey zlib-level=9 -fs HFS+ "$out" >/dev/null
rm -rf "$s"
echo "dmg: $out ($(du -h "$out" | cut -f1))"
