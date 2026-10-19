# C2D Terminal

macOS-first, AI-native terminal workspace. Product owner: C2D Works.

**Source of truth:** `docs/C2D_Terminal_PRODUCT_BIBLE_v2.md`. Read it before changing architecture.

## Status

Usable for personal development (not publicly distributed). Implemented: real terminals (SwiftTerm over
the C2D PTY core), projects, persisted dockable layouts, explorer + NSTextView editor, Git panel
(status/diff/stage/hunk/commit/branches/worktrees/conflicts) with explicit Fetch / Pull / Push,
managed Claude Code sessions in C2D-owned PTYs, tasks with dependencies, ⌘K palette, diagnostics
export with redaction, runtime themes, and a measurement-only Token Optimizer (no provider usage
ingestion, no hand-off to agents yet — the **Token Saver** initiative that adds those is planned, see `docs/PROGRESS.md`). Verification layers: `swift test` on the core package
(160 tests on 2026-10-19; 159 after the 2026-10-18 batch, 154 before it; real shells and real git), Debug-only runtime hooks (below), and CI
(green on `872917f`, the last pushed commit; later local commits are not CI-verified until pushed).
Not done: signing/notarization/updater/billing (owner-gated), macOS 15 runtime check, VoiceOver
audit. Full status: `docs/REMAINING_WORK_AUDIT.md`.

**Terminal editing keys** (in a shell panel): Option+←/→ jump a word (zsh `backward-word`/`forward-word`),
Cmd+Delete clears the input line (`kill-whole-line`), and Ctrl-C aborts the current line — pressed twice
at an idle prompt it ends the shell, Claude-Code style. A ^C on a *running* command is passed through but
does not yet interrupt it: the PTY core does not give the shell a controlling terminal, so the kernel has
no foreground process group to signal. That controlling-tty fix is tracked separately (see
`docs/REMAINING_WORK_AUDIT.md`).

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

Launch argument available in every build: `-c2dOpenProject <dir>` (or pass a folder to `open -a`). Debug-only hooks for runtime checks (compiled out of Release): `-c2dOpenFile <file>`, `-c2dRunCommand "<line>"`, `-c2dApplyPreset <name>`, `-c2dLaunchAgent <provider>`, `-c2dCreateTask "<title>"`, `-c2dGitSelect <path>`, `-c2dPaletteQuery "<q>"`, `-c2dOptimizerDemo YES`, `-c2dPremium YES`, `-c2dSnapshot <png>`, `-c2dAutoConfirmQuit YES`, `-c2dQuitAfter <s>`, `-c2dScrollbackCheck <n>` (+ `-c2dScrollbackLines <cap>`), `-c2dGitSync YES` / `-c2dGitSyncRejected YES` (both refuse unless `origin` is a local filesystem path), `-c2dCtrlCCheck YES` (double Ctrl-C ends an idle shell but never one with a running command), `-c2dFocusCheck YES` (a freshly shown terminal takes keyboard focus), `-c2dThemeID <midnight|ocean|ember|daylight>` (start in a given theme; `daylight` is light mode). Debug builds also honour the environment variable `C2D_SUPPORT_DIR=<dir>`, which points every store (JSON documents, SQLite, layouts) at that directory instead of `~/Library/Application Support/C2D Terminal` so runtime checks never touch real data (the variable is inherited by shells the app spawns; harmless). The full list with comments is in `App/Model/AppModel.swift`.

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
