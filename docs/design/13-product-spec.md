# 13 — Airbag v1 product spec and UX (MVP), with v1.1 / v2 outline

Date: 2026-10-17. Status: design, ready for implementation review. Audience: the engineers building Airbag v1 and the person deciding scope.

Grounding: the product thesis is `docs/research/00-source-market-report-ru.md`; every mechanism referenced here is taken from the research notes 01–06 (`docs/research/`), which were verified on 2026-10-16/17. Where this spec adds a claim of its own, it carries a tag: [verified] = primary source or local probe read today; [likely] = strong inference or secondary source; [unverified] = not confirmed; [decision] = a product choice made in this document, not a fact. Local facts were re-checked on this Mac (macOS 15.7.9, CLT 16.4, Apple Git 2.39.5, Claude Desktop hosting Claude Code 2.1.295, system languages `ru-KZ, kk-KZ`).

How to read: §1–§3 say what Airbag is and is not; §4 is the system model the UX relies on; §5–§9 are the screens and behaviours; §10 is the copy deck (every user-facing string, EN + RU, with keys); §11–§14 cover errors, empty states, privacy and the agent-facing text; §15 metrics; §16 roadmap; §17 icon; §18 Swift signatures for the UX-facing modules; §19 open decisions.

---

## 0. TL;DR

1. Airbag is a safety net under local coding agents, not a monitor of them. It sells one promise ("undo anything the agent did to your project, even through bash") and earns its menu bar slot with a second ("see and stop what the agent left running"). The market report ranks these first and second and marks every neighbouring feature (limits, attention, orchestration) as closed or non-goal [verified: report §Рейтинг].
2. MVP = hook bridge + session registry, per-project hidden git store with per-command and FSEvents snapshots, Timeline with file/folder/project restore that itself snapshots, a recoverable-first circuit breaker (block only the unrecoverable, ask for the rest), a libproc radar with session and worktree attribution, a quiet menu bar icon. Agents: Claude Code and Codex first-class; Cursor and Gemini CLI supported through their native hooks; Copilot CLI in v1.1 [decision].
3. Onboarding is four steps in under 60 s: detect agents → one-click hook install with an exact before/after preview of each settings file and an uninstall promise → protected projects suggested from recent sessions plus manual add → done. No Full Disk Access, no accounts, no network.
4. The icon has five states (idle, protected, snapshotting, blocked, orphan) plus a degraded variant; a dot badge appears only for a blocked command or a new orphan and clears when seen. The dropdown opens with one summary line: "3 projects protected · snapshot 4 s ago · 3 servers · 1 orphan".
5. Copy tone: calm, specific, never alarmist. Every event names the agent, the session, the project and what Airbag did. The agent-facing block text is English, structured, and ends with a safe alternative and the way the user can allow the command.
6. Everything the hook needs (rule evaluation, snapshot, registry write) works with the GUI closed; the GUI adds FSEvents snapshots, the radar and the views. SQLite is the contract between the two [verified: note 04 §7].

---

## 1. Positioning

### 1.1 Positioning statement

EN: For developers and semi-technical builders who run Claude Code, Codex, Cursor or Gemini CLI on their own Mac, Airbag is a free, native menu bar utility that takes project snapshots independently of the agent (before every agent shell command and on every file change), lets you roll back a file, a folder or the whole project in one click, blocks or asks before the handful of commands that cannot be undone, and shows which agent session left which dev server and port running so you can stop it. Unlike the agents' own checkpoints (`/rewind` skips Bash changes, Codex has no `/undo`) and unlike CLI blockers and port killers, Airbag combines recovery, prevention and cleanup in one app that keeps working when the agent is gone, with no accounts, no telemetry, no Full Disk Access.

RU: Для разработчиков и полутехнических билдеров, которые запускают Claude Code, Codex, Cursor или Gemini CLI на своём Mac, Airbag — бесплатная нативная утилита в строке меню, которая делает снимки проекта независимо от агента (перед каждой его shell-командой и при каждом изменении файлов), откатывает файл, папку или весь проект в один клик, блокирует или переспрашивает перед теми немногими командами, которые нельзя отменить, и показывает, какая сессия агента оставила запущенным какой dev-сервер и порт, чтобы его можно было остановить. В отличие от встроенных чекпоинтов агентов (`/rewind` не видит изменения через Bash, у Codex нет `/undo`) и в отличие от консольных блокировщиков и «убийц портов», Airbag соединяет восстановление, предотвращение и уборку в одном приложении, которое продолжает работать, когда агента уже нет, — без аккаунтов, без телеметрии, без Full Disk Access.

### 1.2 One-line pitch

EN: "Airbag: undo anything your coding agent did to your project, and stop what it left running."

RU: «Airbag: откатите всё, что агент сделал с проектом, и остановите то, что он оставил запущенным».

Secondary line for the README and cask `desc` (≤ 80 chars, English only, Homebrew convention): "Safety net for local AI coding agents: snapshots, rollback, circuit breaker, port radar" [verified: note 04 §6.6 cask template].

### 1.3 What Airbag promises and what it does not

