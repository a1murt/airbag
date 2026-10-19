# Contributing

- Toolchain: Swift 6.1 (Command Line Tools are enough). `make test` must stay green.
- No third-party dependencies (ADR-017).
- User-facing strings are written in English (the source language). Add each new one to `ru.lproj` (the reference
  translation) and to every other `*.lproj`: `python3 -I Scripts/check-l10n.py` checks keys, format specifiers and
  plural forms for all languages and fails otherwise.
- Breaker changes: add cases to `Tests/AirbagCoreTests/Fixtures/rules.json` (or `rules-redteam.json` for bypasses).
  Never execute candidate commands while testing them; use `airbag check "<cmd>"`.
- Snapshot engine changes must keep the restore invariants of `docs/design/10-snapshot-engine.md` §6 and the
  retention property test.
- UI changes: `build/Airbag.app/Contents/MacOS/Airbag --render-previews /tmp/previews` renders every screen in light
  and dark mode for review.
- Architecture changes get an ADR in `docs/DECISIONS.md`.
