# Release checklist

Automated (CI and locally):

```bash
swift test                                   # unit + integration (snapshots, restore, breaker, hooks, radar)
python3 -I Scripts/check-l10n.py             # every UI string has a Russian translation
python3 -I Scripts/e2e-hooks.py              # simulated agents drive the release hook binary
python3 -I Scripts/acceptance/parallel-sessions.py   # 5 sessions in worktrees, survivors attributed
make previews                                # light/dark PNGs of every screen for visual review
```

Manual, on a clean macOS 14 and the current macOS (both architectures for the universal build):

1. Install from the DMG; first launch shows the welcome window; the icon appears in the menu bar.
2. Connect Claude Code: `~/.claude/settings.json` gains the Airbag entries, other keys unchanged, backup present.
3. In a test repo, ask the agent to `rm -rf src`; restore from the Timeline; `git status` clean afterwards.
4. Ask the agent to run `rm -rf ~/Documents/x` (sacrificial folder): the agent's own prompt appears (ask).
5. Codex: trust hooks in `/hooks`; `git push --force` is denied; "Allow once" in Guard; the retry passes.
6. Start `npm run dev` through the agent, end the session: the popover offers "stop its servers"; Stop works.
7. Pause for 15 minutes: hooks skip snapshots; a catastrophic command is still blocked; resume.
8. Settings → Remove for each agent: config files return to the backup content.
9. Quit; `airbag snapshot` still works from the terminal; relaunch shows the new snapshot within a minute.
10. Idle for 10 minutes with one live session: Activity Monitor shows < 1 % CPU, < 100 MB.
11. Switch the system language to English and Russian: no untranslated strings, plurals correct.
12. VoiceOver: menu bar item, popover rows and buttons have meaningful labels.
