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

**ADR-030 Record instead of asking where the agent has no prompt.** A question the user rubber-stamps protects nothing,
and a deny that waits for a click in the menu bar is the manual mode nobody runs agents in. Where the agent can show
its own approval prompt (Claude Code, Cursor, Copilot outside bypass permissions) that prompt stays. Elsewhere a risky
command (an ask) now runs after a snapshot, is recorded in Guard as "ran without asking" and puts a dot on the icon.
Blocks are unchanged, and a destructive project command whose snapshot failed still waits for the user. Settings →
"When a snapshot can't undo a command" → "Stop Until I Approve" restores ADR-012's deny with a one-shot allowance.
An agent running `airbag allow` is blocked (`self.allow`): self-approval would make every question a slower allow.

**ADR-031 English source, 19 interface languages.** Supersedes the language list of ADR-016. The interface is written in
English and ships in English, German, Spanish, French, Italian, Dutch, Polish, Brazilian Portuguese, Turkish,
Ukrainian, Russian, Kazakh, Hindi, Indonesian, Vietnamese, Japanese, Korean and Simplified and Traditional Chinese.
It follows the system language; Settings → Language overrides it for Airbag only (per-app `AppleLanguages`, applied on
restart). Russian is the hand-reviewed reference that `check-l10n.py` compares every language against (keys, format
specifiers, CLDR plural forms). Right-to-left languages wait for a layout review. Agent-facing reasons stay English.


**ADR-032 Read-only commands, never-project folders and a size cap for the rest.** A read-only diagnostics session
(2026-10-21) cloned `~/Library/Caches` (32k files, 7.9 GB), an app bundle 22 times and the private keys in `~/.ssh`,
and the walk set off bursts of macOS privacy denials. Three changes. (1) Whether a command reads or writes is decided
from its arguments for the tools that do both (`sed` without `-i` or a `w` command, `sqlite3` with only SELECT/PRAGMA
queries, `ssh-keygen -l/-y/-F`, `launchctl print/list`, `log show`, `plutil -p`/`-o -`, `codesign -d`, `xattr -l`,
`curl` without an output file, …); assignments after `do`/`then`, `case` patterns and `perl -e 'alarm N; exec @ARGV'`
no longer count as commands. `airbag check` names what makes a command need a snapshot. (2) Nothing inside app
bundles, `/Library`, `/usr`, `/private/var` (per-user temporary folders included), `~/.ssh`, `~/.gnupg`, `~/.aws`,
`~/.Trash` or the data folders of `~/Library` (Caches, Containers, Group Containers, Mail, Messages, Safari, Logs,
Preferences, Developer, …) becomes a root, on top of the home folder and its standard folders themselves (ADR-027).
Stores made before are left on disk untouched and listed by `airbag usage` for the user to delete. (3) A root that is
neither a git checkout nor the agent's launch folder is snapshotted only while it holds at most 5,000 files and
500 MB; the cap is stored with the store, so the app and background snapshots honour it. Retention also caps each root
at 200 unpinned snapshots within the 7-day window. `csrutil status`, `fdesetup status|isactive|list|…`, `nvram -p`,
`nvram NAME` and `bless --info|--getBoot` are allowed; every other use of these tools stays blocked (`sys.security`).

**ADR-033 Undo without a confirmation; Restore with one.** Two verbs only. *Undo* puts back what one moment changed
(the files that snapshot recorded, as they were in the snapshot before it) and runs at once from the popover, the
Timeline row and the file menu: it is reversible, because the restore snapshots first and its message offers Undo
(⌥⇧⌘Z later). *Restore* makes the whole project, or a file, match a chosen moment; it can overwrite later good work,
so it opens the confirmation window, which groups the plan into files brought back, files reverted and newer files
set aside. The restore target is always looked up in the store (the snapshot before the moment), never taken from
what a filtered list shows. The Timeline is command-centric: a command's before and after snapshots form one row named
by the command, whose Undo reverts exactly what that command did.

