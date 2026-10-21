#!/bin/zsh
# Regenerates the README artwork in .github/readme/ (macOS 14+, Xcode command-line tools).
# Buddy is taken from App/Views/BuddyView.swift so the README mascot always matches the app.
set -euo pipefail
cd "$(dirname "$0")/../.."
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
# Only BuddyMascotView: the rest of the file depends on app types.
awk '/^struct BuddyMascotView/{on=1} /^struct BuddyRailButton/{on=0} on' App/Views/BuddyView.swift > "$build/BuddyMascotView.swift"
print 'import SwiftUI' | cat - "$build/BuddyMascotView.swift" > "$build/Buddy.swift"
cp Tools/readme/main.swift "$build/main.swift"
swiftc -O -swift-version 5 -o "$build/render" "$build/main.swift" "$build/Buddy.swift"
"$build/render" "$PWD"
