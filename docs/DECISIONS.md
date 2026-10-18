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