**ADR-034 Evidence over configuration, and a quiet notification policy.** "Connected" in Settings and onboarding
comes with the last time that agent called Airbag (`events`), so a hook that is installed but never runs (Codex
before `/hooks` trust, managed settings) reads "no commands yet" instead of "Protected"; "Test Protection" runs the
exact binary written into agent configs on a command it must block. The popover leads with the state that matters
(an agent waiting > paused > a protection problem > "Protecting N projects") and proves its work ("212 commands checked
today"). Notifications: an agent waiting for approval rings (Allow Once / Show); a block and a command that ran
without asking go quietly to Notification Center, one per session; servers left running offer Stop / Keep Running;
nothing while the popover already shows the item, and nothing for snapshots, restores done in the app or pauses.
"Keep Running" is stored, so kept servers stay quiet after a relaunch. Settings is a real Settings window (⌘,).

**ADR-035 Switching Airbag off and a missing snapshot wait for the user whatever the setting; an empty folder
counts as captured.** Three changes for 0.1.1 (2026-10-24). (1) An exception to ADR-030: a finding from a `self.`
rule is never just recorded. It stops the agent until the user approves, with the agent's own prompt where it has one
and otherwise a deny with "Allow Once" in Airbag, also for Claude Code under bypass permissions, Codex and Gemini CLI
and whatever Settings → "When a snapshot can't undo a command" says. The rules cover editing, emptying, moving or
removing the user-level hook files of Claude Code (`~/.claude/settings.json`, `settings.local.json`), Codex
(`~/.codex/hooks.json`, `config.toml`), Cursor (`~/.cursor/hooks.json`), Gemini CLI (`~/.gemini/settings.json`) and
Copilot CLI (any `~/.copilot/hooks/*.json`, `~/.copilot/settings.json`, `settings.local.json`); removing or moving a
folder that holds one (such as `~/.copilot/hooks`); `airbag hooks uninstall` (not with `--dry-run` or `--help`);
`airbag hooks install --command` or `--home`, which re-point the hooks; and `brew uninstall|remove|rm` of the cask.
Recording them would let an agent switch off the protection that does the recording. Not covered: the agents' own
file-edit tools (the hooks match shell tools only, for Claude Code `Bash|Monitor`; Codex's `apply_patch` only gets a
snapshot before the edit), project-level settings (a project's `.claude/settings*.json` with `disableAllHooks`),
interpreter one-liners that write the file (`python3 -c`, `node -e`), and anything while Airbag is paused (SQL that
writes to Airbag's own database through `sqlite3` is a hard block, `self.airbag`). The rules read command text, so a hostile process running as the
user can get around them. Hard blocks (`self.airbag` on Airbag's data, `self.allow`) are unchanged, and a pause still
skips every question (ADR-021). (2) A command whose verdict needs a snapshot (`snapshot: required`: `rm`/`mv` in the
project, `git reset --hard`, `git clean`, …) and did not get a usable one waits for the user even when its verdict
was already an ask; before, where asks are only recorded (ADR-030), such an ask ran. Commands that only recommend a
snapshot (`sed -i`, scripts, `cp` onto a project file) still run when it fails. (3) A folder with no files has
nothing to snapshot, which read as "snapshot unavailable": the first file an agent wrote into a new empty folder
needed approval, or was denied under bypass permissions. When the walk saw the whole folder (no deadline, nothing unreadable), found no
files, skipped none for size and hit no errors, the snapshot requirement now counts as met (the command is allowed
unless another rule asks) and the event records `snapshot_skipped = "empty"`. A folder the user stopped protecting
(`snapshot_skipped = "not_protected"`) is treated the same: it gets no snapshot and needs none; blocks still apply.
A walk cut short proves nothing and still counts as incomplete. Amended after 0.1.1: both, like a usable snapshot,
count per root. Each root a destructive finding targets needs its own, so the hook also snapshots the agent's launch
folder or the main checkout of its worktree when a finding targets it (and only then), and the command waits for the
user when that snapshot fails. 0.1.1 shipped a narrower guard: an empty session folder did not cover another
protected root, but a snapshotted one did, so `rm ../notes.txt` from a nested repository in the launch folder ran
without a snapshot of the launch folder and the file could not be restored.
