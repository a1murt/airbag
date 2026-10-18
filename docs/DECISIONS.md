# Architecture decision records

Each ADR: context → decision → consequences. Status is "accepted" unless noted.

**ADR-001 Name and identifiers.** The metaphor (protection that deploys when something goes wrong) fits the
product. Collisions found 2026-10-17: three tiny same-audience repos (≤ 2 stars), npm `airbag` and GitHub user
`airbag` taken; Homebrew, Mac App Store and PyPI free (research 05 §8). Decision: keep "Airbag", bundle id
`dev.airbag.Airbag`, cask `airbag`, CLI `airbag`. Consequence: revisit before a public launch if one of the repos
gains traction.

**ADR-002 Toolchain.** The development Mac has Command Line Tools only. Decision: SwiftPM-only build, no `.xcodeproj`
in the repo (open `Package.swift` in Xcode if wanted), app bundle assembled by `Scripts/build-app.sh`, Swift
Testing (XCTest is unavailable with CLT). `.xcstrings` and asset catalogs are not used (they silently fail without
Xcode); strings are `.lproj/Localizable.strings`, icons are `.icns` built with `iconutil`.

**ADR-003 Snapshot engine = APFS clones + log-structured SQLite manifest** (doc 10). Rejected: external git store
(needs CLT git, slower hot path, restore hazards), custom CAS with compression (more code, slower restores).

**ADR-004 Stores keyed by root** (main checkout, worktree or plain folder), not by project. Keeps each store small
and its lifecycle tied to the directory; worktree stores age out with retention.

**ADR-005 Snapshots ignore `.gitignore`.** `.env` and local databases are the files agents destroy. Heavy
regenerable directories are excluded by name instead (doc 10 §5); size cap 100 MiB (clone) / 20 MiB (copy).

**ADR-006 Retention: 7 days, newest 20 per root, pinned forever, 5 GiB global budget.** Matches doover's defaults
cited in the market report; budget wins over age under heavy churn.

**ADR-007 SQLite registry shared by CLI and app** (WAL, `busy_timeout`, `BEGIN IMMEDIATE`, spool on failure).
Measured 0 `SQLITE_BUSY` across 4000 concurrent transactions (research 04 §9).

**ADR-008 The CLI is the hook and works without the app.** Protection must not depend on a GUI process being
alive. The app is a client of the same files.

**ADR-009 IPC = unix socket as a wake-up signal only.** No decision ever waits on the app. XPC rejected (needs a
launchd Mach service). Distributed notifications rejected (no sender identity).

**ADR-010 Fail-open by default, strict mode opt-in.** A safety tool that bricks the agent gets uninstalled. Rules
are evaluated before any I/O so the common failure modes (DB, store) never weaken a deny.

**ADR-011 Snapshot first, block only the unrecoverable.** Text-based blocking is unbounded (CC Safety Net's
release stream, research 05 §3). Commands inside a protected root that a snapshot can undo are allowed after a
snapshot; commands whose damage is outside every snapshot (home directory, system paths, remote databases, force
pushes, disk erasure) are blocked or asked.

**ADR-012 `ask` fallback = deny with a one-shot allowance** for agents without a native ask (Codex, Gemini) and
for Claude under bypass permissions. The allowance is bound to (session, SHA-256 of the exact command), expires
in 10 minutes.

**ADR-013 SIGTERM first, SIGKILL as a separate user action.** Never signal agents, host apps, terminals, IDEs or
system processes. Process identity is `(pid, start time)` and is re-validated before every signal.

**ADR-014 Badge only on a blocked command or a new orphan.** The menu bar is scarce; no per-turn notifications.

**ADR-015 No telemetry, no accounts, no network.** An opt-in update check against GitHub Releases may come later.

**ADR-016 Localization: EN + RU from the first release.** User-facing strings localized; agent-facing reasons
English (models act on them).

**ADR-017 Licence MIT, macOS 14+, no third-party dependencies.** Argument parsing, SQLite wrapper, ULID and diff
are small enough to own.

**ADR-018 Swift 5 language mode on the 6.1 toolchain.** Strict concurrency checking is a cost without benefit for
code dominated by C interop and single-threaded short-lived CLI runs; revisit for the app target later.

**ADR-019 Hook path inside the app bundle** (`Airbag.app/Contents/Helpers/airbag`), plus the cask's
`/opt/homebrew/bin/airbag` symlink for terminal use. The installer writes one absolute path per machine and keeps
it stable (Codex trust hashes the command string).

**ADR-020 User-scope hook configs only.** Project-level configs trigger trust prompts and get committed by
accident; Airbag never writes them.

**ADR-021 Pause keeps hard blocks.** Pausing skips snapshots and questions, but catastrophic commands stay blocked:
blocking costs nothing and is the one thing a user never wants to lose by accident.

**ADR-022 Paths are stored in NFC.** Swift compares strings by canonical equivalence, SQLite by bytes; APFS/HFS+
resolve both forms to one file. Normalising every key to NFC keeps the three in agreement (independent review, blocker).

**ADR-023 Timeline actions are about the change, not the snapshot id.** A card lists what changed *into* a snapshot;
"Undo these changes" restores those paths to the previous snapshot, "Restore project to this moment" restores to
the card's own snapshot.

**ADR-024 The reply is printed before persistence.** The agent waits only for the decision and the snapshot; registry
writes, spool ingestion and the app ping follow. A watchdog timeout prints the conservative reply prepared before
the snapshot started, never a bare allow.

**ADR-025 Measure the breaker on real agent history.** Fixtures encode what we thought of; the owner's own sessions
encode what agents actually run. `Scripts/breaker-corpus.py` replays every shell command in `~/.claude/projects`
through two builds (analysis only) and reports the ask rate and every changed decision. On 1585 commands the first
public build asked 17 % of the time; the dogfooding fixes brought it to 3.7 %, every remaining ask justified (force
pushes, history rewrites, overwriting files on the Desktop, `~/.ssh/config`, remote `rm -rf`). A change that raises
the ask rate needs a reason.

**ADR-026 A write outside the project asks only when it replaces something.** With the real file system, creating a
new file outside the project destroys nothing, so redirects, `cp` and truncation ask only when the target exists. A
`mv` that replaces an existing file outside the project asks. Fixtures (no file system) keep assuming it exists.

**ADR-027 A project the command `cd`s into is protected like the session's own.** Sessions often start in a folder
that is not the project (Claude's "No folder" sessions, a parent directory) and work through `cd ~/Work/app && …`.
The hook adds the projects of every `cd`/`pushd` target to the protected roots and snapshots them before and after
the command. The home folder and system folders never become roots, even when the home folder is a git repository.

**ADR-028 Here-documents: shell bodies are analysed, interpreter bodies are scripts.** `bash <<EOF … EOF` is shell
code and gets the full analysis. A body fed to `python3`, `node` or similar is a whole script and is treated like a
script file (snapshot, no text heuristics), because the one-liner heuristics flagged string data in real agent
scripts. An unquoted delimiter still exposes `$(…)` in any body.

**ADR-029 An unterminated quote at the top level asks.** The shell would refuse such a line, so if the lexer sees one
the lexer and the shell disagree (the case that hid `&& rm -rf` behind an apostrophe in a here-document). Nested
analyses (re-joined `xargs` words) do not count.

