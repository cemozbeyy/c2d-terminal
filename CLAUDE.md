# C2D Terminal — agent notes

- Product spec: `docs/C2D_Terminal_PRODUCT_BIBLE_v2.md`. Authoritative; never shorten or rewrite it. Open owner decisions: `docs/OPEN_DECISIONS.md`.
- Work one phase at a time (Bible §0). Report what was built, what was tested, what was not.
- Never present a text view as a terminal. Real PTY or nothing (Bible Part 4).
- Decisions go in `docs/DECISIONS.md` with status CONFIRMED / PROPOSED / UNRESOLVED.
- Project file is generated: edit `project.yml`, run `xcodegen generate`.
- Ask before every `git commit`.
