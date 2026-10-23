# C2D Terminal — agent notes

- `docs/` is private: local only, git-ignored, removed from history (2026-10-21) before the repo went public. Keep using it; never `git add -f` it. Code the app or CI needs lives outside `docs/` (e.g. `Tools/experiment`).
- Product spec: `docs/C2D_Terminal_PRODUCT_BIBLE_v2.md`. Authoritative; never shorten or rewrite it. Decisions: `docs/DECISIONS.md`. Open owner items: `docs/OPEN_DECISIONS.md`. Running log: `docs/PROGRESS.md`.
- Work one phase at a time (Bible §0). Report what was built, what was tested, what was not.
- Never present a text view as a terminal. Real PTY or nothing (Bible Part 4). Engine (SwiftTerm) lives in the UI layer only; `Packages/C2DCore` stays engine-free and on swift-tools 6.0.
- Decisions go in `docs/DECISIONS.md` with status CONFIRMED / PROPOSED / UNRESOLVED / DEFERRED.
- Project file is generated: edit `project.yml`, run `xcodegen generate`.
- Git: never commit unless the owner asks for it in the current message (the 2026-10-16 "commit without asking" mandate was revoked on 2026-10-18). Never `git push`, publish, deploy, or spend money without explicit permission.
- Tests: `swift test --package-path Packages/C2DCore` (real shells, serialized). Always run with a watchdog; a hung test means a cancellation bug, not a slow machine.
- UI: everything clickable or draggable changes the cursor on hover (owner rule). Buttons get it from `ClickableButtonStyle` — use `.buttonStyle(.clickPlain)` / `.clickProminent`, never `.plain` / `.borderedProminent`; menus, toggles, pickers and tap-gesture rows need `.clickCursor()`; a new `NSHostingView` root needs `.buttonStyle(.clickDefault)`.
