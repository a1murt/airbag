# 02 — OpenAI Codex (CLI + desktop app): hooks, session layout, worktrees, sandbox, process attribution

Status: research note for Airbag. Written 2026-10-17. Codex is **not installed on the dev machine** (no `~/.codex/config.toml`, no `codex` on PATH, no `/Applications/Codex.app`), so every claim below comes from primary sources fetched 2026-10-16/17 (official docs at `learn.chatgpt.com`, the `openai/codex` repository `main` branch, GitHub API, Homebrew API) or from third-party source code. Tags: `[verified]` = read in the primary source today; `[likely]` = secondary source or strong inference from source code; `[unverified]` = not confirmed.

Latest versions at time of writing: Codex CLI `rust-v0.163.0` (published 2026-10-15), `0.164.0-alpha.2` (2026-10-16); Codex desktop app `26.1007` (changelog entry 2026-10-08). `[verified]`

## TL;DR

1. Hooks are stable since **0.124.0 (2026-04-23)**: release notes say "Hooks are now stable, can be configured inline in `config.toml` and managed `requirements.toml`" (#19012 "Mark codex_hooks stable"); the changelog's 2026-05-14 entry announces "Hooks general availability". Enabled by default (`[features] hooks = false` turns them off; `codex_hooks` is a deprecated alias). `[verified]`
2. Config: `~/.codex/hooks.json` (user, loads regardless of project trust) or `[hooks]` tables in `~/.codex/config.toml`; `<repo>/.codex/hooks.json|config.toml` only for trusted projects. Same nested shape as Claude Code: event → matcher groups → handlers `{type:"command", command, timeout, async, statusMessage}`. `[verified]`
3. 12 events: `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PreCompact`, `PostCompact`, `UserPromptSubmit`, `SubagentStart`, `SubagentStop`, `Stop`, `Interrupt`, `SessionStart`, `SessionEnd`. Shell commands match as `Bash`; `tool_input.command` is a string. `[verified]`
4. Blocking: `PreToolUse` deny via `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…"}}`, or legacy `{"decision":"block","reason":"…"}`, or **exit 2 + reason on stderr**. Default timeout 600 s. **Fail-open**: timeout/crash/malformed output = hook "failed", tool runs. `[verified]`
5. Every non-managed hook must be **trusted** by the user (`/hooks` in the TUI, press `t`; Settings → Hooks in the app). Trust is a `trusted_hash` in `~/.codex/config.toml` under `[hooks.state."<hooks.json path>:<event>:<group>:<handler>"]`, keyed by position + a hash of the normalized handler; Airbag cannot pre-trust itself through documented means and must keep its command string byte-stable across upgrades. `[verified]`
6. Session identity in hook stdin: `session_id` (thread UUID), `turn_id`, `tool_use_id`, `transcript_path` (rollout file), `cwd`, `model`, `permission_mode`. No env var is set for hook commands; hooks inherit the Codex process environment and run as a direct child of the `codex` (CLI) or `codex app-server` (app) process in a new POSIX session, so the Codex PID is the hook shell's parent. `[verified]`
7. Shell-tool children (dev servers!) carry `CODEX_THREAD_ID`, `CODEX_SESSION_ID`, `CODEX_TOOL_CALL_ID`, `CODEX_VERSION`, plus `CODEX_SANDBOX=seatbelt` / `CODEX_SANDBOX_NETWORK_DISABLED=1` when sandboxed — Airbag's radar can attribute Codex-spawned listeners by reading process environments (no hook needed). `[verified from source]`
8. Rollouts: `~/.codex/sessions/YYYY/MM/DD/rollout-YYYY-MM-DDTHH-MM-SS-<thread_uuid>.jsonl` (cold files compressed to `.jsonl.zst`; archived → `~/.codex/archived_sessions/`). Reported sizes: 39.4 GiB / 938 sessions, single files 0.7–10.7 GB. `[verified]`
9. Worktrees: `$CODEX_HOME/worktrees/<4-hex>/<repo-name>`, detached HEAD, owner thread recorded in `<git-dir>/codex-thread.json`; app keeps the last 15 and auto-deletes on archive/over-limit (snapshot first); CLI never auto-cleans. "Worktree by default since 2026-09-22" is **not confirmed** by the changelog. `[verified]`
10. Legacy `notify` (array of argv in `config.toml`) still exists and only fires `agent-turn-complete`; it's redundant with the `Stop` hook. `/undo` remains absent (issue #9203 open, 536 reactions, maintainer: needs redesign). `[verified]`

---

## 1. Surfaces and versions

| Surface | Identity | Version seen | Notes |
|---|---|---|---|
| Codex CLI (Rust, `codex-rs`) | `codex` binary; npm `@openai/codex`; Homebrew cask **`codex`** (installs `bin/codex`, zap removes `~/.codex`) | 0.163.0 (2026-10-15) | Homebrew cask `codex` is rank **#1** of all casks in the last 30 days: **144,448** installs (7.33 %). This is the CLI, not the app. `[verified]` |
| Codex desktop app (Electron) | bundle id `com.openai.codex`; Homebrew cask **`codex-app`** (`Codex.app`, requires macOS ≥ 12) | cask 26.623.141536 (stale); changelog app **26.1007** (2026-10-08) | Only **1,088** brew installs / 30 d — nearly everyone installs the DMG and auto-updates. Since ~Sep 2026 the app can be installed as `/Applications/ChatGPT.app` with the same bundle id (issue #48214) and the docs now call it "ChatGPT desktop app → Codex". `[verified]` |
| IDE extension | runs the bundled CLI as `codex app-server` | — | Not covered further. |
| `codex exec` | non-interactive CLI | — | Hooks **do** fire: the exec crate's own integration test `exec_hook_trust_bypass_runs_session_start_hook` (`codex-rs/exec/tests/suite/hooks.rs`) runs a `SessionStart` hook under `codex exec --dangerously-bypass-hook-trust` `[verified from source]`; with persisted trust and no bypass flag, two non-maintainer reports in #32491 (0.147.0 macOS; app-server `hooks/list` + `config/batchWrite` flow) say the hook ran `[likely]`. The maintainer comment in #54353 (2026-10-16) does **not** mention `codex exec` — an earlier draft of this note misattributed it. Untrusted hooks are skipped silently in `exec` (no stderr line, exit 0) per #32491. |

Market-report correction: the report's "cask `codex` 109k installs/30d" is the **CLI** cask, not the app. `[verified]`

## 2. Hooks

### 2.1 Where hooks live and how layers merge

Source: https://learn.chatgpt.com/docs/hooks (markdown twin `hooks.md`, accessed 2026-10-17) and `codex-rs/hooks/src/engine/discovery.rs`.

- Codex discovers hooks "next to active config layers" as either `hooks.json` or inline `[hooks]` tables in `config.toml`. The four practical locations: `~/.codex/hooks.json`, `~/.codex/config.toml`, `<repo>/.codex/hooks.json`, `<repo>/.codex/config.toml`. `[verified]`
- **All** matching hooks from all layers run; higher-precedence layers do not replace lower ones. If one layer has both `hooks.json` and `[hooks]`, both load and Codex warns. `[verified]`
- Project-local hooks load only when the project `.codex/` layer is trusted (`projects."<path>".trust_level = "trusted"`); user and system hooks load regardless. `[verified]`
- Plugins may bundle hooks (`hooks/hooks.json` in the plugin root or `"hooks": "./hooks/x.json"` in `.codex-plugin/plugin.json`); they get `PLUGIN_ROOT`, `PLUGIN_DATA`, `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA` env vars and still need trust. `[verified]`
- Enterprise: `requirements.toml` can set `allow_managed_hooks_only = true` (skips user/project/session/plugin hooks) or `[features] hooks = false`. Airbag must detect both and tell the user. `[verified]`
- `~/.codex/hooks.json` top level is strict: only `description` and `hooks` are allowed (`HooksFile` is `deny_unknown_fields`). Handlers are parsed as a tagged enum (`type = command | mcp_tool | prompt | agent`); `prompt`/`agent` are parsed but skipped. Do not add marker keys. `[verified from codex-rs/config/src/hook_config.rs]`

### 2.2 Config shape (official example, abbreviated)

```json
{
  "description": "Optional lifecycle hooks for this workspace.",
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [ { "type": "command",
                     "command": "/usr/bin/python3 \"$(git rev-parse --show-toplevel)/.codex/hooks/pre_tool_use_policy.py\"",
                     "statusMessage": "Checking Bash command" } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "python3 ~/.codex/hooks/session_end.py", "timeout": 3 } ] }
    ]
  }
}
```

Equivalent TOML in `config.toml`:

```toml
[[hooks.PreToolUse]]
matcher = "^Bash$"

[[hooks.PreToolUse.hooks]]
type = "command"
command = '/usr/bin/python3 "$(git rev-parse --show-toplevel)/.codex/hooks/pre_tool_use_policy.py"'
timeout = 30
statusMessage = "Checking Bash command"
```

Handler fields: `type`, `command`, `commandWindows`/`command_windows`, `timeout` (seconds; default **600**; `SessionEnd`/`Interrupt` default **1 s**, max **3 s**), `async` (default false), `statusMessage`, `additionalContextLimit` (default 2500 tokens). Commands run with the session `cwd` as working directory. `[verified]`

### 2.3 Events, matchers, tool coverage

| Event | `matcher` applies to | Values |
|---|---|---|
| `PreToolUse`, `PostToolUse`, `PermissionRequest` | tool name | `Bash` (shell + unified `exec_command`), `apply_patch` (aliases `Edit`, `Write`), MCP names `mcp__server__tool`, other local function tools (`update_plan`, `spawn_agent`→`Agent`) |
| `PreCompact`, `PostCompact` | trigger | `manual`, `auto` |
| `SessionStart` | source | `startup`, `resume`, `clear`, `compact`, `fork` |
| `SessionEnd` | reason | only `other` today |
| `SubagentStart`, `SubagentStop` | agent type | depends on subagent |
| `UserPromptSubmit`, `Stop`, `Interrupt` | ignored | — |

Matcher is a regex; `"*"`, `""` or omitted = match all. Hosted tools (`WebSearch`) never pass through hooks. `write_stdin` into an existing unified-exec session does **not** trigger `PreToolUse` again (the same coverage hole CC Safety Net documents: "input typed into an already-running interactive session is never inspected"). The docs explicitly say: "Treat tool hooks as a useful guardrail, not a complete enforcement boundary." `[verified]`

### 2.4 stdin contract

One JSON object on stdin per invocation. Common fields: `session_id` (string; subagent hooks carry the parent's), `transcript_path` (string|null), `cwd`, `hook_event_name`, `model`; turn-scoped events add `turn_id`; most add `permission_mode` ∈ `default | acceptEdits | plan | dontAsk | bypassPermissions`. In the current source `permission_mode` is `"bypassPermissions"` iff `approval_policy = never`, otherwise `"default"` (`codex-rs/core/src/hook_runtime.rs::hook_permission_mode`). `[verified]`

Generated schema `codex-rs/hooks/schema/generated/pre-tool-use.command.input.schema.json` (required fields): `cwd, hook_event_name="PreToolUse", model, permission_mode, session_id, tool_input (any), tool_name, tool_use_id, transcript_path, turn_id`; optional `agent_id`, `agent_type` (when running inside a subagent); `additionalProperties: false`. `[verified]`

Realistic `PreToolUse` payload for a shell command (field names verified; values illustrative):

```json
{
  "session_id": "0199a213-81c0-7800-8aa1-bbab2a035a53",
  "transcript_path": "/Users/me/.codex/sessions/2026/10/17/rollout-2026-10-17T09-12-33-0199a213-81c0-7800-8aa1-bbab2a035a53.jsonl",
  "cwd": "/Users/me/.codex/worktrees/3f9a/myrepo",
  "hook_event_name": "PreToolUse",
  "model": "gpt-6.1-sol",
  "permission_mode": "default",
  "turn_id": "7c1f0c1e-…",
  "tool_name": "Bash",
  "tool_use_id": "call_abc123",
  "tool_input": { "command": "git reset --hard HEAD~3" }
}
```

Other events add: `PostToolUse.tool_response`; `PermissionRequest.tool_input.description` (string|null, not guaranteed); `SessionStart.source`; `SessionEnd.reason`; `UserPromptSubmit.prompt`; `Stop.stop_hook_active`, `Stop.last_assistant_message`; `SubagentStop.agent_transcript_path`. `[verified]`

Session-id caveat: issue #54353 (2026-10-15) claimed hooks carry no session id; the maintainer replied (2026-10-16) that command hooks **do** receive `session_id` on stdin and that `SessionStart` "runs on the thread's first turn, not immediately on `thread/start`". Treat `SessionStart` as "first turn of a thread", not "thread created". `[verified]`

### 2.5 stdout / exit-code contract (blocking)

- Exit `0` with no output = success. `[verified]`
- `PreToolUse` deny (preferred form):
  ```json
  {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Destructive command blocked by hook."}}
  ```
  Legacy form `{"decision":"block","reason":"…"}` also accepted; **or** exit code `2` with the reason on stderr. A deny without a non-empty reason is rejected ("returned permissionDecision:deny without a non-empty permissionDecisionReason") and the tool runs. `[verified]`
- `PreToolUse` rewrite: `permissionDecision: "allow"` + `updatedInput: {"command": "…"}` (string required for Bash/apply_patch). `permissionDecision: "ask"`, `continue:false`, `stopReason`, `suppressOutput` are **unsupported** on `PreToolUse` → hook marked failed, tool continues. `[verified]`
- **Trap (verified in `codex-rs/hooks/src/engine/output_parser.rs::unsupported_pre_tool_use_hook_specific_output`):** `permissionDecision: "allow"` **without** `updatedInput` is also rejected ("PreToolUse hook returned unsupported permissionDecision:allow") and `updatedInput` without `permissionDecision: "allow"` is rejected too; both mark the hook Failed (tool still runs, and any `additionalContext` in that payload is dropped). Likewise `{"decision":"approve"}` is unsupported. To allow, print **nothing** (or only `additionalContext`/`systemMessage` without a permission decision) and exit 0. Exit 2 with an **empty** stderr is Failed, not a block. `[verified]`
- Async handlers (`"async": true`) never block: `parse_completed` only honours block/deny when `handler.can_apply_control_effects()`; a deny from an async hook is treated as a failed hook. `[verified from source]`
- `PermissionRequest`: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"…"}}}` or `behavior:"allow"`. Any deny wins; allow skips the prompt; no decision → normal prompt. Fires only when Codex would ask for approval (sandbox escalation, network, etc.). `[verified]`
- `PostToolUse`: `decision:"block"` + `reason` replaces the tool result with feedback (cannot undo); `continue:false` stops processing; exit 2 also works. `[verified]`
- `Stop`: `decision:"block"` + `reason` makes Codex continue with `reason` as a new prompt. `SessionEnd`, `Interrupt`: advisory only. `[verified]`
- `additionalContext` > ~2500 tokens is spilled to `<temp_dir>/hook_outputs/<session_id>/<uuid>.txt`. `[verified]`
- **Fail-open is explicit**: issue #41979 (open, 2026-09-01) asks for an opt-in fail-closed mode because "a timeout, spawn failure, crash/non-protocol exit, or malformed output is treated as a failed hook with `should_block=false`, so the tool is dispatched". Multiple matching command hooks launch concurrently; one cannot prevent another from starting. `[verified]`

### 2.6 How a command hook is executed (from `codex-rs/hooks/src/engine/command_runner.rs`, `codex-rs/utils/pty/src/posix_child.rs`)

- Launcher: `$SHELL -lc "<command>"` where `SHELL` is read from the Codex process environment (fallback `/bin/sh`); the shell program/args can be overridden by a config (`HooksConfig.shell_program/shell_args`; the config key is not documented — `[unverified]`). `[verified]`
- Spawned via `posix_spawn` with `POSIX_SPAWN_SETSID` (`ProcessMode::NewSession`), i.e. the hook shell starts its own session/process group, **directly from the Codex process** (CLI: the `codex` TUI process; app: `codex app-server`). Release 0.158.0: "Use native POSIX spawning for command hooks" (#47610). Hence `getppid()` in the hook shell = Codex PID; the hook binary's own parent is the shell, or Codex if the shell `exec`s the single command. `[verified from source]`
- Forward-looking caveat: `command_runner.rs` carries the comment "Needed only until command hooks move to the exec server, which owns process-tree cleanup", and `registry.rs` a TODO to move the env snapshot into `CommandHookRuntime::new`. If/when hooks are spawned by a separate exec-server process, `getppid()` from the hook will no longer be the Codex PID. Airbag's PID walk must therefore be a bounded ancestor scan matching on argv (`codex`, `app-server`, `exec`), not a fixed depth. `[verified comment; timing unknown]`
- Environment = `std::env::vars_os()` of the Codex process, captured once in `Hooks::new` when the session's hook registry is built (a snapshot; later env changes are not seen), minus `NON_INHERITABLE_ENV_VARS` (`CODEX_EXEC_SERVER_NOISE_AUTH_TOKEN`, `NODE_REPL_AUTH_TOKEN`, `CODEX_GUARDIAN_DECISIONS_API_KEY`, `OPENAI_FEDERATION_RULE_ID`, `OPENAI_IDENTITY_TOKEN_FILE`, `OPENAI_WORKLOAD_IDENTITY_CONTEXT`), plus plugin vars. **No `CODEX_THREAD_ID`/`CODEX_SESSION_ID` is injected for hooks** (those are injected for shell-tool children only). `[verified from source]`
- stdin is the JSON; stdout/stderr captured; on timeout the whole hook process group is killed (`kill_process_group`). Up to 8 `async` hooks per session run concurrently; async hooks cannot block. Hooks run **outside** the Seatbelt sandbox (they are not shell-tool calls). `[verified]`
- Windows note (irrelevant for macOS but explains bug reports): hooks run under `powershell -Command`, which turns exit 2 into exit 1, so exit-2 deny does not block on Windows (#48183, #54072). On macOS with zsh/bash `-lc` the exit code is preserved. `[verified]`

### 2.7 Trust model (critical for installers)

Sources: hooks doc; `codex-rs/hooks/src/engine/discovery.rs` (`hook_hash`, `hook_trust_status`), `codex-rs/hooks/src/lib.rs` (`hook_key`), `codex-rs/config/src/hook_config.rs` (`HookStateToml`); Adrafinil `CodexHookTrust.swift`; issue #32491 comments.

- "Before a non-managed hook can run, Codex requires you to review and trust the exact hook definition. Codex records trust against the hook's current hash, so new or changed hooks are marked for review and skipped until trusted." Managed hooks (system/MDM/cloud/`requirements.toml`) are trusted by policy. `[verified]`
- Persisted state key: `"<key_source>:<event_label>:<group_index>:<handler_index>"` where `key_source` is the absolute path of the `hooks.json`/`config.toml` that declared it (plugins: `<plugin_id>:<relative path>`), `event_label` is snake_case (`pre_tool_use`, `session_start`, `stop`…). Stored in `~/.codex/config.toml`:
  ```toml
  [hooks.state."/Users/me/.codex/hooks.json:pre_tool_use:0:0"]
  trusted_hash = "sha256:…"     # set by /hooks → t
  # enabled = false             # set by /hooks → disable
  ```
  Fields: `enabled`, `trusted_hash`, `trusted_content_hash` (plugins). The TOML header form follows directly from `HooksToml { #[serde(flatten)] events, state: BTreeMap<String, HookStateToml> }` living under `[hooks]` in `codex-rs/config/src/hook_config.rs`, and is echoed by an #32491 commenter who wrote such entries by hand. `[verified from source]`
- Hash = `version_for_toml(NormalizedHookIdentity{event_name, group{matcher, hooks:[normalized handler]}})`. Deterministic over event name, matcher and the normalized handler (command string, timeout, async, statusMessage, …). **Any change to the command string, timeout or matcher → status `Modified` → hook skipped until re-trusted.** Position in the array is part of the key, so inserting a group before Airbag's group also invalidates trust. `[verified]`
- Trust statuses exposed over app-server: `Managed | Untrusted | Trusted | Modified` (`codex-rs/app-server-protocol/src/protocol/v2/hook.rs`). `[verified]`
- Ways to trust: (a) TUI `/hooks` → select handler → `t` (`codex-rs/tui/src/bottom_pane/hooks_browser_view.rs`: `KeyCode::Char('t')` = "trust" on a handler page, "trust all" on the events page; untrusted handlers are labelled "New hook - review required", changed ones " · modified") `[verified from source]`; (b) desktop app Settings → Hooks (changelog 2026-05-08, app 26.506: "Added an in-app trust review flow for hooks and kept Hooks settings reachable even before hooks are fully configured") `[verified]`; (c) startup warning telling you to open `/hooks` when review is needed `[verified, hooks doc]`; (d) `--dangerously-bypass-hook-trust` per invocation (hooks doc; flag defined in `codex-rs/utils/cli/src/shared_options.rs`) `[verified]`; (e) programmatic: #32491 commenters (not maintainers) persisted trust via app-server `hooks/list` (returns `currentHash`) + `config/batchWrite` writing that hash under `hooks.state`, after which `codex exec` ran the hook (0.147.0 macOS and a later app-server flow) — `[likely]`. (e) is technically possible but bypasses the review UX Codex designed; see §10.
- Known gap: project-level hooks added to a newly opened project were silently skipped with no prompt (#35306, July 2026) — user-level `~/.codex/hooks.json` is the safer installation point. `[verified issue; current behavior unverified]`

### 2.8 History

- 0.124.0 (2026-04-23): hooks stable; inline `config.toml`/`requirements.toml`; hooks observe MCP tools, `apply_patch` edits, long-running Bash sessions (#18893, #18385, #18391, #18888, #19012). `[verified]`
- 2026-05-14 changelog: "Hooks general availability"; app 26.506: in-app trust review. 2026-05-21: plugins may include lifecycle hooks. `[verified]`
- Before 0.124: feature flag `[features] codex_hooks = true` (third-party blogs date `PreToolUse` to ~0.114); the flag name survives as a deprecated alias. `[likely]`
- 0.142.5 regression: `hooks.json` not discovered at all on macOS (#30835, July 2026) — Airbag should surface Codex version in diagnostics. `[verified issue]`
- 0.158.0 (Sep 2026): native POSIX spawn for hooks; 0.161.0: matchers compiled at discovery; 0.162.0: hooks browser polish. `[verified]`

## 3. Legacy `notify`

`codex-rs/hooks/src/legacy_notify.rs` and config reference: `notify` is a root-level array of argv in **user-level** `config.toml` (ignored in project `.codex/config.toml`). Codex appends one argument containing JSON and spawns it detached (stdin/stdout/stderr null) after each turn:

```json
{"type":"agent-turn-complete","thread-id":"b5f6c1c2-1111-2222-3333-444455556666","turn-id":"12345",
 "cwd":"/Users/example/project","client":"codex-tui",
 "input-messages":["Rename `foo` to `bar` and update the callsites."],
 "last-assistant-message":"Rename complete and verified `cargo build` succeeds."}
```

Only `agent-turn-complete` exists; `client` is `codex-tui` for the TUI, app-server clients report their own name. The source carries a TODO to remove it. For Airbag it is redundant with the `Stop` hook and lacks per-command granularity. `[verified]`

## 4. Session identity and finding the Codex process from a hook

- `session_id` in hooks = `ThreadId` (UUID; new ones look like UUIDv7, e.g. `0199a213-81c0-7800-8aa1-bbab2a035a53` in the `codex exec --json` docs). Subagents report the parent's `session_id` plus `agent_id`. `SessionMeta` distinguishes `session_id` (root thread) from `id` (this thread) and `parent_thread_id`. `[verified]`
- `transcript_path` = the rollout file (§5); null when `--ephemeral` or not yet created. `[verified/likely]`
- `cwd` for tool hooks = the thread's local working directory (for worktree threads, the worktree path). `[verified from hook_runtime.rs::tool_hook_cwd]`
- PID: walk `getppid()` upward until an executable whose basename starts with `codex` (CLI: `codex`, or Homebrew's real binary `codex-aarch64-apple-darwin` behind the symlink `[likely, Adrafinil]`) or whose path is inside `Codex.app`/`ChatGPT.app` (`…/Contents/Resources/codex app-server` or `…/Contents/Resources/codex-cli/bin/codex app-server`). Record both the Codex PID and its parent (Terminal/iTerm/VS Code/Electron main) to label the surface. `[verified structure, likely paths]`
- Environment of **shell-tool children** (not hooks), from `codex-rs/core/src/exec_env.rs` and `codex-rs/core/src/spawn.rs`: `CODEX_THREAD_ID` (always injected, "even when `include_only` is set"), `CODEX_SESSION_ID` (root session), `CODEX_TOOL_CALL_ID` (per call), `CODEX_VERSION`, `CODEX_PERMISSION_PROFILE` (informational), `CODEX_SANDBOX=seatbelt` (when sandboxed), `CODEX_SANDBOX_NETWORK_DISABLED=1` (when network is off). These are inherited by everything the command forks (dev servers included). An issue commenter identifies leaked helpers by "`CODEX_SANDBOX` set, no thread id, parent launchd, group leader gone" (#12491, 2026-10-02). `[verified]`
- Shell-tool children are started with `setsid()` (`detach_from_tty`, falling back to `setpgid(0,0)` on `EPERM`) and only Linux gets `PR_SET_PDEATHSIG` (`spawn.rs` even says the intent is that children die with Codex, "This relies on prctl(2), so it only works on Linux"); on macOS a child survives Codex's death and is re-parented to launchd — this is the orphan-dev-server mechanism (#25772, #42244). `CODEX_THREAD_ID` is inserted in step 6 of `shell_environment::populate_env`, *after* the `include_only` filter, so it survives any `shell_environment_policy`; `CODEX_SESSION_ID`/`CODEX_VERSION` come from `inject_session_env` (called from `unified_exec/process_manager.rs`, `unified_exec/shell_snapshot.rs`, `tasks/user_shell.rs`); `CODEX_SANDBOX=seatbelt` is set in `core/src/sandboxing/mod.rs` only when `SandboxType::MacosSeatbelt`. `[verified from source, 2026-10-17]`
- `SessionEnd` fires for the main thread when you archive/delete an open conversation, when Codex closes normally, or after the conversation "has been idle and isn't open in any connected client for 30 minutes"; never for subagents; 1 s default / 3 s max. `[verified]`

## 5. Rollout files (`~/.codex/sessions`) and other state

Sources: `codex-rs/rollout/src/{rollout_file_name,list_files,compression,lib}.rs`, `codex-rs/protocol/src/protocol.rs`, troubleshooting doc, environment-variables doc.

- Root: `CODEX_HOME` (default `~/.codex`; must exist if overridden). SQLite state: `CODEX_SQLITE_HOME` / `sqlite_home` (defaults to `CODEX_HOME`; file name not documented `[unverified]`). Logs `$CODEX_HOME/log` (`codex-tui.log` opt-in via `log_dir`); app logs `~/Library/Logs/com.openai.codex/YYYY/MM/DD`; app support `~/Library/Application Support/Codex`. `[verified]`
- Layout: `sessions/YYYY/MM/DD/rollout-<YYYY-MM-DDTHH-MM-SS>-<thread_uuid>.jsonl`; after `thread/revert` the name becomes `rollout-<ts>-<thread_uuid>_<rollout_uuid>.jsonl`; the parser treats the timestamp as UTC. Archived threads move to `archived_sessions/`. A background worker compresses cold files to `.jsonl.zst` (plain `.jsonl` takes precedence if both exist; `rollout-compression.lock` throttles; `.tmp/rollout-maintenance.lock` serializes maintenance). `history.jsonl` is a separate transcript controlled by `history.persistence = save-all|none` and `history.max_bytes`. `codex exec --ephemeral` skips rollout persistence. `[verified]`
- Line format: `{"timestamp": "...", "ordinal": n?, "type": "<item>", "payload": {...}}` with item types `session_meta`, `response_item`, `compacted`, `turn_context`, `event_msg`, `token_usage_record`, `world_state`, … (`RolloutLine` flattens `RolloutItem`; `type`/`payload` naming `[likely]`). First line is `session_meta` with: `session_id`, `id`, `forked_from_id?`, `parent_thread_id?`, `timestamp`, `cwd`, `runtime_workspace_roots?`, `originator`, `cli_version`, `source` (`cli|vscode|exec|mcp|custom:<name>|subagent…`), `model_provider`, `creator_user_id?`, plus `git: {commit_hash, branch, repository_url}`. `turn_context` lines carry per-turn `cwd`, `approval_policy`, `sandbox_policy`, `model`. `ExecCommandBegin/End` events are **not** persisted; the commands themselves are recoverable from `response_item` function calls. `[verified struct; persisted-set likely]`
- Codex itself indexes threads in SQLite ("state DB") with filesystem fallback; the desktop app was reported laggy because it scanned all rollout files (#20864). `[verified]`
- Sizes (GitHub issues, all open): #38838 (2026-08-16): 938 sessions = **39.4 GiB**, 732 subagent sessions = 22.7 GiB, one file ≈ 9.5 GB; #42518 (2026-09-03): six subagent files of **10.4–10.7 GB** each (97.8 % `compacted` records); #24948 (2026-05-28): single sessions 700 MB–2 GB; #49797 (2026-10-01): 3.25 GB from duplicated image data. The market report's "100+ GB `.codex/sessions`" Reddit thread is consistent. `[verified issues]`

Local `~/.codex` on the dev machine contains only `memories/ skills/ tmp/` (416 KB, created 2026-06-14 by some tool) — no Codex usage history. `[verified]`

## 6. Worktrees

Sources: https://learn.chatgpt.com/docs/environments/git-worktrees (accessed 2026-10-17), `codex-rs/worktree/src/{paths,settings,metadata,lib}.rs`, changelog, issue #22875.

- Location: `$CODEX_HOME/worktrees` by default (app: Settings → Worktrees → "Worktree root"; config `[desktop] git-worktree-root = "/abs/path"`). Each checkout is `<root>/<4 hex chars>/<repository dir name>`; the root carries a `.metadata_never_index` marker (Spotlight off). `[verified]`
- Creation: `git worktree add --detach --no-checkout <path> <base_sha>` from the source repo, then `core.worktree` set in the worktree's `config.worktree`, then `--work-tree=. reset --hard --no-recurse-submodules <sha>`; **detached HEAD**, no branch. Base = HEAD of the branch chosen; uncommitted local changes can be applied; ignored files are copied only if listed in `.worktreeinclude` (plus `AGENTS.override.md`). `[verified]`
- Ownership: `codex-thread.json` = `{"version":1,"ownerThreadId":"<thread uuid>"}` (serde `deny_unknown_fields`, `persist_noclobber`, never re-bound to another thread) written at `git rev-parse --git-path codex-thread.json`. Local probe (git 2.39.5, 2026-10-17): after `git worktree add --detach --no-checkout <path> <sha>` + `git --work-tree=. reset --hard --no-recurse-submodules <sha>` the checkout has a detached HEAD, its `.git` is a pointer **file** (`gitdir: <main>/.git/worktrees/<name>`), and `--git-path codex-thread.json` resolves to `<main>/.git/worktrees/<name>/codex-thread.json` — i.e. the owner record lives in the **source repo's** `.git`, not in the worktree directory, so Airbag can enumerate all Codex-owned worktrees of a repo by globbing `<repo>/.git/worktrees/*/codex-thread.json`. One worktree ↔ one thread; the app returns a chat to the same worktree on handoff. `[verified: source + local probe]`
- Cleanup (desktop app): keep the **15** most recent managed worktrees (`[desktop] worktree-keep-count`, default `DEFAULT_WORKTREE_KEEP_COUNT = 15`); `worktree-auto-cleanup-enabled` default true (settings added in app 26.227/26.303); deleted automatically when the chat is archived or to stay within the limit; **not** deleted if the chat is pinned, still in progress, or the worktree is permanent; a snapshot is saved before deletion and offered for restore. The CLI path (`WorktreeSettings::for_cli`) forces `auto_cleanup_enabled = false`, and `remove()` refuses when ignored local files exist. `[verified]`
- CLI: `/worktree` slash command and managed-worktree tools shipped in CLI 0.162.0 (2026-10-08) "when the worktrees feature is enabled"; `Browse worktrees` shows owner chats. `[verified]`
- Projectless app threads use `~/Documents/Codex/<YYYY-MM-DD>/<slug>` (issue #22875, May 2026). `[verified then; may have changed]`
- "Worktree by default for agent sessions since 2026-09-22": **not found**. The changelog entry dated 2026-09-22 is "GPT-6 Sol and Luna in Codex and ChatGPT Work" (models, nothing about worktrees). The docs say "By default, chats use a Codex-managed worktree" only in contrast to *permanent* worktrees, in the context of choosing **Worktree** over **Local** (the git-worktrees page names Local and Worktree plus Handoff between them; the `Cloud` option is a composer environment choice, not covered by that page `[likely]`). The nearest changelog items are **ChatGPT for iOS 1.2026.251** (2026-09-18) "New tasks remember your worktree mode and setup environment for each project" and **ChatGPT for iOS 1.2026.267** (2026-10-02) "Worktree creation now respects your computer's configured storage location" — both are mobile-app release notes, not desktop/CLI defaults; scheduled tasks/automations default to dedicated worktrees (app 26.224/26.312). Treat worktree mode as per-project sticky, not global default. `[verified absence in changelog, re-checked 2026-10-17 against the full 1.7 MB page]`

## 7. Sandbox and approvals, and how they interact with hooks

Sources: https://learn.chatgpt.com/docs/agent-approvals-security, /docs/sandboxing, config reference, `codex-rs/sandboxing/src/seatbelt.rs`, `codex-rs/core/src/spawn.rs`.

- `sandbox_mode`: `read-only | workspace-write | danger-full-access` (plus beta named permission profiles `:read-only`, `:workspace`, `:danger-full-access`, `default_permissions`). Default for git repos: Auto = `workspace-write` + `approval_policy = on-request`; non-git folders: `read-only`. `[verified]`
- `approval_policy`: `on-request | never | { granular = {...} }`; `untrusted` **retired** (prevents startup), `on-failure` deprecated. `approvals_reviewer = user | auto_review`. CLI flags: `--sandbox <mode>`, `--ask-for-approval|-a <policy>`, `--approve-for-me`, `--dangerously-bypass-approvals-and-sandbox` (alias `--yolo`); `--full-auto` "is no longer supported" for `codex exec`. `[verified]`
- macOS enforcement: `/usr/bin/sandbox-exec -p <generated SBPL>` (path pinned, PATH ignored); base policy is `(deny default)` with process-exec/fork allowed so children inherit it. `workspace-write` writable roots = cwd + `/tmp` + `$TMPDIR` (opt-outs `exclude_slash_tmp`, `exclude_tmpdir_env_var`) + `sandbox_workspace_write.writable_roots`; **protected read-only inside writable roots: `.git` (and the resolved gitdir for pointer files), `.codex`, `.agents`, `.aws`**. Network off unless `[sandbox_workspace_write] network_access = true`; optional `features.network_proxy` domain policy. `[verified]`
- Consequence for Airbag's breaker: in the default Auto mode, `git reset --hard`, `git clean -fdx`, `git push --force` need to write `.git` or use the network, so they fail inside the sandbox and Codex **asks for approval** → `PermissionRequest` fires with `tool_input.command`; `rm -rf` *inside* the workspace does **not** need approval (`PreToolUse` is the only interception point). Under `danger-full-access`/`--yolo`, only `PreToolUse` runs; `PermissionRequest` never fires. `[likely — inference from documented rules]`
- Order within a tool call: `PreToolUse` (can deny/rewrite) → approval decision (`PermissionRequest` only if an approval would be asked; `approvals_reviewer=auto_review` may route it to a reviewer model) → sandboxed exec → `PostToolUse`. Hooks run unsandboxed. `[likely]`
- Auto-review (`approvals_reviewer = "auto_review"`) and GPT-6 Astra "safety monitoring" are OpenAI's own guardrails; they are model-based, fail closed on errors, and only see actions that already need approval — they do not snapshot and do not cover in-workspace `rm -rf`. `[verified]`
- Unified exec (`features.unified_exec`, "enabled on all platforms, user opt-outs are ignored") keeps long-running commands in PTY sessions across turns; `PostToolUse` for such a command may be delivered by a later `write_stdin` poll. `[verified]`

## 8. Codex desktop app: how it runs the CLI (process attribution)

Evidence: GitHub issues #24185, #24991, #12491 (comments 2026-03..2026-10), #48214, #34083, #19794, Homebrew `codex-app` cask JSON, troubleshooting doc. No local observation possible.

```
launchd
└── /Applications/Codex.app/Contents/MacOS/Codex            (Electron main; bundle id com.openai.codex)
    │   also seen as /Applications/ChatGPT.app/Contents/MacOS/ChatGPT with the same bundle id (Sep 2026+)
    ├── Codex Helper (Renderer) --renderer-client-id=N       (Electron renderers)
    ├── Codex Helper (GPU) / Codex Helper --type=gpu-process
    ├── …/Contents/Resources/codex app-server --analytics-default-enabled   (Rust CLI, one per app; older layout)
    │   or …/Contents/Resources/codex-cli/bin/codex app-server … (layout since app 26.924, manifest codex-package.json)
    │   or …/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true app-server --analytics-default-enabled
    │   ├── /usr/bin/sandbox-exec -p … /bin/zsh -lc "<shell tool command>"   (setsid; env CODEX_THREAD_ID=…)
    │   ├── …/Contents/Resources/node_repl, codex-code-mode-host              (code mode)
    │   ├── MCP servers (npx/uvx/…), heroku mcp:start, playwright-mcp …
    │   └── ~/.codex/computer-use/Codex Computer Use.app/…/SkyComputerUseClient mcp
    └── …/Contents/Resources/codex_chronicle (sidecar; purpose undocumented)
```
`[verified from issue reports; exact arguments vary by version]`

- The CLI inside the app can be a different version than Homebrew's (`/Applications/Codex.app/Contents/Resources/codex --version` is the documented "retained compatibility bundle path"; issue #48214 shows it missing on 26.924 with `codex-cli/bin/codex` instead). Airbag's agent detector should match the process **arguments** (`app-server`, `exec`, `mcp-server`) and executable path prefixes, not one fixed path. `[verified]`
- Leaks: MCP/REPL/Computer-Use children accumulate under a live `codex app-server` (hundreds of processes, 16–37 GB RSS) and some are re-parented to launchd when the app dies; a user shipped a read-only tool "tidewake" to spot them (#12491, 2026-10-02). `[verified]`
- `codex app-server` also runs as a user daemon (`/daemon` TUI command; third-party bridges start `codex app-server --listen ws://127.0.0.1:8791`) — a `codex` process with no TTY and no Codex.app ancestor is possible. `[likely]`
- Market-report items: #42244 "Show agent-started dev servers and background processes in Codex Desktop" (open, 2026-09-02, 5 comments, 2 reactions; a commenter notes `process/spawn` in app-server returns no durable process identity); #12491 open/reopened; #9203 `/undo` open with 536 reactions, last maintainer word 2026-01-16 ("will need to be redesigned"); community answers are third-party shadow-git tools (snap-back, agentckpt). `[verified]`

## 9. Existing third-party integrations (working examples)

### 9.1 CC Safety Net (kenryu42/claude-code-safety-net, v2.6.12)

Installed into Codex as a **plugin** through the author's marketplace (`npx -y cc-safety-net@latest install --codex` → adds `cc-marketplace` from `kenryu42/cc-marketplace`, installs `cc-safety-net@cc-marketplace`; the marketplace points at the `plugin` ref of the repo). `.codex-plugin/plugin.json` sets `"hooks": "./hooks/codex.json"`; that file is: `[verified]`

```json
{
  "description": "Block unsafe Codex tool calls with CC Safety Net.",
  "hooks": {
    "PreToolUse": [
      { "hooks": [ { "type": "command",
                     "command": "node \"${PLUGIN_ROOT}/dist/bin/cc-safety-net.js\" hook --codex" } ] }
    ]
  }
}
```

No matcher (all tools), `src/hosts/codex/hook.ts` maps only `Bash` to a command tool (`CODEX_COMMAND_TOOLS = [['Bash','auto']]`); detection parses `codex plugin list` for `installed, enabled`; `doctor` cannot check trust and prints: "Start Codex, open `/hooks`, select the cc-safety-net PreToolUse hook, and press `t` to trust it." Install docs warn that input typed into an already-running interactive session is never inspected. The shared `runPreToolUseHook` emits the JSON deny / exit-2 contract common to Claude Code. `[verified]`

### 9.2 Adrafinil (kageroumado/adrafinil, Swift, macOS 26.4+)

Writes `~/.codex/hooks.json` directly (`CodexIntegration.swift`, `CodexHookShape.swift`): `UserPromptSubmit` → `adrafinil acquire --tool codex`, `Stop` → `release`, `SubagentStart/SubagentStop` with `--subagent` (keys on `agent_id`); earlier `SessionStart` handlers are stripped as obsolete because "a resume does not fire it (verified live)" (that observation predates the maintainer's "first turn" statement; both can be true for their build). Design rules worth copying: no marker keys (strict parsing), identify own handlers by the command containing `adrafinil`, never rewrite a byte-identical handler (keeps `trusted_hash` valid), repair only a drifted command, append a fresh group when absent, drop empty event arrays on uninstall. Trust detection reads `[hooks.state."<hooks.json path>:<event>:…"]` tables with a non-empty `trusted_hash` from `config.toml` (`CodexHookTrust.swift`). Process matching uses basenames `codex`, `codex-aarch64-apple-darwin`, `codex-x86_64-apple-darwin` because Homebrew's symlink resolves to the suffixed binary under `proc_pidpath`. Their comment that "`codex exec` ignores hooks.json entirely" is contradicted by the exec crate's own hook test (`codex-rs/exec/tests/suite/hooks.rs`) and by #32491 reports for ≥0.147 — do not rely on it. `[verified source; claims therein as stated]`

## 10. Copy-pasteable Airbag hook config for Codex

Assumptions: a single Airbag CLI at a **stable, user-independent path** (the command string is hashed; use the same string for every user and never embed a version), e.g. `/Applications/Airbag.app/Contents/MacOS/airbag` or the cask-installed `/opt/homebrew/bin/airbag` (Intel: `/usr/local/bin/airbag`). Pick one per machine at install time and keep it forever; if it must change, the user re-trusts once.

`~/.codex/hooks.json` (merge, do not overwrite):

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command",
                     "command": "/opt/homebrew/bin/airbag hook codex session-start",
                     "timeout": 5, "statusMessage": "Airbag: registering session" } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command",
                     "command": "/opt/homebrew/bin/airbag hook codex prompt",
                     "timeout": 5 } ] }
    ],
    "PreToolUse": [
      { "matcher": "^Bash$",
        "hooks": [ { "type": "command",
                     "command": "/opt/homebrew/bin/airbag hook codex pre-bash",
                     "timeout": 30, "statusMessage": "Airbag: snapshot + safety check" } ] },
      { "matcher": "^apply_patch$",
        "hooks": [ { "type": "command",
                     "command": "/opt/homebrew/bin/airbag hook codex pre-edit",
                     "timeout": 10, "statusMessage": "Airbag: snapshot" } ] }
    ],
    "PermissionRequest": [
      { "matcher": "^Bash$",
        "hooks": [ { "type": "command",
                     "command": "/opt/homebrew/bin/airbag hook codex permission",
                     "timeout": 10 } ] }
    ],
    "PostToolUse": [
      { "matcher": "^Bash$",
        "hooks": [ { "type": "command",
                     "command": "/opt/homebrew/bin/airbag hook codex post-bash",
                     "async": true, "timeout": 20 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command",
                     "command": "/opt/homebrew/bin/airbag hook codex stop",
                     "timeout": 5 } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command",
                     "command": "/opt/homebrew/bin/airbag hook codex session-end",
                     "timeout": 2 } ] }
    ]
  }
}
```

Behaviour of each `airbag hook codex …` subcommand (reads the JSON from stdin, always exits 0 unless denying):

| Subcommand | Action | stdout |
|---|---|---|
| `session-start`, `prompt` | upsert registry row: `agent=codex`, `session_id`, `cwd`, `transcript_path`, `model`, `permission_mode`, Codex PID (walk `getppid()` chain), surface (CLI/app/exec) | none |
| `pre-bash` | evaluate rules on `tool_input.command`; take a snapshot of the project (or of the rule's target paths when the full project is too large for the budget); on **block**: print the deny JSON below (non-empty `permissionDecisionReason` is mandatory); on **allow**: print **nothing** — never emit `permissionDecision:"allow"` without `updatedInput`, Codex marks that Failed; on **ask**: cannot (`ask` unsupported) → deny with a reason that tells the user to re-run with Airbag's allow token, or allow and snapshot — policy decision | deny JSON or empty |
| `pre-edit` | snapshot (cheap; FSEvents is the backstop) | empty |
| `permission` | deny destructive escalations (`git reset --hard`, `git clean -fdx`, `git push --force`, `prisma migrate reset --force`, `DROP DATABASE`) | `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Airbag: …"}}}` |
| `post-bash` | label the last snapshot with exit status; scan new listening sockets of processes whose env has `CODEX_THREAD_ID == session_id` | empty |
| `stop`, `session-end` | mark turn idle / session ended (`SessionEnd` may never arrive for crashes — keep the PID liveness check) | empty |

Deny payload for `pre-bash` (exit 0):

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
 "permissionDecisionReason":"Airbag blocked `git reset --hard`: it would discard 14 uncommitted files. Snapshot #182 was taken; open Airbag to allow once."}}