| Promise | Scope | Not promised |
|---|---|---|
| Snapshots independent of the agent | Files inside protected projects (and their worktrees), including untracked and `.gitignore`d files such as `.env` (toggle), excluding `node_modules/`, `dist/`, `.next/`, `.git/`, files ≥ 50 MiB (visible skipped list) [verified: note 06 §3, §10] | Files outside protected projects; remote databases; anything the agent did over the network |
| Rollback of file / folder / project, itself reversible | Restore from any snapshot; a pre-restore snapshot is always taken first; files the snapshot never captured are never deleted [verified: note 06 §7] | Restoring the project's own `.git` history; nested `.git` directories (open question, note 06 §15.1) |
| Circuit breaker | Short, explainable list of block/ask rules evaluated in the hook binary before the command runs; `deny` holds even under `--dangerously-skip-permissions` in Claude Code [verified: note 01 §4] | A security boundary against a hostile agent or plugin (a user-installed mod can override a settings-file hook, note 01 §4.4; a Docker bind-mount bypass was reported, note 05 §6); commands typed into an already-running interactive session (Codex `write_stdin`, note 02 §2.3) |
| Radar with attribution | Listening TCP sockets of same-uid processes, attributed to project, worktree, agent and session; orphan detection; SIGTERM then SIGKILL as separate actions [verified: note 04 §1, §10] | Root processes, Docker-internal ports (v1 shows the VM helper's host port only), Kubernetes, tunnels |
| Native, light, private | ≤ ~100 MB `phys_footprint`, idle CPU < 1 %, macOS 14+, no network calls except nothing (updates via Homebrew), no telemetry, MIT, notarized | Windows/Linux; App Store |

### 1.4 Principles (each traceable to a documented failure of a neighbour)

1. Recovery first, blocking last. Snapshot and allow anything inside a protected project; block only what cannot be restored (Demo_CLI, doover, agentundo; note 05 §5.3). Users uninstall blockers that cry wolf; they keep the thing that gave them their files back.
2. The agent is not trusted to protect the user from the agent. Hooks are the attachment point, but FSEvents snapshots keep working when hooks are missing, untrusted (Codex) or bypassed [verified: note 02 §2.7, note 03 §8].
3. Every destructive thing Airbag itself does is reversible: restores snapshot first; stops are SIGTERM with identity re-check, SIGKILL is a separate click (LeftOpen); the retention sweep never touches pinned snapshots; uninstall removes exactly the handlers Airbag wrote [verified: note 01 §6.1, note 04 §10].
4. Quiet by default. One summary line; a badge only for a blocked command or a new orphan; no notification for a snapshot, ever (market report: the menu bar is a scarce resource; 43 % of one user's notifications were idle reminders).
5. Say exactly what happened. Event titles carry the command, the agent, the session name, the project; errors say which file, which path, which rule. No "something went wrong".
6. Nothing leaves the machine. Snapshots contain `.env`; the store and registry are 0700/0600; command text is redacted of secrets before storage; no analytics (note 05 §9.5, note 06 §12).
7. Works with CLT only, builds with SwiftPM, ships as a notarized Homebrew cask: the two closest free radar/disk tools are ad-hoc signed; notarization is a differentiator (note 05 §9.9).

---

## 2. Personas and jobs-to-be-done

### 2.1 Persona A — the parallel-agent developer

Profile: professional developer, 3–10 years, macOS, Apple silicon, 16–36 GB RAM. Runs 3–6 Claude Code and Codex sessions in worktrees (desktop app tabs, cmux or iTerm2), several in auto mode or `--dangerously-skip-permissions` [verified: report; r/ClaudeCode posts]. Knows git well, does not want another git client. Already has CodexBar and maybe cc-safety-net.

Pains (from the report and trackers): agent forgets it started a dev server and starts another (#9780); parallel sessions kill each other's processes (#25464); orphaned `next dev` at 8 GB after the session ended, closed as not planned (#43944); `rm -rf` through bash that `/rewind` cannot undo; 80–200 GB of worktrees.

What they will judge Airbag on: hook latency (p95 well under a second), zero false blocks on their normal git workflow, correct attribution of ports to the right worktree, honest "unknown" when attribution is weak, and that it never touches their `.git`.

### 2.2 Persona B — the semi-technical builder

Profile: founder, designer, data person or student who learned to ship with Claude Code or Cursor in 2026; runs one agent at a time, mostly in the Claude desktop app or Cursor; uses git because the agent told them to, commits rarely, has never done a restore. Has a Supabase or Prisma project with a `.env` [verified: report, "vibecoded apps" posts].

Pains: "claude just deleted my entire project"; `prisma migrate reset --force` wiped the database; "yesterday it worked"; does not know what `git reset --hard` means when the agent proposes it; menu bar full of icons they do not understand.

What they will judge Airbag on: whether the first screen explains itself, whether "Restore" does what it says without git words, whether the blocked-command explanation tells them what to do next, and whether it works in Russian.

### 2.3 Jobs-to-be-done

| # | Job (when … I want to … so that …) | Trigger | Today's workaround | Airbag answer | Signal of success |
|---|---|---|---|---|---|
| J1 | When an agent command destroys files, I want to get them back in one click, so that an hour of work is not lost | Timeline shows "Before `rm -rf src/legacy`" | `git checkout`, Time Machine (hourly, misses minutes-long disasters), re-prompting | Timeline → event → Restore folder | Restore completed, pre-restore snapshot exists, no file outside the snapshot touched |
| J2 | When "it worked yesterday", I want to compare and roll back to the last state that built, so that I stop gambling on prompts | User opens Timeline after a bad turn | `git stash`, `git log -p`, scrolling chat | Diff viewer per snapshot; pin "last known good"; restore project | Pinned snapshot used in a restore |
| J3 | When the agent is about to run something unrecoverable, I want it stopped or confirmed before it runs, so that `~` and the database survive | PreToolUse hook fires | CLAUDE.md rules ("kept being a suggestion"), cc-safety-net | Breaker deny/ask with a reason the agent understands | Blocked event in Guard; agent proposes a safe alternative in its next message |
| J4 | When a session ends, I want to know which servers it left running and stop them, so that ports and RAM are free | SessionEnd or agent PID gone | `lsof -i :3000`, `kill-port`, Activity Monitor | Radar row "orphan" + "Session ended — stop its 2 servers?" | Servers stopped within a minute of the prompt |
| J5 | When two agents fight over port 3000, I want to see who owns what, so that I can decide | Port conflict | guessing | Radar attribution to session and worktree | User stops the right one |
| J6 | When I install a safety tool, I want to know exactly what it changed in my config and that it can be removed, so that I keep trusting my setup | Onboarding | reading the tool's source | Hook preview diff, backup file, uninstall promise, self-test | Hooks installed in the first session; uninstall leaves settings byte-identical except Airbag's handlers |
| J7 | When the agent is blocked, I (the agent) want to understand why and what is allowed instead, so that I can continue the task without the user retyping | Deny reason delivered | opaque "permission denied" | Structured agent-facing message (§14) | Agent's next action is the safe alternative or a request to the user |

---

## 3. Scope

### 3.1 MVP scope table

| Component | In v1 (MVP) | Acceptance criteria (testable) | Grounding |
|---|---|---|---|
| Hook bridge | One binary `airbag` (bundled at `Airbag.app/Contents/Helpers/airbag`) used as the hook command for Claude Code, Codex, Cursor, Gemini CLI; one-click install/uninstall/repair at user scope only; self-test after install | Hook spawn+decision overhead ≤ 10 ms p50 (exec form); self-test deny actually denies in each installed agent; uninstall restores every other key byte-for-byte | notes 01 §6.1, 02 §10, 03 §3.10/§4.8 |
| Session registry | SQLite (WAL) at `~/Library/Application Support/Airbag/registry.sqlite`; rows per `(agent, session_id)` with cwd, worktree, PIDs (+start times), terminal app, names, status; liveness from `~/.claude/sessions/<pid>.json` + `kill(pid,0)`/`procStart` for Claude Code, PID liveness for others | A session appears in the UI ≤ 2 s after SessionStart; disappears/retires ≤ 10 s after the agent PID dies even without SessionEnd | notes 01 §11, 02 §4, 04 §8 |
| Snapshot engine | Per-project bare git store under `~/Library/Application Support/Airbag/stores/<id>/`; own walker → `update-index` → `write-tree` → `commit-tree` (orphan) → `update-ref refs/airbag/snapshots/<ulid>`; triggers: pre-command (hook), post-command (hook, async), FSEvents (2 s quiet), manual, pre/post-restore, project-added | Steady-state snapshot ≤ 150 ms for 20k files; 2,000 changed files ≤ 1 s; first snapshot runs in the GUI, never in a hook; hook snapshot has a 3 s wall-clock cap after which the command is allowed and the miss is logged | note 06 §3, §5, §9, §14 |
| Timeline | Project → session → event; event card with changed files and statuses; diff viewer; restore file/folder/project with confirmation that itself snapshots; search/filter; pin "last known good" (manual) | Destructive-agent scripts (`rm -rf dir`, `mv`, `sed -i`, `git checkout -- .`, `git reset --hard`, `git clean -fdx`) are fully reverted from the UI with zero lost files (report's MVP criterion) | report §MVP; note 06 §7 |
| Circuit breaker (Guard) | Rule engine in the hook binary; tiers block / ask / notice; allow once / for session / always per project; per-agent ask fallback; strict mode toggle; log | Rules evaluate in < 1 ms; each rule has an ID, a test corpus, an agent-facing message; no false block on `git push --force-with-lease`, `rm -rf node_modules` inside a project | notes 01 §4, 02 §2.5, 03 §2, 05 §5–6 |
| Radar | libproc listening sockets every 2–5 s and on hook events; attribution ladder; orphan flag; Stop / Force stop / Reveal; "session ended — stop its servers?" | Full scan ≤ 2 ms; on a 3–5 session bench every dev server is labelled with its session incl. after the session ended; identity re-check before every signal | note 04 §1–2, §10; note 01 §13.6 |
| Menu bar | `MenuBarExtra(.window)` with `NSStatusItem`+`NSPopover` fallback; five icon states + degraded; dot badge policy; summary line; popover with attention rows, projects, view switcher | Idle `phys_footprint` of the app ≤ 100 MB after 24 h with 5 projects; idle CPU < 1 % (target < 0.2 %) | note 04 §5 |
| Settings | General, Agents & Hooks (status, repair, uninstall), Projects & excludes, Snapshots & retention, Guard rules, Notifications, Keep awake (placeholder), About/Privacy | Every setting has a default that needs no reading | this doc §7.4 |
| Localization | EN + RU via `.lproj/Localizable.strings` (+ `.stringsdict` for plurals) and an own bundle accessor | Both languages pass a layout check at 1.3× string length; RU plural forms correct for 1/2/5/21 | note 04 §6.2 |
| Distribution | SwiftPM build, assembled `.app`, Developer ID + notarization + stapling, Homebrew cask (own tap first) | `spctl -a` accepted; `brew install --cask` without Gatekeeper dialog | note 04 §6 |

### 3.2 Explicit non-goals (never) and deferred items

Never (market report "Никогда" and brief): usage/limit counters; "agent is waiting / done" attention features and notifications; orchestration, session spawning or terminal multiplexing; reading OAuth tokens or using the Agent SDK; telemetry, crash reporting that phones home, install counting; a git client (branches, merges, commits to the user's repo); whole-disk or cloud backup; a sandbox or a replacement for the agents' sandboxes; auto-killing processes without a click; project-level hook files (they get committed and trust-prompted; note 03 §8.1).

Deferred: disk cleaner, automatic last-known-good marks, keep-awake (v1.1, §16); pre-push secret check, hook-integrity watch, environment doctor (v2); Copilot CLI (v1.1 after a live probe of `toolArgs` and `exec`/`args`, note 03 §9.7); Codex `config/batchWrite` trust shortcut (only after a maintainer endorses it, note 02 §12.4); "Focus the terminal tab" via Apple events (opt-in, v1.1; needs `NSAppleEventsUsageDescription`, note 04 §5.5); side-by-side diff; history replay screen ("would have blocked N") (v1.1; Paveo-style, note 05 §5.14).

### 3.3 Agent support matrix for v1

| Agent | Tier | Before-shell hook | Ask | Session start/end | Attribution without hooks | Notes |
|---|---|---|---|---|---|---|
| Claude Code (terminal, desktop app, VS Code, `-p`) | 1 | `PreToolUse` matcher `Bash\|PowerShell\|Monitor` | yes (`ask` prompts even in auto; deny in `dontAsk`/unattended; bypass [unverified]) | `SessionStart`/`SessionEnd` + `~/.claude/sessions/<pid>.json` | env `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID` readable via `KERN_PROCARGS2` after reparenting | hooks held back until workspace trust in interactive sessions [verified: note 01] |
| Codex (CLI, app, `exec`) | 1 | `PreToolUse` matcher `^Bash$` (+ `PermissionRequest`) | no — ask tier degrades to deny-with-instructions + allow token | `SessionStart` (first turn), `UserPromptSubmit`, `Stop`, `SessionEnd` | env `CODEX_THREAD_ID`, `CODEX_SESSION_ID` | user must trust handlers once in `/hooks` (`t`); command string must stay byte-stable [verified: note 02 §2.7] |
| Cursor (IDE, CLI) | 2 | `beforeShellExecution` | yes | `sessionStart`/`sessionEnd` (CLI `sessionEnd` [unverified]) | env `CURSOR_AGENT`, cwd | also imports `~/.claude/settings.json` hooks → dedupe required [verified: note 03 §3.6] |
| Gemini CLI / Antigravity CLI | 2 | `BeforeTool` matcher `run_shell_command` | undocumented (`decision: ask` in source) → off by default, opt-in after probe | `SessionStart`/`SessionEnd` (best effort) | env `GEMINI_CLI=1`, `GEMINI_SESSION_ID` (hook only) | allow path must print `{}`; stray stdout is shown to the user [verified: note 03 §4.5] |
| Copilot CLI | v1.1 | `preToolUse` matcher `bash\|powershell` | yes (autopilot → deny) | yes | env `COPILOT_CLI=1` | hook error = deny, so the hook must never crash [verified: note 03 §5.5] |

### 3.4 Platform constraints restated for the UX

macOS 14+; Swift 6.1, SwiftPM, CLT only on the dev machine; `.xcstrings` is unusable on this toolchain, `.lproj/Localizable.strings` is [verified: note 04 §6.2]; no `Settings` scene / `openSettings` (use a `Window` scene + activation-policy flip, note 04 §5.4); avoid `.sheet`/`.alert` inside the menu bar extra on 14.0 (use windows, note 04 §5.3); git comes from CLT (`/usr/bin/git` shim; detect before exec, never trigger the install dialog from a hook, note 04 §9); no Full Disk Access; folders under `~/Desktop`, `~/Documents`, `~/Downloads` may prompt per folder on first access, and picking them in an Open panel implies consent [verified doc / FSEvents behaviour unverified: note 04 §3.2].

---

## 4. System model as the UX needs it

```
                    ┌────────────────────────────┐
  agent process ──► │ airbag (hook/CLI binary)   │ ── stdin JSON ──► rules (µs) ──► snapshot (ms, capped) ──► registry row
  (hooks)           │ works with the app closed  │ ── stdout JSON / exit 2 ──► agent                        │
                    └────────────┬───────────────┘                                                          │
                                 │ optional Unix socket ping (≤ 50 ms)                                      ▼
                    ┌────────────▼───────────────┐      ┌───────────────────────┐      ┌───────────────────────────┐
                    │ Airbag.app (menu bar)      │ ◄──► │ registry.sqlite (WAL) │ ◄──► │ stores/<project-id>/ (git) │
                    │ FSEvents · radar · views   │      └───────────────────────┘      └───────────────────────────┘
                    └────────────────────────────┘
```

Consequences for the UX:

- With the app quit, hooks still snapshot before commands, still block, still register sessions; the icon is simply absent. On next launch the app reads the registry and the Timeline shows what happened ("while Airbag was closed" group marker) [decision].
- FSEvents snapshots, orphan detection and the radar need the app running; Settings › General explains this next to "Launch at login".
- A protected project is keyed by the canonical path of its git common dir when it is a repository (worktrees attach to it) or by the folder itself otherwise [verified: note 06 §12]. The UI shows the project name (folder name), and worktrees as children.
- Snapshot identity is a ULID ref; the UI never shows SHAs except in the diff viewer's copyable details.
- Dedupe: if the tree is unchanged, no snapshot is stored, but the *event* ("Before `npm test`") is still recorded with "no file changes" so the Timeline reads as a log of what ran [decision; note 06 §5].

---

## 5. First-run onboarding (< 60 s)

### 5.1 Flow and time budget

```
Launch ─► 1 Agents (≈10 s) ─► 2 Hooks (≈15 s, one click + preview) ─► 3 Projects (≈20 s) ─► 4 Done (≈5 s)
                                                                              │
                                                                              └─ background: first snapshot per project (not on the critical path)
```

Rules: one window (`Window` scene, 720×520 pt, not resizable below), no popover; the window is the only onboarding surface; every step has a primary button and a "Skip for now"; nothing is written to any file before the click in step 2; the app is already in the menu bar during onboarding with the idle icon so the user sees where it lives. Onboarding never asks for notification permission, login item or folder access; those are requested in context later (§8; HIG: request authorization "in a context that helps people understand why", [verified: Apple, Asking permission to use notifications, accessed 2026-10-17]).

Re-entry: Settings › Agents & Hooks › "Run setup again" replays steps 1–3 with current state.

### 5.2 Step 0 — Launch

- First launch from Homebrew/Finder: no Gatekeeper dialog because the app is notarized and stapled [verified: note 04 §6.4–6.5]. Language = system language (`ru` picked automatically on this Mac, [verified: note 04 §6.2]).
- Window title `onboarding.window.title` ("Welcome to Airbag"). Header: `onboarding.welcome.title` + `onboarding.welcome.body` (two sentences: what it does, that nothing is sent anywhere). Footer link `onboarding.privacy.link` opens §13 text in a sheet-free window.
- Primary: `common.continue`. Secondary: `onboarding.skip_all` (skips to a Done screen with "Set up later from the menu bar").

### 5.3 Step 1 — Detect installed agents

Detection is read-only, finishes in < 1 s, and shows a row per agent with a status pill. Rules [verified sources in brackets]:

| Agent | Detected when | Version source | Unsupported / blocked when |
|---|---|---|---|
| Claude Code | any of: `~/.claude/` exists with `settings.json` or `projects/`; `~/.claude.json` exists; a running process whose exe path ends in `/claude.app/Contents/MacOS/claude` or basename `claude`; `/Applications/Claude.app` present | `~/.claude/sessions/*.json` `version` field when a session is live; else "installed" | managed settings present (`/Library/Application Support/ClaudeCode/managed-settings.json`) with `allowManagedHooksOnly` or `disableAllHooks` [likely path, note 01 §6.1] |
| Codex | `~/.codex/config.toml` or `~/.codex/hooks.json` or `~/.codex/sessions/`; `codex` on PATH or `/Applications/Codex.app` / `ChatGPT.app` with bundle id `com.openai.codex` | `codex --version` (and the app-bundled CLI when found) | version < 0.124.0 (hooks unstable before) [verified: note 02 §2.8]; `[features] hooks = false`; `allow_managed_hooks_only` in any `requirements.toml` |
| Cursor | `~/.cursor/` exists; `/Applications/Cursor.app`; `~/.local/bin/agent` or `cursor-agent` | app `Info.plist`; CLI version dir name | none known; Claude-import on by default → dedupe note |
| Gemini CLI | `~/.gemini/settings.json` or `~/.gemini/projects.json`; `gemini` on PATH | `gemini --version` | `hooksConfig.enabled = false` |
| Copilot CLI | `~/.copilot/` exists | — | shown as "coming in 1.1", not selectable |

Row anatomy: agent icon (bundled monochrome glyphs, not vendor logos — trademark hygiene) · name · status pill (`agents.status.found` / `agents.status.not_found` / `agents.status.version_unsupported` / `agents.status.managed_only`) · checkbox "Protect" (default on when found). On this Mac the expected result is: Claude Code found (desktop app), Gemini CLI found (settings file), Codex and Cursor not found [verified locally 2026-10-17].

Empty result: all not found → `onboarding.agents.none` with a link to the supported list and `common.continue` still enabled (projects can be protected with FSEvents alone).

### 5.4 Step 2 — Install hooks (one click, with preview)

Layout: left, the list of agents selected in step 1 with a short line each ("Claude Code · `~/.claude/settings.json` · 5 hooks"); right, a preview pane with a segmented control "Summary | Exact change". Primary button `onboarding.hooks.install` ("Install hooks"). Nothing is written until it is clicked.

Summary pane, per agent (plain language, one line per hook):

- `hooks.explain.session` — "Tells Airbag when a session starts and ends (so ports can be attributed and sessions named)."
- `hooks.explain.pre` — "Runs before each shell command: evaluates the safety rules, then takes a snapshot of the project (≤ 3 s, otherwise skipped)."
- `hooks.explain.post` — "Runs after each shell command in the background: labels the snapshot with the result."
- `hooks.explain.stop` — "Marks the turn as finished."
- Plus the agent-specific facts: Claude Code — "applies to running sessions immediately; held back in folders you have not trusted" [verified: note 01 §6]; Codex — "Codex requires you to trust each new hook once: open Codex, type `/hooks`, select an Airbag entry, press `t` (or Settings › Hooks in the app). Airbag shows the trust state live." [verified: note 02 §2.7]; Cursor — "Cursor also reads Claude Code hooks; Airbag detects that route and answers only once." [verified: note 03 §3.6]; Gemini — "Confirmation prompts ('ask') are not available in Gemini CLI; Airbag blocks with an explanation instead." [verified: note 03 §4.5].

Exact-change pane: a read-only monospace diff (before → after) of the actual target file, generated from the same merge function that `apply()` will run, so what is shown is what is written. Target files [verified: notes 01–03]: `~/.claude/settings.json`; `~/.codex/hooks.json` (created if absent; never `config.toml` unless the user already keeps hooks there, in which case the TOML form is shown); `~/.cursor/hooks.json` (with `"version": 1`); `~/.gemini/settings.json` under `hooks`. Below the diff: `hooks.preview.backup` ("A copy of the current file is saved to `~/Library/Application Support/Airbag/backups/<file>.<timestamp>` before writing.") and `hooks.preview.uninstall_promise` ("Uninstall removes exactly these entries and nothing else. Settings › Agents & Hooks › Remove hooks, or `airbag hooks uninstall`.").

The hook command written is the absolute path to the bundled helper, exec form where the agent supports it (Claude Code `args`, Copilot `exec`), shell string elsewhere; identical across all users so Codex trust hashes match the documentation [decision; verified mechanics: notes 01 §6.1, 02 §10]. Timeouts: Claude Code pre 30 s, post 30 s, session 5 s, SessionEnd 1 s; Codex pre 30 s, post async 20 s, SessionEnd 2 s; Cursor pre 20 s `failClosed: false`; Gemini pre 20000 ms. Strict mode (`onFailure: block` / `failClosed: true`) is never written by onboarding; it is a Guard setting (§7.3).

After the click, inline progress per agent (≤ 2 s total):

1. Write (atomic temp + rename, mode preserved, 0600 for Claude's file) → `hooks.step.written`.
2. Self-test → `hooks.step.selftest`: Airbag spawns its own binary exactly as the agent would (same argv, same cwd semantics) with a synthetic `PreToolUse` payload for the agent's shape and the command `rm -rf /tmp/airbag-selftest-<rand>/..` targeting outside any project; expected: deny JSON (or exit 2) and no file written. A second synthetic `SessionStart` must produce a registry row that is deleted afterwards. Failure → row turns to `hooks.step.selftest_failed` with "Show details" (stdout/stderr) and the hook stays installed but Guard shows "degraded" (§11.5).
3. Live check (Claude Code only, optional, 5 s): if a live session exists, wait for `ConfigChange` evidence (the next hook event from that session) and show `hooks.step.live_ok`; otherwise `hooks.step.live_pending` ("Will apply to the next command"). [verified: hot reload, note 01 §6]
4. Codex: trust watcher starts reading `~/.codex/config.toml` `[hooks.state."…"]` every 2 s while onboarding is open; row shows `hooks.codex.untrusted` with the instruction until `trusted_hash` appears, then `hooks.codex.trusted` [verified: note 02 §2.7]. This does not block `common.continue`.

Conflict handling in this step is specified in §11.2.

### 5.5 Step 3 — Protected projects

Header `onboarding.projects.title` ("Which projects should Airbag protect?") and a one-line explanation `onboarding.projects.body` ("Airbag keeps snapshots of these folders in its own store under ~/Library. Your project's own .git is never read or changed.").

Auto-suggest list (sources read-only, deduplicated by canonical path, sorted by last seen, max 12 shown, "Show more"):

| Source | What is read | Verified |
|---|---|---|
| Claude Code | `~/.claude.json` → `projects` keys (19 on this Mac); `~/.claude/projects/<slug>/` mtimes (slug decoded back to a path by matching against `projects` keys and `~/.claude/sessions/*.json` `cwd`); live `sessions/*.json` `cwd` | [verified locally 2026-10-17] |
| Codex | first line (`session_meta.cwd`) of the newest `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (stream only the first line; handle `.jsonl.zst` by skipping) | [verified format: note 02 §5] |
| Cursor | `~/.cursor/projects/<project>/` names; `~/.cursor/chats/<workspace-hash>/` cannot be mapped to paths without the IDE → ignored | [likely: note 03 §3.7] |
| Gemini CLI | `~/.gemini/projects.json` `projects` map (path → name) | [verified locally] |

Filters applied before showing: drop `~` itself, `/`, `/tmp`, `/private/tmp/claude-*` scratchpads, `~/Library/Application Support/Claude/scratch-workspaces/*` (desktop scratch dirs), `ssh:*` entries, paths that no longer exist, paths inside another suggested project (shown nested under it instead) [verified: these exact entries exist in the local `~/.claude.json`]. Each suggestion row: folder icon · name · path (middle-truncated) · agent glyphs that used it · "last used 2 h ago" · size estimate (lazy, `getattrlistbulk`, SpaceGuard's method [verified: note 05 §2.3]) · checkbox (default on for the three most recent). A row with a git repo shows `projects.row.git` ("git repository"); a worktree shows `projects.row.worktree_of` ("worktree of qost").

Manual add: `projects.add` button → `NSOpenPanel` (folders only, multiple) — selecting a folder in the panel implies consent for Desktop/Documents/Downloads locations [verified doc, note 04 §3.2]. Drag-and-drop onto the list also works.

Guards with inline messages (no modal): folder is `~` or a volume root → `projects.guard.home` (refused); folder has > 100,000 files or > 2 GB after excludes → `projects.guard.large` ("Large folder: the first snapshot may take a few minutes. Protect anyway?") with "Protect" / "Skip" (takeback's size guard idea, numbers chosen for the 20k-files ≈ 7 s measurement scaled, [decision; note 06 §9]); folder inside an already protected project → `projects.guard.nested`; folder on a network or external volume → `projects.guard.volume` (allowed, warned: FSEvents persistence is per device UUID, note 04 §3.2).

The git requirement, explained once in this step as a small info box `projects.git_requirement`:

> "Airbag stores snapshots with git, using the git that comes with Apple's Command Line Tools. Your project does not need to be a git repository, and Airbag never touches a project's own .git folder." If `xcode-select -p` fails or `<dir>/usr/bin/git` is missing, the box turns into the error state §11.1 with a button that runs `xcode-select --install` explicitly (never implicitly) [verified: note 04 §9].

The `.env` decision is visible here as one checkbox, default on: `projects.include_env` ("Include .env and other secrets files in snapshots (kept only on this Mac, owner-only permissions)") [decision; note 05 §9.5, note 06 §12].

On `common.continue`: projects are registered immediately; the first snapshot of each starts in the background (serialised, lowest QoS); the Done screen shows progress.

### 5.6 Step 4 — Done

- `onboarding.done.title` ("You're protected") only when ≥ 1 project is registered and ≥ 1 hook self-test passed; otherwise `onboarding.done.partial_title` ("Airbag is running") with the list of what is missing and a button per item.
- Body lists three facts with live values: projects protected (with first-snapshot progress bars), hooks installed per agent (with Codex trust state), where to find Airbag (`onboarding.done.where`: "Airbag lives in the menu bar: [glyph]. Click it to see the timeline, the radar and the guard.").
- One optional toggle `settings.general.launch_at_login` (default off; turning it on calls `SMAppService.mainApp.register()`, handles `.requiresApproval` by opening Login Items [verified: note 04 §5.2]).
- Primary `onboarding.done.open_menu` opens the popover and closes the window.

### 5.7 Time check

Measured budget targets: detection < 1 s; preview generation < 200 ms; write + self-test ≤ 2 s per agent; suggestions < 1 s (first-line reads only); registration instant. A user who accepts defaults clicks four times.

---

## 6. Menu bar presence

### 6.1 Icon states

The menu bar renders template images in black and clear; the system recolours them, so state must be carried by shape, never by colour [verified: Apple HIG, The menu bar, accessed 2026-10-17: "Both interface icons and symbols use black and clear colors to define their shapes; the system can apply other colors…"]. Height budget 24 pt; glyph drawn at 18 pt, `NSImage.isTemplate = true`.

| State | When | Glyph (SF Symbol, availability verified in `name_availability.plist` on this Mac) | Badge | Tooltip (`menu.tooltip.*`) |
|---|---|---|---|---|
| idle | no protected project, or protection paused, or every hook missing and no FSEvents watch | `shield` (outline; macOS 10.15+) | none | "Airbag — nothing protected yet" / "paused until 14:05" |
| protected | ≥ 1 project watched (FSEvents live) and no attention item | `shield.fill` (10.15+) | none | "Airbag — 3 projects protected" |
| snapshotting | a snapshot is being written (hook or FSEvents) | `shield.fill` with a 600 ms opacity pulse (`symbolEffect(.pulse)` on 14+; static when Reduce Motion is on); never longer than the snapshot, min 300 ms so it is perceivable | none | "Airbag — taking a snapshot of qost" |
| blocked | ≥ 1 unseen blocked (or asked-and-denied) command | `exclamationmark.shield.fill` (10.15+) | dot | "Airbag — blocked `rm -rf ~/old` in qost" |
| orphan | ≥ 1 unseen orphan, no unseen block | `shield.fill` + dot | dot | "Airbag — 1 server left running by an ended session" |
| degraded (variant of idle/protected) | git missing, store disk full, hook self-test failing, hooks removed by someone else | `shield.slash` (10.15+) | none (the popover header shows the issue) | "Airbag — snapshots paused: git not found" |

Precedence when several apply: blocked > orphan > snapshotting > degraded > protected > idle. Candidates considered and rejected: `shield.checkered` (14.0+, reads as a finish flag), `lifepreserver` (11.0+, no state variants; kept as the app-icon motif, §17), `shield.lefthalf.filled` (12.0+, reads as "half protected"). All names above exist in the system catalogue on macOS 15.7.9 with the stated minimums [verified locally 2026-10-17 via `/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist`].

The badge is a 6 pt filled circle drawn into the template image at the bottom-right (no first-party badge API exists for status items; drawing it into the image keeps it monochrome and legible on both menu bar appearances) [likely; standard practice]. An optional setting `settings.general.show_count` (default off) appends a short text ("1") next to the glyph for users who want a count; off by default because menu bar width is scarce (report: Ice installs 58.6k/year).

### 6.2 Badge policy

- Set only by: a new blocked command (deny, or ask answered "deny" by the user) and a new orphan (incl. "session ended with servers"). Never by snapshots, asks still pending (the agent's own UI is showing the prompt), notices, or hook/session activity.
- Cleared when: the popover is opened (all attention items become "seen"), or the item is resolved (orphan stopped/kept, block allowed), whichever first. Opening the main window via keyboard also clears.
- Rate: one badge, not a counter; the count lives in the popover header. A new item after clearing re-badges.
- Degraded states never badge; they change the glyph and add a header line, because they are not events the user caused and should not nag.

### 6.3 Dropdown anatomy

HIG prefers a menu over a popover for extras and allows a popover when the functionality "is too complex for a menu" [verified: Apple HIG, The menu bar, accessed 2026-10-17]. Airbag's dropdown has live counts, inline actions and keyboard navigation, which a `.menu`-style extra cannot update while open (run loop blocked) [verified: note 04 §5.3]; therefore `.window` style (popover-like), 360 pt wide, max 560 pt tall, scrolls.

```
┌──────────────────────────────────────────────────────────┐
│ ◙ Airbag                                       ⚙  ⋯      │  header: app name, Settings, overflow menu
│ 3 projects protected · snapshot 4 s ago · 3 servers · 1 orphan │  summary line (one line, middle-truncates)
├──────────────────────────────────────────────────────────┤
│ NEEDS ATTENTION                                   (2)    │  section appears only when non-empty
│ ⛔ Blocked rm -rf ~/old-backups                          │
│    qost · Claude Code "План проекта" · 2 min ago         │
│    [Allow once ▾] [Show]                                 │
│ ⚠ Session ended — stop its 2 servers?                    │
│    qost · Codex · :3000 next-server, :5555 prisma studio │
│    [Stop 2] [Keep] [Show]                                │
├──────────────────────────────────────────────────────────┤
│ PROJECTS                                                 │
│ ● qost            2 live · snapshot 4 s ago · :3000 :3999│  ● = live session(s), ○ = idle, ◌ = paused
│ ○ alfacenter      snapshot 12 min ago                    │
│ ○ lamus           snapshot 3 h ago · ⚑ pinned 1          │
│   + Add project…                                         │
├──────────────────────────────────────────────────────────┤
│ [ Timeline ]  [ Radar ]  [ Guard ]                       │  opens the main window on that view
├──────────────────────────────────────────────────────────┤
│ Pause for 1 hour      Snapshot all now          Quit     │
└──────────────────────────────────────────────────────────┘
```

Behaviours:

- Clicking a project row opens the Timeline filtered to that project; ⌥-click reveals the folder in Finder; right-click menu: Snapshot now, Restore to pinned…, Pause this project, Reveal in Finder, Remove from Airbag.
- "Allow once ▾" offers Allow once / Allow for this session / Always allow in qost (Guard semantics, §7.3).
- "Stop 2" sends SIGTERM to both, shows progress inline, then either removes the row or turns it into "1 didn't stop — Force stop?" (§7.2).
- The overflow menu `⋯`: Open Airbag window, Run setup again, Report a problem (opens GitHub issues URL in the browser — the only outbound link in the app), About.
- Keyboard: popover takes focus on open (`NSApp.activate()` first, note 04 §5.3); ↑↓ move between rows, → expands actions, Return activates the primary action, Esc closes; ⌘1/⌘2/⌘3 open the views; ⌘, opens Settings.
- Pause: writes a `paused_until` row; hooks answer allow instantly (still logging the command), FSEvents streams stop; icon → idle with tooltip; auto-resume with a popover header line "Protection resumed".

### 6.4 Summary line grammar

Format: `{projects} · {snapshot} · {servers}[ · {orphans}]`, where orphans is omitted when zero, servers is omitted when zero and no orphan, and the snapshot segment is omitted when there are no projects. Pluralised per language (`.stringsdict`): EN "1 project protected / 3 projects protected"; RU «1 проект под защитой / 2 проекта под защитой / 5 проектов под защитой». Snapshot age uses `RelativeDateTimeFormatter` with `.abbreviated` units ("4 s ago" / «4 с назад»), falling back to `summary.snapshot.none` («снимков пока нет») and `summary.snapshot.inprogress` ("snapshot in progress…"). Degraded conditions prepend a line above the summary (e.g. `error.git_missing.short`). Full key list in §10.3.

---

## 7. Main views

Window model: one main window ("Airbag", 980×640 pt default, remembers size) with a sidebar-less top segmented control Timeline | Radar | Guard (⌘1–3) and a persistent project filter popup at the right; Settings is a separate window (⌘,). The app flips to `.regular` activation policy while a window is open and back to `.accessory` when the last closes, so the window appears in front and the Dock stays clean [verified pattern: note 04 §5.4]. Text uses system styles (body 13 pt default, minimum 11 pt in dense tables, never below 10 pt; Apple's macOS minimum) [verified: Apple HIG Accessibility table, accessed 2026-10-17].

### 7.1 Timeline

Purpose: answer "what did the agent do to my files, and how do I get back".

Structure: a vertical list grouped **project → session → event**, newest first; groups collapse; the project filter popup narrows to one project; a session header shows agent glyph, session name (from `~/.claude/sessions/<pid>.json` `name`, `custom-title`, hook `session_title`, Codex thread id prefix, Cursor `conversation_id` prefix [verified: note 01 §11.2]), surface (desktop / terminal / `-p`), worktree name when not the main checkout, state (live ● / ended ○ with end time), and counts (events, files changed, blocked). FSEvents-only snapshots sit under a pseudo-session `timeline.session.unattributed` ("File changes outside agent sessions") so manual edits are not blamed on an agent.

Event card (collapsed row, 2 lines; expands inline):

```
┌ 14:02:11  Before `rm -rf src/legacy`                      12 files · 3.1 MB   ⚑ │
│           Claude Code · "План проекта" · qost/worktree bright-fox · tool toolu_01A…  │
│  ▸ D src/legacy/index.ts   D src/legacy/util.ts  …  (+10)                           │
│  [Restore folder src/legacy…] [Restore project to here…] [Compare with previous ▾]   │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

Event kinds and titles (`timeline.event.*`): pre-command "Before `{cmd}`"; post-command "After `{cmd}`" (shown only when it produced changes, otherwise folded into the pre-command card as the "changed by this command" list — the before/after pair is what tells the user exactly what the command touched [decision; note 05 §5.1]); fsevents "File changes"; manual "Manual snapshot"; pre-restore "Before restore" / post-restore "After restore"; project-added "Project added"; session markers "Session started" / "Session ended"; guard markers "Blocked `{cmd}`" / "Asked about `{cmd}` — allowed/denied" (link to Guard); "no file changes" rows for commands that changed nothing (dimmed, collapsible via filter "Hide unchanged").

Command text is shown monospace, single line, middle-truncated to 80 chars, full text on expand; secrets redacted at capture time (`*_PASSWORD=`, `*_TOKEN=`, `*_API_KEY=`, URL userinfo) [decision; agentundo precedent, note 05 §2.1].

Changed-file list: status letter + label (A added, M modified, D deleted, R renamed with old → new, T type changed, "skipped" for files above the size cap with the size, from `diff-tree -r -z --raw -M` [verified: note 06 §6]); monospace path relative to the project; click opens the diff viewer; ⌥-click reveals in Finder; right-click: Restore this file, Copy path, Open in editor.

Diff viewer (right pane or sheet-free window): unified diff from `git diff A B -- path` for text; "Binary file · 1.2 MB → 0 B" for binaries; images show before/after thumbnails (PNG/JPEG/GIF/HEIC via NSImage); > 1 MB diffs truncate with "Show full diff" and "Save patch…"; monospace, line numbers, light syntax-free colouring (added/removed background tints that also differ in a leading +/- glyph for colour-independence). Header shows both snapshot times and a "Restore this version" button.

Restore (the core interaction):

1. Scopes: file (from the file row), folder (from a card for a path prefix or from a folder row), project (from the card's "Restore project to here…"). All three open the same confirmation **window** (not a sheet; 14.0 bug, note 04 §5.3): `restore.title` ("Restore {scope} to {time}?").
2. The window shows the plan computed with `diff-tree --raw` between a fresh pre-restore snapshot and the target [verified: note 06 §13]: N files will be written, M removed (only paths tracked in the pre-restore snapshot and absent in the target), K unchanged, plus a list of "not covered" files (excluded dirs, size-capped, empty dirs) that will be left as they are, and a hard stop if any target blob maps onto a directory on disk (`restore.conflict.dir_over_file`, the one data-loss path, note 06 §7).
3. Explicit sentence always present: `restore.note.snapshot_first` ("Airbag takes a snapshot of the current state first. You can undo this restore from the Timeline."). If a live session is attached to this project: `restore.note.live_session` ("{agent} session “{name}” is still running here. The agent may overwrite restored files; pause it first if you can.").
4. Buttons: `restore.action.restore` (default, Return) and `common.cancel` (Esc). Progress inline; on completion the Timeline gets a "After restore" card at the top and a toast-like header line in the popover `restore.done` ("Restored 12 files in qost · Undo").
5. Mechanics: file/folder → `git restore --source=<sha> --worktree -- <paths>`; project → `restore --staged --worktree -- .` after the pre-restore snapshot; then stat refresh; verify written blobs by re-hashing changed paths and show `restore.verify_failed` with the list if any mismatch [verified mechanics: note 06 §7, §13; verification step is a decision].

Pin "last known good" (manual, v1): ⚑ on any card toggles `pinned`; pinned snapshots are exempt from retention and listed in the project row of the popover ("⚑ pinned 1"); "Restore to pinned…" in the project context menu restores the newest pinned. Automatic pinning after a successful build/test command is v1.1 (§16).

Search and filter: ⌘F search field over command text, file paths, session names; filter chips: project (popup), agent, event kind, "has file changes", pinned, blocked, date range (Today / 7 days / All); results keep grouping. Keyboard: ↑↓ rows, → expand, ⌘R restore focused scope (opens the confirmation), ⌘P pin, Space quick-look the diff of the focused file.

Density: a project with 5 sessions × 200 commands/day must scroll smoothly; the list is virtualised (`List` with identifiable rows and lazy diff loading), diffs load on expand, counts come from the registry, not from git [verified cost model: note 06 §14.10].

### 7.2 Radar

Purpose: "what is listening, who started it, is it an orphan, stop it".

Table (sortable, resizable, columns can be hidden; default order):

| Column | Content | Source |
|---|---|---|
| Port | `:3000`, bind scope glyph (local `127.0.0.1` / all interfaces `0.0.0.0`/`::`), family as detail; dual-stack sockets grouped per `(pid, port)` | `PROC_PIDFDSOCKETINFO` [verified: note 04 §1.3] |
| Process | name · pid; expand to show the process tree (`npm run dev` → `node` → `next-server`) | `proc_pidpath`, `KERN_PROC_ALL` |
| Project / worktree | project name · worktree name (or "main") · branch when cheap | cwd under a protected root; `.claude/worktrees/*`, `~/.codex/worktrees/<4hex>/<repo>`, `~/.cursor/worktrees/<repo>/*` [verified: notes 01 §8, 02 §6, 03 §3.9] |
| Agent · session | agent glyph · session name · live ● / ended ○ "12 min ago" | registry join via env `CLAUDE_CODE_SESSION_ID` / `CODEX_THREAD_ID` / `CURSOR_AGENT` / `GEMINI_CLI`, ancestry, hook-recorded commands [verified: note 01 §13.6, note 02 §11.5] |
| RAM | `phys_footprint` (Activity Monitor's number) | `proc_pid_rusage` [verified: note 04 §1.1] |
| CPU | % over the last poll window | `PROC_PIDTASKINFO` deltas |
| Uptime | since `pbi_start_tvsec` | |
| Status | live / orphan / unknown / system | §7.2 rules |

Attribution confidence is shown, not hidden: a tooltip on the Agent cell says how the link was made ("environment of the process names session 65cf…", "started by a command recorded at 14:02 in this session", "working directory inside qost; agent unknown"). When only the cwd matches, the Agent cell reads `radar.agent.unknown` ("unknown"), never a guess.

Status rules [decision, grounded in note 01 §13.6, note 02 §11.5]:

- live: attributed session is alive (agent PID alive, Claude Code session file present and `procStart` matches).
- orphan: attributed session has ended (SessionEnd received, or agent PID dead, or session file gone) **or** the process is reparented to launchd (ppid 1) and carries an agent env marker but no live agent ancestor exists. An orphan keeps its last-known session name and agent.
- unknown: listening, same uid, cwd inside a protected project, no agent evidence (e.g. a server the user started by hand). Shown, never badged.
- system: not inside any protected project and not agent-attributed (ControlCenter :5000/:7000, limactl :53, ssh forwards). Hidden by default; toggle `radar.filter.show_all`.

Actions (row buttons and context menu):

- `radar.action.stop` ("Stop"): re-validate `(pid, start)`; if the owning shell is gone, signal the process group (`kill(-pgid, SIGTERM)`) so wrappers and children go together; if the session is alive, signal the pid and its descendants only, never the agent's shell group [verified: note 04 §2, §10]. Poll 100 ms up to 5 s. Outcome: row disappears, or `radar.stop.failed` ("Didn't stop after 5 s") with the Force stop button now enabled.
- `radar.action.force_stop` ("Force stop"): SIGKILL, separate explicit click, enabled only after a Stop attempt or via ⌥ on the Stop button; the row shows `radar.force.warning` ("Ends the process immediately; unsaved state in it is lost.") before the click (inline text, not a modal).
- `radar.action.reveal` ("Reveal"): reveals the process cwd (or the project) in Finder; menu also offers Open `http://localhost:{port}`, Copy pid, Show session in Timeline, Open project in Terminal / editor (`vscode://file/…`, `cursor://file/…`), Activate the terminal app that hosts the session (`NSRunningApplication.activate` after `yieldActivation`, note 04 §5.5).
- Multi-select Stop applies the same protocol per row.

"Session ended — stop its 2 servers?" behaviour [decision]:

1. Trigger: a session transitions live → ended and ≥ 1 listening process is attributed to it with confidence ≥ "env or recorded command" (cwd-only matches do not trigger).
2. Surface: an attention row in the popover with Stop N / Keep / Show, a dot badge, and — only if notifications are authorised (§8) — one system notification with actions "Stop" and "Keep" (actionable; HIG: "Prefer nondestructive actions… If you must provide a destructive action, make sure people have enough context", so the body names the ports and processes).
3. Never auto-stops. "Keep" marks those processes as kept: they stay listed as orphan, no badge, no repeat prompt (HIG: "Avoid sending multiple notifications for the same thing").
4. If the same session is resumed (`SessionStart` with `source: resume` and the same cwd, or a Codex thread reattaches), kept/orphan processes re-attach and the row disappears.
5. Per-project setting `settings.projects.on_session_end`: Ask (default) / Don't ask (list silently). Auto-stop is not offered in v1 (the agent shell cannot know user intent; neither can Airbag).

Polling: libproc full scan every 5 s when the popover/window is closed and no session is live, 2 s when a session is live or the Radar is visible, plus an immediate rescan on every hook event; rows diff in memory and the SwiftUI model updates only on change (PortKiller's 2 GB idle regression is the cautionary tale) [verified cost: note 04 §1.4; pitfall: note 05 §6].

Port conflict: when two live rows share a port number on overlapping bind scopes, both get a `radar.conflict` label ("also claimed by …"); no action beyond visibility in v1.

### 7.3 Guard

Purpose: "what did Airbag block or ask about, why, and let me relax or tighten it".

Layout: top segmented control Log | Rules; project filter applies.

Log table: time · agent · session · project · command (monospace, expand) · rule id (monospace, click → Rules row) · decision pill (`guard.decision.blocked`, `guard.decision.asked_allowed`, `guard.decision.asked_denied`, `guard.decision.noticed`, `guard.decision.allowed_token`, `guard.decision.allowed_rule_off`) · snapshot link ("snapshot 01J…" → Timeline) · actions.

Actions per blocked/asked row:

- `guard.allow.once`: creates an allowance `{project, normalized command hash, expires in 10 min, single use}`; the row shows "Allowed once — re-run the same command within 10 min". The hook consumes it on the next identical command (normalisation: trimmed, whitespace-collapsed, env prefix `VAR=x` stripped).
- `guard.allow.session`: `{session_id, rule id}` until the session ends.
- `guard.allow.project`: `{project, rule id}` persistent; appears as an override in Rules with a Remove button.
- `guard.explain`: opens a popover-free detail panel with the full command, the matched sub-command after unwrapping (`bash -c`, `sh -c`, `git -C`, `xargs`, `find -exec`, `&&`/`;`/`|` chains), the rule text, the agent-facing message exactly as delivered, and the snapshot taken.

Rules (v1 ships 11 rule IDs; each row: ID · description · targets · tier popup · per-project overrides · test corpus count) [decision; sources: brief list, cc-safety-net IDs, agentundo alert list, notes 01 §13.3, 05 §9.3]:

| Rule ID | Matches (after unwrapping) | Default tier | Lowest allowed tier | Agent-facing alternative |
|---|---|---|---|---|
| `rm.recursive-outside-project` | `rm -r`/`-rf`/`-fr` (and `find … -delete`, `-exec rm`) with any target resolving outside every protected project and outside `$TMPDIR`/`/tmp` | block | ask | move to Trash (`mv … ~/.Trash/`), or ask the user to delete manually |
| `rm.recursive-home-or-root` | recursive rm whose target is `~`, `/`, a volume root, a top-level home folder (`~/Documents`…), or a variable/`$(pwd)`-derived path | block | block | none; ask the user |
| `rm.recursive-project-root` | recursive rm of a protected project root or its `.git` | block | ask | delete specific subfolders instead |
| `git.reset-hard` | `git reset --hard` (any ref) | ask | notice | `git stash` / `git stash push -u`, or a new branch |
| `git.clean-force` | `git clean -f` with `-d`/`-x`/`-X` | ask | notice | `git clean -n` first; remove named paths |
| `git.checkout-discard` | `git checkout -- .`/`<path>`, `git restore .`/`--worktree <paths>` | ask | notice | `git stash` |
| `git.push-force` | `git push --force`/`-f` without `--force-with-lease`; `git push --delete`/`--mirror` | ask | notice | `--force-with-lease`; ask the user |
| `db.drop-database` | `DROP DATABASE`/`DROP SCHEMA` in `psql`/`mysql`/`sqlite3`/`mongosh` invocations or heredocs; `dropDatabase()`; `FLUSHALL` | block | ask | export first; ask the user |
| `db.prisma-migrate-reset` | `prisma migrate reset` (any flags; `--force` or `--skip-seed` noted) and equivalents `rails db:reset`, `artisan migrate:fresh`, `manage.py flush` | block | ask | `prisma migrate dev` / a new migration; ask the user |
| `disk.device-write` | `dd of=/dev/…`, `mkfs`, `diskutil erase*`, `>`/`>>` to `/dev/disk*` | block | block | none |
| `db.remote-target` | connection strings / `-h host` / `PGHOST=` to non-local hosts in commands that modify data | notice | off | reminder: snapshots cannot undo remote changes |

Tiers: block (deny), ask (prompt where the agent supports it, else the per-agent fallback), notice (allowed, logged, timeline marker, no badge), off. Per-agent ask fallback popup in Settings › Guard: "Block with explanation and allow token" (default) or "Allow and snapshot" — applies to Codex always, to Gemini until `decision: ask` is verified, to Copilot autopilot [verified: notes 02 §11.4, 03 §8.6].

Unparseable commands (tokenizer failure, CR/VT/FF, `-c` option clusters): snapshot and allow for in-project rules; for `rm.recursive-outside-project` only, "understand or block" is a toggle `settings.guard.unparseable_block` (default off; aws-safebox precedent) [decision; note 05 §6].

Strict mode toggle `settings.guard.strict` ("If Airbag's hook crashes or times out, block the command (Claude Code 2.1.295+, Cursor)"; default off). Writes `"onFailure": "block"` on the Claude Code PreToolUse handler and `failClosed: true` on Cursor's entry; explains that Codex and Gemini have no equivalent [verified: notes 01 §4.1, 03 §3.5, 02 §2.5]. Because the breaker evaluates first and the snapshot is capped at 3 s, strict mode never blocks because of a slow snapshot.

"Test the breaker" button runs the self-test (§5.4) for every installed agent and shows the result inline.

### 7.4 Settings

Separate window, toolbar tabs (SF Symbols in brackets), each tab fits 640×480 without scrolling:

1. General [`gearshape`]: Launch at login (SMAppService; status text for `.requiresApproval` with "Open Login Items"); Language: System / English / Русский (applies after relaunch; button "Relaunch now"); Show count next to the menu bar icon (off); Pause durations; Open Airbag window at launch (off).
2. Agents & Hooks [`terminal`]: table agent · config file · state (`hooks.state.healthy` with "last event 2 min ago", `not_installed`, `drifted`, `untrusted` (Codex; with the instruction), `duplicate_route` (Cursor via Claude import; "Airbag answers once"), `managed_only`, `invalid_file`, `binary_moved`) · buttons Install / Repair / Remove per row; "Run setup again"; "Show hook files" (reveals each in Finder); "Strict mode" lives in Guard, cross-linked.
3. Projects [`folder`]: list with name, path, worktrees count, store size (packed + loose from `count-objects -v`, refreshed ≤ 1/min), last snapshot, pinned count, pause toggle, "On session end: Ask / Don't ask", Include .env toggle (per project override of the global), Excludes editor (gitignore syntax, defaults `node_modules/ dist/ .next/ build/ .venv/ target/ .DS_Store`; first 8 go to FSEvents stream exclusions, the rest to the callback filter [verified: note 04 §3.1]), size cap per file (50 MiB default), Remove (keeps or deletes the store — two buttons), Add project.
4. Snapshots [`clock.arrow.circlepath`]: Retention age (1 / 3 / 7 (default) / 14 / 30 days), Store budget total (2 / 5 (default) / 10 / 20 GiB, packed), "Always keep the newest 20 snapshots per project" (fixed, explained), "Pinned snapshots are never removed"; FSEvents quiet period (1 / 2 (default) / 5 s); Hook snapshot cap (3 s default, 1–10); "Pack stores now"; store location (read-only path, Reveal); "Snapshots taken while Airbag is closed" explanation.
5. Guard [`exclamationmark.shield`]: rules table (§7.3), per-agent ask fallback, strict mode, unparseable-outside-project toggle, "Test the breaker", "Export log…".
6. Notifications [`bell.badge`]: status (not asked / allowed / denied with "Open System Settings"), toggles per event class (§8), "Request permission" button (only way Airbag asks outside of a first event).
7. Keep awake [`moon.zzz`]: placeholder, controls disabled, text `settings.keepawake.placeholder` ("Coming in 1.1: Airbag will keep your Mac awake while at least one agent session is running, on AC power only. Lid-closed operation is not planned.") [verified constraints: note 04 §4].
8. About [`info.circle`]: version, build, git commit, MIT licence, Privacy statement (§13), "Check for updates: `brew upgrade --cask airbag`", link to the repository, "Uninstall Airbag…" (removes hooks, asks whether to delete stores and registry, then quits; the cask's `zap` does the rest) [verified: note 04 §6.6].

