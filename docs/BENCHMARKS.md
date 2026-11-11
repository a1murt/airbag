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

2026-11-10, Apple M4, macOS 27.0.1, release build of 0.1.6 (the Guard hardening of ADR-042). Three runs of the script
per project size, 60 timed calls per row in each run; each cell gives the lowest and highest of the three runs:

| Project | Read-only command (`ls src`, no snapshot), p50 | Changes files (`rm -rf src/m000`), project unchanged since the last snapshot, p50 | First command that changes files, initial snapshot included |
|---|---|---|---|
| 5,000 files, 50 MB | 11.4–11.5 ms | 25.3–25.4 ms (p90 25.7–25.8 ms) | 571–591 ms |
| 500 files, 5 MB | 11.3–11.4 ms | 14.2–14.4 ms | 88–92 ms |

The 0.1.1 build measured on 2026-10-24 gave 12.4–13.0 ms, 15.4–26.4 ms and 566–729 ms for the same rows.

2026-11-11, after the red-team changes (ADR-043), the 5,000-file row on a busier machine, alternating with the installed
0.1.5 in two rounds: read-only 13.1–13.4 ms against 12.8–13.0 ms for 0.1.5, changing files 27.2–27.4 ms against
26.9 ms. `airbag check` alone, 80 calls per command alternating the two builds, differed by 0.1 ms at most. Within
noise of each other; the table above stays the reference for an idle machine.

For a command that changes files the hook also walks the project to find that nothing changed, so that time grows with
the project's size. The first such command in a new project pays for the initial snapshot (one call per run). Over
the hook's 1.5 s deadline, the snapshot is kept as incomplete and finished in the background; until it is done, a
command that needs a snapshot (`rm`, `mv`, `git reset --hard`, …) waits for the user instead of running
([design/10 §4.6](design/10-snapshot-engine.md)).

## Snapshots and restore

From the snapshot engine's own measurements, [design/10 §11](design/10-snapshot-engine.md) (2026-10-18, Apple M4,
release build), taken before 0.1.1 and not re-measured since:

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

2026-11-11, final 0.1.6 release build (with the red-team changes of ADR-043) against 0.1.5: 5,090 commands. 4,882
allowed (95.9 %), 205 asked (4.0 %), 3 blocked: twice an agent running `airbag allow` on its own command, once a command
that deleted a temporary folder holding a git project it then entered (a project a command enters is protected, and
deleting the folder around a protected project is blocked; 0.1.5 blocks it too). No decision changed between the two
builds. A first version of the secret-file rule stopped any change inside `~/.ssh`; replaying it turned five everyday
commands stricter (appending a `Host` to `~/.ssh/config`, `chmod 600` on it, `perl -i` on it), so the rule now names
the secret files themselves.

2026-11-10, 0.1.6 release build before the red-team changes, against 0.1.5: 4,944 commands. 4,738 allowed (95.8 %), 204
asked (4.1 %), 2 blocked (both an agent running `airbag allow` on its own command); no decision changed between the two
builds, and no command meets the rules that always wait (ADR-042). Only Claude Code sessions are in this corpus, from
one person's work, and it grows as sessions happen, so a later run replays more commands. An earlier run, 2026-10-24 on
0.1.1, replayed 2,578 commands: 95.7 % allowed, 4.2 % asked, 2 blocked.

## Guard under hostile input

`Scripts/guard-fuzz.py` generates commands built to break the parser (brace sequences at the ends of Int, deep
`$(…)` nesting, unbalanced quotes, very long words, the padding that once slowed the verdict) and fails if `airbag
check` crashes or takes longer than 2 s on any. CI runs 2,000 of them on every push; `make fuzz` runs 3,000.

```bash
python3 -I Scripts/guard-fuzz.py --count 3000 --seed 1
```

2026-11-11, final 0.1.6 release build: 0 of 3,008 crashed or took longer than 2 s, seeds 1, 5 and 11 (also on
2026-11-10, before the red-team changes). The 0.1.4
release build crashed on 18 of 203, all from one bug (`abs()` of `Int.min` in brace expansion), fixed in 0.1.5.

## Not measured yet

Idle CPU and memory of the app for this build. The release checklist ([QA.md](QA.md), item 10) asks for under 1 % CPU
and under 100 MB after ten idle minutes with one live session.