```

Equivalent minimal TOML if a user prefers `config.toml` (do not install both; Codex warns and the trust keys differ):

```toml
[[hooks.PreToolUse]]
matcher = "^Bash$"
[[hooks.PreToolUse.hooks]]
type = "command"
command = "/opt/homebrew/bin/airbag hook codex pre-bash"
timeout = 30
statusMessage = "Airbag: snapshot + safety check"
```

After installation the user must trust the handlers once: `codex` → `/hooks` → each Airbag handler → `t` (or app Settings → Hooks). Airbag verifies trust by looking for `[hooks.state."<abs hooks.json>:pre_tool_use:<g>:<h>"]` with a non-empty `trusted_hash` in `~/.codex/config.toml`, and shows an "untrusted / modified" badge otherwise. Preflight checks: `codex --version` ≥ 0.124.0 (and the app-bundled CLI version), `[features] hooks` not `false`, no `allow_managed_hooks_only` in any `requirements.toml`, `~/.codex/hooks.json` parses.

Optional alternative: ship Airbag as a Codex plugin (`.codex-plugin/plugin.json` + `hooks/hooks.json`, command `"${PLUGIN_ROOT}/bin/airbag …"`) via a marketplace entry — same trust step, more install friction, but survives path changes. Not recommended for v1.

## 11. What this means for Airbag (design implications)

1. **Hook bridge for Codex is cheap and symmetric with Claude Code.** Same nested JSON, same `PreToolUse`/`Stop` semantics, same exit-2 convention. One `airbag hook <agent> <event>` entry point with per-agent field mapping (`Bash`+`tool_input.command` string for Codex vs Claude's `Bash`+`tool_input.command`) covers both. Install target: user-level `~/.codex/hooks.json`, never project `.codex/` (trust-gated, silently skipped).
2. **Trust is the onboarding hurdle, not config.** Design the install flow as "write hooks → open Codex → `/hooks` → `t`" with live detection from `config.toml` (`[hooks.state]`), exactly like Adrafinil. Keep the command string and group order byte-stable across Airbag upgrades; never reorder or rewrite other handlers; append your own matcher groups at the end of each event array. Decide explicitly whether to offer the app-server `hooks/list` + `config/batchWrite` shortcut (`[likely]`), and if so only behind an explicit user click — it bypasses Codex's review UX and depends on undocumented RPC behaviour.
3. **Hooks are fail-open and time-boxed.** `pre-bash` must finish inside its timeout (set 30 s, target < 2 s p95) or the command runs unprotected; a crashing hook is treated as "allow". Therefore: snapshot engine must have an incremental fast path (dirty-set from FSEvents + `git`-style index), with a hard internal budget and a fallback that snapshots only the command's target paths (rm/mv/sed -i arguments, as bashward/doover do). FSEvents snapshots remain the primary safety net; hooks add labelled "before command X" points.
4. **No `ask` from `PreToolUse`.** Codex does not support `permissionDecision: "ask"`; the "ask" tier of the circuit breaker must be implemented as deny-with-instructions plus a one-shot allow token stored in the registry (the model will retry with the token after the user clicks Allow in Airbag), or as a `PermissionRequest` allow/deny when the command already needs approval. Also note `write_stdin` to a running interactive session is invisible to hooks.
5. **Process attribution for the radar is better than for Claude Code.** Any process spawned by a Codex shell tool, and its descendants, has `CODEX_THREAD_ID`, `CODEX_SESSION_ID`, `CODEX_TOOL_CALL_ID` (and `CODEX_SANDBOX` in sandboxed modes) in its environment. Read environments of same-user processes via `sysctl(KERN_PROCARGS2)` (works without Full Disk Access for your own uid) and join to the registry by thread id. Orphan rule: `PPID == 1` ∧ (`CODEX_THREAD_ID` set ∨ `CODEX_SANDBOX` set) ∧ owning session ended or Codex PID dead. Keep the PID-ancestry method as fallback for processes that scrub their env.
6. **Agent/surface detection:** the Codex CLI process is `codex` (or `codex-<triple>` for Homebrew); the app's engine is `codex app-server` under `Codex.app`/`ChatGPT.app` (bundle `com.openai.codex`); `codex exec` and `codex mcp-server` are headless. Match on argv, not on a path. Record the Codex PID per session from the hook (`getppid()` chain) and the app's Electron main PID as the "surface".
7. **Worktree awareness is mostly path parsing.** `~/.codex/worktrees/<4hex>/<repo>` (or the user's configured root from `[desktop] git-worktree-root`) → owner thread via `git rev-parse --git-path codex-thread.json` → session row. For the v1.1 disk cleaner: respect the app's own policy (keeps 15, auto-cleanup flag), never delete a worktree whose owner thread is live or pinned (pinned state lives in the app's private state — unknown to Airbag → treat "owner thread has a rollout modified in the last N days" as "keep"), and prefer "show + one-click `git worktree remove`" over automatic deletion. Codex already snapshots a worktree before deleting it, so Airbag's value here is visibility and dependency weight (`node_modules`), not recovery.
8. **Timeline enrichment from rollouts is optional but cheap:** `transcript_path` gives the session's JSONL; the first line (`session_meta`) has cwd/git branch/commit/originator/cli_version; later `response_item` function calls hold the exact commands. Readers must handle `.jsonl.zst` and 10 GB files (stream, never load). Do not write to these files.
9. **Sandbox mode changes which hook protects.** In Auto (`workspace-write`), destructive git operations hit `.git` read-only protection or network and surface as `PermissionRequest` — Airbag can deny there with full context; `rm -rf` inside the workspace never asks → `PreToolUse` is the only gate. In `--yolo`/`danger-full-access` only `PreToolUse` exists. Snapshots must not depend on either.
10. **Session lifecycle signals:** `SessionStart` = first turn of a thread (source `startup|resume|fork|clear|compact`), `UserPromptSubmit` = every turn start (most reliable "active" signal), `Stop` = turn end (not emitted on Esc interrupt — `Interrupt` is, 1 s budget), `SessionEnd` = close/archive/30-min idle. Keep PID liveness as the ground truth for "session alive".
11. **Codex-specific gaps Airbag fills:** no `/undo` (#9203), no process view (#42244), no worktree/session disk dashboard (#38838), process leaks (#12491). Codex's own mitigations (worktree snapshot before delete, auto-review, safety monitoring) do not cover bash-side damage inside the workspace.
12. **Version gating & diagnostics:** require CLI ≥ 0.124.0; warn on the app-bundled CLI version (`…/Contents/Resources/codex --version` or `…/codex-cli/bin/codex --version`); detect `[features] hooks = false`, `allow_managed_hooks_only`, and the 0.142.5-style "hooks not discovered" regression by watching for the absence of `SessionStart`/`UserPromptSubmit` while a Codex process is alive.

## 12. Open questions

1. Exact `tool_input` for `Bash` beyond `command` (e.g. `workdir`, `timeout_ms`, `description`, `with_escalated_permissions`) — schema says `any`; needs a live capture on a Codex install.
2. Whether `SessionStart(source=resume)` fires reliably in the TUI today (Adrafinil observed it did not; maintainers say "first turn") — verify on 0.163.
3. Does the hook shell get `exec`'d into the command (so Airbag's parent is Codex directly) with the user's default zsh? Affects PID-walk depth only; implement a bounded walk regardless.
4. `config/batchWrite` of `hooks.state.<key>.trusted_hash` via app-server as a consented "trust Airbag" shortcut: confirm the RPC shape on 0.163 and whether the TUI/app treats it identically to a manual `t`. No maintainer has endorsed this path (the #54353 reply only says hooks "must be trusted individually"); the only evidence is two #32491 user comments.
5. SQLite state DB file name/schema under `CODEX_HOME` (thread index, pinned flags) — useful for the worktree cleaner's "pinned" check; undocumented.
6. The current desktop app bundle layout (`Codex.app` vs `ChatGPT.app`, `Resources/codex` vs `Resources/codex-cli/bin/codex`) and whether `codex app-server` is one per app or per workspace in 26.10xx.
7. Serialized `type`/`payload` key names of rollout lines (`[likely]`) and which `event_msg` kinds are persisted — confirm against a real file before building the timeline enricher.
8. Rollout filename timestamp zone (parsed as UTC; is it written in UTC or local?).
9. `hooks` shell override config key (`HooksConfig.shell_program/shell_args`) — undocumented; could matter if a user sets a non-POSIX shell.
10. Whether the Homebrew `codex` cask still symlinks to a triple-suffixed binary (Adrafinil's claim) — affects the process-name matcher; check on a machine with the cask.
11. Is the "worktree-by-default since 2026-09-22" claim in the brief from a source outside the public changelog (e.g. a mobile release note)? Nothing found.

## Sources (accessed 2026-10-16/17)

Official docs (learn.chatgpt.com; `developers.openai.com/codex/*` 308-redirects here):
- Hooks: https://learn.chatgpt.com/docs/hooks (markdown: https://learn.chatgpt.com/docs/hooks.md)
- Config reference: https://learn.chatgpt.com/docs/config-file/config-reference ; basics: https://learn.chatgpt.com/docs/config-file/config-basic ; advanced: https://learn.chatgpt.com/docs/config-file/config-advanced
- Environment variables: https://learn.chatgpt.com/docs/config-file/environment-variables
- Agent approvals & security: https://learn.chatgpt.com/docs/agent-approvals-security ; Sandbox: https://learn.chatgpt.com/docs/sandboxing ; Permissions: https://learn.chatgpt.com/docs/permission-modes
- Worktrees: https://learn.chatgpt.com/docs/environments/git-worktrees ; Environments: https://learn.chatgpt.com/docs/environments/modes ; Local environments: https://learn.chatgpt.com/docs/environments/local-environment
- Developer commands (`/hooks`, `/worktree`, flags): https://learn.chatgpt.com/docs/developer-commands?surface=cli ; Non-interactive: https://learn.chatgpt.com/docs/non-interactive-mode
- Troubleshooting (log/session paths, bundled CLI path): https://learn.chatgpt.com/docs/reference/troubleshooting
- Changelog: https://learn.chatgpt.com/docs/changelog (HTML; 1.7 MB)

openai/codex repository (branch `main`, 2026-10-16):
- `codex-rs/hooks/src/engine/command_runner.rs`, `engine/discovery.rs`, `engine/mod.rs`, `events/*.rs`, `legacy_notify.rs`, `lib.rs`, `registry.rs`, `config_rules.rs`, `declarations.rs`
- `codex-rs/hooks/schema/generated/pre-tool-use.command.input.schema.json`
- `codex-rs/config/src/hook_config.rs`; `codex-rs/app-server-protocol/src/protocol/v2/hook.rs`
- `codex-rs/core/src/hook_runtime.rs`, `exec_env.rs`, `spawn.rs`, `exec.rs`, `sandbox_tags.rs`, `rollout.rs`
- `codex-rs/protocol/src/protocol.rs` (`SessionMeta`, `SessionSource`, `GitInfo`, `TurnContextItem`), `codex-rs/protocol/src/shell_environment.rs`
- `codex-rs/rollout/src/rollout_file_name.rs`, `list_files.rs`, `compression.rs`, `maintenance.rs`, `lib.rs`; `codex-rs/history/src/lib.rs`
- `codex-rs/worktree/src/paths.rs`, `settings.rs`, `metadata.rs`, `lib.rs`, `git.rs`
- `codex-rs/sandboxing/src/seatbelt.rs`, `seatbelt_base_policy.sbpl`, `spawn.rs`; `codex-rs/utils/pty/src/posix_child.rs`, `process_group.rs`
- Release `rust-v0.124.0`: https://github.com/openai/codex/releases/tag/rust-v0.124.0 (published 2026-04-23T18:29Z)
- Issues: #9203 https://github.com/openai/codex/issues/9203 ; #42244 https://github.com/openai/codex/issues/42244 ; #12491 https://github.com/openai/codex/issues/12491 ; #54353 https://github.com/openai/codex/issues/54353 ; #32491 https://github.com/openai/codex/issues/32491 ; #41979 https://github.com/openai/codex/issues/41979 ; #48214 https://github.com/openai/codex/issues/48214 ; #22875 https://github.com/openai/codex/issues/22875 ; #38838, #42518, #24948, #49797, #20864, #30835, #35306, #48183, #54072, #24185, #24991, #34083, #19794 (GitHub API search results)

Third-party source:
- CC Safety Net: https://github.com/kenryu42/claude-code-safety-net (`.codex-plugin/plugin.json`, `hooks/codex.json`, `src/hosts/codex/{detect,hook}.ts`, `package.json` v2.6.12); install docs https://ccsafetynet.com/docs/installation ; marketplace https://github.com/kenryu42/cc-marketplace (`.agents/plugins/marketplace.json`)
- Adrafinil: https://github.com/kageroumado/adrafinil (`AdrafinilShared/Sources/AdrafinilShared/Installer/Integrations/CodexIntegration.swift`, `Support/CodexHookShape.swift`, `Support/CodexHookTrust.swift`, `Models/AgentKind.swift`)

Package data:
- Homebrew cask `codex`: https://formulae.brew.sh/api/cask/codex.json ; cask `codex-app`: https://formulae.brew.sh/api/cask/codex-app.json ; 30-day cask analytics: https://formulae.brew.sh/api/analytics/cask-install/30d.json
- GitHub releases API: https://api.github.com/repos/openai/codex/releases

## Verification log (independent re-check, 2026-10-17)

Method: a second pass by a skeptical reviewer. Each item below was re-checked against the primary source named (raw files from `openai/codex` `main` fetched with curl on 2026-10-17; official docs at `learn.chatgpt.com`; GitHub API via `gh`; local `git` probe). "Verdict" is about the claim as it stood in the earlier draft.

| # | Claim checked | Source / probe | Verdict |
|---|---|---|---|
| 1 | PreToolUse blocking: `hookSpecificOutput.permissionDecision=deny` + non-empty reason, legacy `decision:block`, exit 2 + stderr; `ask`, `continue:false`, `stopReason`, `suppressOutput` unsupported → Failed, tool runs; PermissionRequest `decision.behavior=deny` + `message`, any deny wins | `codex-rs/hooks/src/events/pre_tool_use.rs::parse_completed`; `codex-rs/hooks/src/engine/output_parser.rs` (`unsupported_pre_tool_use_*`, `invalid_pre_tool_use_reason_message`); `codex-rs/hooks/src/events/permission_request.rs` (`resolve_decision`: "any deny wins"); https://learn.chatgpt.com/docs/hooks.md | **Correct**, with an addition: `permissionDecision:allow` without `updatedInput`, `updatedInput` without `allow`, `decision:approve`, and exit 2 with empty stderr are all Failed (fail-open). Added to §2.5 and §10. |
| 2 | PreToolUse stdin required fields and `permission_mode` derivation | `codex-rs/hooks/schema/generated/pre-tool-use.command.input.schema.json` (required: cwd, hook_event_name, model, permission_mode, session_id, tool_input, tool_name, tool_use_id, transcript_path, turn_id; optional agent_id, agent_type; `additionalProperties:false`); `codex-rs/core/src/hook_runtime.rs::hook_permission_mode` (`Never` → `bypassPermissions`; `UnlessTrusted|OnRequest|Granular` → `default`) | **Correct.** |
| 3 | Hook locations, all layers run, project hooks only when trusted, `hooks.json` top level = `description` + `hooks` only | https://learn.chatgpt.com/docs/hooks.md ("If more than one hook source exists, Codex loads all matching hooks", "Project-local hooks load only when the project `.codex/` layer is trusted"); `codex-rs/config/src/hook_config.rs` (`#[serde(deny_unknown_fields)] struct HooksFile { description, hooks }`) | **Correct.** |
| 4 | 12 events; shell/`exec_command` match `Bash`; `apply_patch` with aliases `Edit`/`Write`; `write_stdin` does not re-trigger PreToolUse | `codex-rs/hooks/src/lib.rs` (`HOOK_EVENT_NAMES: [&str; 12]`); `codex-rs/core/src/tools/hook_names.rs` (`bash()` → "Bash"; `apply_patch()` aliases `["Write","Edit"]`; `spawn_agent()` alias `Agent`); hooks doc ("doesn't run `PreToolUse` again") | **Correct.** |
| 5 | Timeouts 600 s default, SessionEnd/Interrupt 1 s default / 3 s max; 8 async hooks; fail-open | `codex-rs/hooks/src/engine/discovery.rs::normalize_command_hook` (`unwrap_or(600)`, clamp to `SESSION_END_*`); `codex-rs/hooks/src/events/session_end.rs` (`SESSION_END_DEFAULT_TIMEOUT_SEC = 1`, `SESSION_END_MAX_TIMEOUT_SEC = 3`); `codex-rs/hooks/src/engine/command_runner.rs` (`MAX_CONCURRENT_ASYNC_HOOKS = 8`; timeout/spawn_error/stdin_error/wait_error → `error` → `HookRunStatus::Failed`, `should_block=false`); `hook_runtime.rs` (`if !should_block { Continue }`); https://github.com/openai/codex/issues/41979 (open, 2026-09-01) | **Correct.** |
| 6 | Hook spawn: `$SHELL -lc`, `/bin/sh` fallback, `posix_spawn` + `POSIX_SPAWN_SETSID`, cwd = session cwd, env snapshot minus `NON_INHERITABLE_ENV_VARS`, no `CODEX_THREAD_ID` for hooks, process group SIGKILL on timeout | `command_runner.rs::build_command` / `default_shell_program`; `codex-rs/utils/pty/src/posix_child.rs` (`ProcessMode::NewSession => POSIX_SPAWN_SETSID`); `codex-rs/utils/pty/src/child_command.rs` (fallback path uses `pre_exec` → `detach_from_tty()` = `setsid()`); `codex-rs/hooks/src/registry.rs::Hooks::new` (`std::env::vars_os().collect()`); `codex-rs/protocol/src/shell_environment.rs` (`NON_INHERITABLE_ENV_VARS`, 6 names as listed); `ProcessTreeGuard::drop` → `kill_process_group` (SIGKILL) | **Correct.** Added caveat: source comments say command hooks will move to the exec server, which would break the "hook's parent is the Codex PID" assumption. |
| 7 | Shell-tool child env (`CODEX_THREAD_ID` always, `CODEX_SESSION_ID`, `CODEX_TOOL_CALL_ID`, `CODEX_VERSION`, `CODEX_PERMISSION_PROFILE`, `CODEX_SANDBOX=seatbelt`, `CODEX_SANDBOX_NETWORK_DISABLED=1`); `setsid`; `PR_SET_PDEATHSIG` Linux-only | `codex-rs/core/src/exec_env.rs`; `shell_environment.rs::populate_env` step 6; `codex-rs/core/src/spawn.rs` (`detach_from_tty`, `#[cfg(target_os = "linux")] set_parent_death_signal`); `codex-rs/core/src/sandboxing/mod.rs` (`"seatbelt"` only for `SandboxType::MacosSeatbelt`); `codex-rs/utils/pty/src/process_group.rs::detach_from_tty` (`setsid`, `setpgid` fallback on EPERM) | **Correct.** |
| 8 | Trust: `/hooks` → `t`; app Settings → Hooks since 26.506; key `<abs path>:<snake_event>:<group>:<handler>`; hash over normalized identity; statuses Managed/Untrusted/Trusted/Modified; TOML `[hooks.state."…"] trusted_hash` | `codex-rs/hooks/src/lib.rs::hook_key` / `hook_event_key_label`; `discovery.rs::hook_hash` (`NormalizedHookIdentity{event_name, matcher, hooks:[handler]}` → `version_for_toml`), `hook_trust_status`; `codex-rs/tui/src/bottom_pane/hooks_browser_view.rs` (`KeyCode::Char('t')` → `trust_selected_hook` / `trust_all_hooks`); changelog entry 2026-05-08 "Codex app 26.506 … in-app trust review flow for hooks"; `hook_config.rs::HooksToml.state` | **Correct.** TOML header form upgraded from `[likely]` to `[verified from source]`. |
| 9 | "`codex exec` does run hooks (maintainer, issue #54353, 2026-10-16)" | `gh api repos/openai/codex/issues/54353/comments` — the only maintainer comment (etraut-openai) says `session_id` is on stdin, `SessionStart` runs on the first turn, hooks must be trusted individually; it never mentions `codex exec`. Independent evidence: `codex-rs/exec/tests/suite/hooks.rs::exec_hook_trust_bypass_runs_session_start_hook` (uses `--dangerously-bypass-hook-trust`); #32491 comments by non-maintainers (0.147.0 macOS; app-server `hooks/list` + `config/batchWrite`) | **Wrong attribution.** Conclusion stands (exec runs hooks) but on different evidence; downgraded the persisted-trust path to `[likely]`. Fixed in §1, §2.7, §9.2, §12. |
| 10 | 0.124.0 release date / notes; "Hooks general availability" 2026-05-14 | `gh api repos/openai/codex/releases/tags/rust-v0.124.0` → `published_at 2026-04-23T18:29:40Z`; release body "Hooks are now stable, can be configured inline in `config.toml` and managed `requirements.toml`" with #18893 #18385 #18391 #18888 #19012 ("Mark codex_hooks stable"); changelog text (1.7 MB HTML stripped locally): 2026-05-14 entry "Work with Codex from anywhere 26.513 … This launch also includes Hooks general availability" | **Correct.** |
| 11 | Worktrees: `$CODEX_HOME/worktrees/<4-hex>/<repo>`, detached HEAD, `codex-thread.json`, keep 15, CLI never auto-cleans, snapshot before delete, pinned/in-progress/permanent exceptions | `codex-rs/worktree/src/{settings,metadata,paths,lib}.rs`; https://learn.chatgpt.com/docs/environments/git-worktrees.md; local probe in a scratch repo (git 2.39.5) | **Correct.** Probe added: owner file resolves into the source repo's `.git/worktrees/<name>/`. |
| 12 | "No changelog entry makes worktrees default on 2026-09-22"; nearby entries | Full changelog text grep: 2026-09-22 = "GPT-6 Sol and Luna"; 2026-09-18 and 2026-10-02 worktree lines belong to **ChatGPT for iOS** release notes, not the desktop app | **Correct, imprecise.** Clarified the surface of the nearby entries in §6. |
| 13 | Sandbox: `/usr/bin/sandbox-exec -p`, `(deny default)`, `.git`/`.codex`/`.agents`/`.aws` read-only inside writable roots | `codex-rs/sandboxing/src/seatbelt.rs` (`MACOS_PATH_TO_SEATBELT_EXECUTABLE`, `vec!["-p", full_policy]`); `seatbelt_base_policy.sbpl` (`(deny default)`, `(allow process-exec)`, `(allow process-fork)`); `codex-rs/protocol/src/permissions.rs` (`PROTECTED_METADATA_PATH_NAMES`, `default_read_only_subpaths_for_writable_root` incl. resolved gitdir for `.git` pointer files) | **Correct.** The consequence "destructive git ops → PermissionRequest" remains an inference `[likely]`; not tested live. |

Not re-verified in this pass (no Codex install on the dev machine): live `tool_input` shape for `Bash`; whether `SessionStart(source=resume)` fires in the TUI; current desktop-app bundle layout; rollout `type`/`payload` key names; SQLite state DB schema; the exact `config/batchWrite` RPC shape for `hooks.state`.
