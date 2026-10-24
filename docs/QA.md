# Release checklist

Automated (CI and locally):

```bash
swift test                                   # unit + integration (snapshots, restore, breaker, hooks, radar)
python3 -I Scripts/check-l10n.py             # every UI string has a Russian translation
python3 -I Scripts/e2e-hooks.py              # simulated agents drive the release hook binary
python3 -I Scripts/acceptance/parallel-sessions.py   # 5 sessions in worktrees, survivors attributed
make previews                                # light/dark PNGs of every screen for visual review
python3 -I Scripts/breaker-corpus.py OLD NEW  # this Mac's real agent commands: ask rate and changed verdicts (ADR-025)
python3 -I Scripts/hook-latency.py .build/arm64-apple-macosx/release/airbag 5000  # hook latency, nothing executed (BENCHMARKS.md)
```

Manual, on a clean macOS 14 and the current macOS (both architectures for the universal build):

1. Install from the DMG; first launch shows the welcome window; the icon appears in the menu bar.
2. Connect Claude Code: `~/.claude/settings.json` gains the Airbag entries, other keys unchanged, backup present.
3. In a test repo, ask the agent to `rm -rf src`; restore from the Timeline; `git status` clean afterwards.
4. Ask the agent to run `rm -rf ~/Documents/x` (sacrificial folder): the agent's own prompt appears (ask).
5. Codex: trust hooks in `/hooks`; `git push --force` runs and appears in Guard as "Ran without asking", with a dot on
   the icon. Settings → Agents → "When a snapshot can't undo a command" → "Stop Until I Approve": the same command is
   denied; "Allow Once" in Guard; the retry passes. An agent running `airbag allow` itself is blocked.
6. Start `npm run dev` through the agent, end the session: the popover offers "stop its servers"; Stop works.
7. Pause for 15 minutes: hooks skip snapshots; a catastrophic command is still blocked; resume.
8. Settings → Remove for each agent: config files return to the backup content.
9. Quit; `airbag snapshot` still works from the terminal; relaunch shows the new snapshot within a minute.
10. Idle for 10 minutes with one live session: Activity Monitor shows < 1 % CPU, < 100 MB.
11. Switch the system language to English and Russian: no untranslated strings, plurals correct.
12. VoiceOver: menu bar item, popover rows and buttons have meaningful labels.

After the GitHub release (the release workflow publishes it for a pushed `v*` tag):

1. Update the cask in the tap `a1murt/homebrew-airbag`: `version`, and `sha256` from the zip's line in the release's
   `Airbag-<version>.sha256`. Make the same change to `Packaging/airbag.rb`.
2. `brew upgrade --cask airbag` from the previous version: the hooks come back (`airbag hooks status`). For ad-hoc
   builds Homebrew prints "airbag's signer changed so macOS may prompt at next launch"; no prompt appears, because
   the cask's postflight removed the quarantine flag.
