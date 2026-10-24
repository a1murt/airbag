# Benchmarks

Numbers the README quotes, and where each comes from. Re-run the scripted ones on a release build before changing the
README.

## Hook latency

`Scripts/hook-latency.py` feeds `airbag hook claude-code` the same PreToolUse JSON Claude Code sends and times process
start to reply. Every call has its own `tool_use_id` (a repeated id is the same call arriving twice, which the hook
answers from its first decision without a snapshot), and the script checks that each reply is a plain allow. The
commands are only decided on, never run. Project (a git repository) and `AIRBAG_HOME` live in a temporary folder.

```bash
swift build -c release --product airbag
python3 -I Scripts/hook-latency.py .build/arm64-apple-macosx/release/airbag 5000 60
python3 -I Scripts/hook-latency.py .build/arm64-apple-macosx/release/airbag 500 60
```

2026-10-24, Apple M4, macOS 27.0.1, release build of 0.1.1. Three runs of the script per project size, 60 timed calls
per row in each run; each cell gives the lowest and highest of the three runs:

| Project | Read-only command (`ls src`, no snapshot), p50 | Changes files (`rm -rf src/m000`), project unchanged since the last snapshot, p50 | First command that changes files, initial snapshot included |
|---|---|---|---|
| 5,000 files, 50 MB | 12.5–12.7 ms | 26.0–26.4 ms (p90 26.5–27.3 ms) | 566–729 ms |
| 500 files, 5 MB | 12.4–13.0 ms | 15.4–15.7 ms | 86–93 ms |

For a command that changes files the hook also walks the project to find that nothing changed, so that time grows with
the project's size. The first such command in a new project pays for the initial snapshot (one call per run). Over
the hook's 1.5 s deadline, the snapshot is kept as incomplete and finished in the background; until it is done, a
command that needs a snapshot (`rm`, `mv`, `git reset --hard`, …) waits for the user instead of running
([design/10 §4.6](design/10-snapshot-engine.md)).

## Snapshots and restore

From the snapshot engine's own measurements, [design/10 §11](design/10-snapshot-engine.md) (2026-10-18, Apple M4,
release build), taken before 0.1.1 and not re-measured for it:

| | 5k files (48 MB) | 50k files (388 MB) |
|---|---|---|
| First snapshot | 0.74 s | 9.3 s |
| Unchanged | 9–11 ms | 116–184 ms |
| 100 files changed | 47 ms | 164 ms |
| Restore 100 files, with the snapshots before and after it and process start | 60 ms | 410 ms |

## Guard on real commands

`Scripts/breaker-corpus.py` replays the distinct shell commands (command and folder) from the Claude Code sessions on
this Mac through two `airbag` binaries with `airbag check`, which never runs anything, and compares the verdicts.

```bash
python3 -I Scripts/breaker-corpus.py OLD_AIRBAG NEW_AIRBAG
```

2026-10-24, 0.1.1 release build: 2,578 commands. 2,467 allowed (95.7 %), 109 asked (4.2 %), 2 blocked (both an agent
running `airbag allow` on its own command). Only Claude Code sessions are in this corpus, from one person's work, and
it grows as sessions happen, so a later run replays more commands.

## Not measured yet

Idle CPU and memory of the app for this build. The release checklist ([QA.md](QA.md), item 10) asks for under 1 % CPU
and under 100 MB after ten idle minutes with one live session.
