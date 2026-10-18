<p align="center"><img src="Resources/AppIcon-1024.png" width="128" alt="Airbag icon"></p>

# Airbag

**A safety net for AI coding agents on your Mac.** Airbag takes a snapshot of your project before every shell
command an agent runs, lets you roll any file, folder or the whole project back in one click, stops the few
commands no snapshot can undo, and shows which agent session left which dev server running.

Free, native, MIT-licensed. No account, no telemetry, no network. macOS 14+.

> *Русский:* Airbag — бесплатная нативная утилита в строке меню, страховка от ИИ-агентов. Снимок проекта перед
> каждой shell-командой агента, откат в один клик, предохранитель от разрушительных команд и радар dev-серверов с
> привязкой к сессии агента. Интерфейс на русском и английском.

## Why

Agents now run unattended, in auto mode, overnight. Their built-in undo only covers edits made by their own file
tools: Claude Code's checkpoints explicitly skip files changed through Bash, Codex has no `/undo`, and Time
Machine's hourly local snapshots miss disasters that take minutes. Meanwhile `rm -rf`, `git reset --hard`,
`git clean -fdx` and "cleanup scripts" keep wiping real work, and dev servers outlive the sessions that started
them. Airbag sits *underneath* the agents, independent of them.

<p align="center">
  <img src="docs/images/popover-light.png" width="300" alt="Menu bar popover">
  <img src="docs/images/main-timeline-light.png" width="520" alt="Timeline with diff and restore">
</p>

## What it does

| | |
|---|---|
| **Snapshots** | Before every agent shell command (via hooks) and after file changes (FSEvents). APFS clones: a snapshot of an unchanged 50k-file project costs ~120 ms and almost no disk. `.env` and other git-ignored files are included; `node_modules`, build output and caches are not. |
| **Timeline & restore** | Every snapshot is labelled with the command it preceded ("Before `rm -rf src/legacy`") and the agent session. See changed files, diffs, restore a file, a folder or the whole project. A restore never deletes anything: files in the way are moved into Airbag's store, and the restore itself is undoable. Even a project folder that was deleted entirely can be brought back. |
| **Circuit breaker** | Inside the project, destructive-but-recoverable commands are allowed *after* a snapshot. Commands whose damage lies outside every snapshot are blocked (your home folder, system folders, parents of the project, disks, power) or need your approval (other folders, force-push, databases, cloud resources, `curl \| sh`, `sudo`). 386 test cases, including an adversarial red-team set. |
| **Radar** | Listening dev servers with the project, the agent and the session that started them — also after the agent exited, thanks to the environment the agent leaves in its child processes. Orphans (session ended, server still running) are flagged; stop them with SIGTERM, force-stop only as a separate click. |

## Supported agents

| Agent | Snapshot before shell commands | Block | Ask | Session tracking |
|---|---|---|---|---|
| Claude Code (CLI, desktop, IDE) | ✓ | ✓ | native prompt | ✓ |
| Codex (CLI, app) | ✓ | ✓ | deny + "Allow once" in Airbag | ✓ (trust the hooks once in `/hooks`) |
| Cursor (IDE, CLI) | ✓ | ✓ | native prompt | ✓ |
| Gemini CLI | ✓ | ✓ | deny + "Allow once" in Airbag | ✓ |
| GitHub Copilot CLI | ✓ | ✓ | native prompt | ✓ |

Airbag writes one entry into each agent's **user** settings file (never into project files), keeps a backup, and
removes exactly its own entries on uninstall. Without hooks, Airbag still snapshots protected projects on file
changes.

## Install

```bash
brew install --cask airbag      # from the project tap once released
```

Or download the notarized DMG from Releases. First launch walks you through connecting agents and picking
projects (under a minute).

## Command line

The CLI (`airbag`, linked by the cask) works without the app:

```text
airbag snapshot [--root DIR]          take a snapshot now
airbag snapshots | log | changes ID   what happened, with the snapshot before each agent command
airbag diff FROM [TO] [--path F]      what changed (TO omitted = working tree)
airbag restore ID [--path P]          restore (never deletes; prints the undo command)
airbag check "<command>"              what the breaker decides, and why
airbag ports | stop PID [--force]     dev servers and the session that started them
airbag hooks status | install | uninstall [--all]
airbag guard | allow ID               blocked commands; approve one once
```

## How it works

```
agent ──hook──▶ airbag (CLI): parse → rules (≈1 ms) → snapshot (APFS clones) → reply → registry (SQLite)
                                                                            │
Airbag.app (menu bar): timeline · restore · radar (libproc, ~5 ms/scan) · FSEvents snapshots · retention
```

Protection never depends on the app being open. Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
decisions: [docs/DECISIONS.md](docs/DECISIONS.md), snapshot engine: [docs/design/10-snapshot-engine.md](docs/design/10-snapshot-engine.md),
breaker: [docs/design/12-circuit-breaker-rules.md](docs/design/12-circuit-breaker-rules.md).

Measured on an M-series Mac: hook overhead p50 ≈ 12–15 ms (process start to reply); snapshot of an unchanged 5k-file project 10 ms (50k files
≈ 120 ms); restoring 100 files 60 ms; idle app 0 % CPU and 19 MB.

## Honest limits

- Text analysis of shell commands can never be complete; the snapshot is the real safety net. Code hidden in
  scripts, generated at runtime, or run on remote machines is outside what the breaker can see.
- Snapshots cover project files. They do not cover `.git` history, databases, cloud resources, or folders Airbag
  skips by design (`node_modules`, build output, files over 100 MB).
- Hooks fail open by default (a crashed hook lets the command run); strict mode flips that for Claude Code and Cursor.

## Privacy

Everything stays in `~/Library/Application Support/Airbag` (owner-only permissions, excluded from Time Machine and
Spotlight). Snapshots contain copies of your files, including `.env`. Command output is never stored; secrets in
command lines are masked before they are logged. See [SECURITY.md](SECURITY.md).

## Build from source

Command Line Tools are enough; Xcode is optional.

```bash
make test        # Swift Testing suite
make app         # build/Airbag.app (ad-hoc signed)
make e2e         # simulated agents against the real hook binary
```

## License

MIT — see [LICENSE](LICENSE).
