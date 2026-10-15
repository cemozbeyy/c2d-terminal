# C2D Terminal

macOS-first, AI-native terminal workspace. Product owner: C2D Works.

**Source of truth:** `docs/C2D_Terminal_PRODUCT_BIBLE_v2.md`. Read it before changing architecture.

## Status

Foundation only. The app builds, launches a native window, logs a diagnostics line and runs one test target.
Real terminals (SwiftTerm over the C2D PTY core), project registry, persisted dockable layouts. **No editor, Git, agent or Token Optimizer code yet.**

## Requirements

- macOS 15+. Verified on Xcode 27 / Swift 6.4 locally and on Xcode 16.4 / Swift 6.1.2 in CI.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

The `.xcodeproj` is generated and gitignored. Edit `project.yml`, not the project file.

## Commands

```sh
xcodegen generate                                   # (re)create C2DTerminal.xcodeproj
swift test --package-path Packages/C2DCore          # unit tests (Swift Testing)
xcodebuild build -project C2DTerminal.xcodeproj -scheme C2DTerminal -configuration Debug -destination 'platform=macOS' -skipPackagePluginValidation
open ~/Library/Developer/Xcode/DerivedData/C2DTerminal-*/Build/Products/Debug/C2DTerminal.app   # launch dev build
```

Or open `C2DTerminal.xcodeproj` in Xcode and press Run.

Formatting/linting: none configured yet (swiftformat/swiftlint are not installed on the dev machine).

Release build (ad-hoc signed, Gatekeeper will reject until a Developer ID exists): `./Scripts/build-release.sh` → `build/C2DTerminal-<version>-unsigned.zip`.

Launch argument available in every build: `-c2dOpenProject <dir>` (or pass a folder to `open -a`). Debug-only hooks for runtime checks (compiled out of Release): `-c2dOpenFile <file>`, `-c2dRunCommand "<line>"`, `-c2dApplyPreset <name>`, `-c2dLaunchAgent <provider>`, `-c2dCreateTask "<title>"`, `-c2dGitSelect <path>`, `-c2dPaletteQuery "<q>"`, `-c2dOptimizerDemo YES`, `-c2dPremium YES`, `-c2dSnapshot <png>`, `-c2dAutoConfirmQuit YES`, `-c2dQuitAfter <s>`.

## Layout

```
App/                 SwiftUI/AppKit app: Model, Views (workspace canvas), Terminal, Explorer, Editor, Git, Agents, Tasks, Palette, Optimizer
Packages/C2DCore/    Engine-free core: PTY, Workspace layout, Persistence (JSON docs + SQLite), Projects, Terminal/Agent registries, Files, Git, Tasks, Optimizer
Spikes/              SwiftTermSpike evaluation harness (not part of the app)
Scripts/             build-release.sh
docs/                Product Bible, DECISIONS.md, OPEN_DECISIONS.md, PROGRESS.md, module notes, evidence/ screenshots
.github/workflows/   CI (core tests on macos-15, app build on macos-26) and a manual unsigned release build
project.yml          XcodeGen spec
```
