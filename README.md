# C2D Terminal

macOS-first, AI-native terminal workspace. Product owner: C2D Works.

**Source of truth:** `docs/C2D_Terminal_PRODUCT_BIBLE_v2.md`. Read it before changing architecture.

## Status

Foundation only. The app builds, launches a native window, logs a diagnostics line and runs one test target.
**PTY session core exists (headless; see `docs/PTY_CORE.md`). No terminal engine/rendering, editor, Git, agent or Token Optimizer code yet.** The window says so.

## Requirements

- macOS 15+. Verified on Xcode 27 / Swift 6.4 locally and on Xcode 16.4 / Swift 6.1.2 in CI.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

The `.xcodeproj` is generated and gitignored. Edit `project.yml`, not the project file.

## Commands

```sh
xcodegen generate                                   # (re)create C2DTerminal.xcodeproj
swift test --package-path Packages/C2DCore          # unit tests (Swift Testing)
xcodebuild build -project C2DTerminal.xcodeproj -scheme C2DTerminal -configuration Debug -destination 'platform=macOS'
open ~/Library/Developer/Xcode/DerivedData/C2DTerminal-*/Build/Products/Debug/C2DTerminal.app   # launch dev build
```

Or open `C2DTerminal.xcodeproj` in Xcode and press Run.

Formatting/linting: none configured yet (swiftformat/swiftlint are not installed on the dev machine).

## Layout

```
App/                 SwiftUI app target (entry point, foundation window)
Packages/C2DCore/    Shared Swift package: Diagnostics, PTY/ (PTYSession); git/agent modules later
docs/                Product Bible, DECISIONS.md (ADRs), OPEN_DECISIONS.md, TERMINAL_ENGINE_EVALUATION.md, PTY_CORE.md
.github/workflows/   CI: package tests + app build on a macOS runner
project.yml          XcodeGen spec
```
