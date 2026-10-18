# 03 — Hooks in Cursor (IDE + CLI), Gemini CLI and GitHub Copilot CLI

Status: research, written 2026-10-16/17. Sources fetched on those dates; versions checked: Cursor CLI installer pin `2026.10.16-e3cb207`, Cursor IDE docs (current), Gemini CLI repo head `ed96fae` (2026-10-16, package `0.66.0-nightly.20261013`), Copilot CLI `1.0.98` (changelog 2026-10-14), CC Safety Net `2.6.12` (head `8f62e92`, 2026-10-15; re-checked 2026-10-17 at `4fd49ef` = 2.6.13, Cursor/Copilot hook sources unchanged in the parts cited), Adrafinil head `29d3434` (2026-10-14).
Tags: [verified] = primary source read on the access date; [likely] = secondary source or strong inference; [unverified] = not confirmed.

## TL;DR

1. All three agents have a synchronous pre-shell hook that can block: Cursor `beforeShellExecution` (`permission: allow|deny|ask`), Gemini `BeforeTool` matched on `run_shell_command` (`decision: allow|deny`; an undocumented `ask` exists in source at head `ed96fae`, see §4.5), Copilot `preToolUse` matched on tool `bash` (`permissionDecision: allow|deny|ask`). [verified]
2. All three have session start/end events; only Cursor's and Copilot's are reliable end-of-session signals; Gemini's `SessionEnd` is best-effort and not awaited. [verified]
3. Config files: Cursor `~/.cursor/hooks.json` / `<project>/.cursor/hooks.json` (flat entries, `"version": 1`); Gemini `~/.gemini/settings.json` / `<project>/.gemini/settings.json` (Claude-style nested `hooks` object, ms timeouts); Copilot `~/.copilot/hooks/*.json` / `<repo>/.github/hooks/*.json` (`"version": 1`, per-shell `bash`/`powershell` or `exec`+`args`). [verified]
4. Cursor's "Claude Code hooks compatibility" (changelog 2.4, 2026-01-22) is real and ON by default in IDE and CLI: Cursor reads `~/.claude/settings.json`, `.claude/settings.json`, `.claude/settings.local.json`, maps `PreToolUse`→`preToolUse`, `Bash`→`Shell`. Copilot CLI also reads repo-level `.claude/settings.json`. Consequence: an Airbag hook installed for Claude Code will also be invoked by Cursor (and, in-repo, by Copilot) — Airbag must install native configs and deduplicate. [verified]
5. Cursor CLI (`agent`, legacy `cursor-agent`) fires `beforeShellExecution`/`afterShellExecution` since Jan 2026 and `sessionStart`, `stop`, `postToolUse`, `afterFileEdit` since Apr 2026; `sessionEnd` in the CLI is not confirmed; cloud agents never fire session hooks. [verified: staff forum posts]
6. Process attribution markers in agent-spawned shells: Cursor `CURSOR_AGENT` (+ `CURSOR_SANDBOX=seatbelt` when sandboxed), Gemini `GEMINI_CLI=1`, Copilot `COPILOT_CLI=1`. Cursor IDE shells are children of `Cursor Helper (Plugin): extension-host (agent-exec) …`; Cursor CLI is `~/.local/share/cursor-agent/versions/<ver>/cursor-agent` with a bundled `node`. [verified/likely, see §3.8]
7. Cursor auto-creates worktrees under the fixed, non-configurable `~/.cursor/worktrees/` (staff, Jan and May 2026), capped by `cursor.worktreeMaxCount` (docs: default 25/machine) and pruned every `cursor.worktreeCleanupIntervalHours`. [verified]
8. Fail-safety differs: Cursor fails open unless `failClosed: true` (but a permission hook that emits invalid or schema-mismatching JSON blocks regardless; the docs list "no output" only as a `failClosed`-class failure, so empty stdout is *not* documented as a block); Gemini: exit 1 is a warning and proceeds, but any other non-zero exit with non-JSON text on stdout/stderr is converted to `deny` (source, §4.5); Copilot `preToolUse` fails CLOSED on hook error but OPEN on timeout (30 s default). Airbag's hook must always print exactly one valid JSON object. [verified]
9. Default hook timeouts: Cursor "platform default" (undocumented; CC Safety Net sets 30 s), Gemini 60 000 ms, Copilot 30 s. The snapshot work inside the hook therefore has a hard budget of a few seconds. [verified]
10. Both reference installers (CC Safety Net, Adrafinil) merge idempotently into shared JSON files, identify their own entries by command string (or a private tag key), remove only their own entries on uninstall, and avoid project-level hooks (trust prompts). Airbag should do the same, and prefer a dedicated file where the agent allows one (Copilot). [verified]

## 1. Scope and method

Brief: nail down for Cursor (IDE + CLI), Gemini CLI and Copilot CLI the config paths, JSON schema, event names (esp. before-shell and session start/end), stdin fields, blocking semantics, timeouts; check the Jan-2026 claim that Cursor CLI is Claude-hooks-compatible; how the Cursor agent terminal spawns processes; where Cursor creates worktrees; and derive copy-pasteable Airbag configs plus a compatibility matrix.

Method: official docs fetched (cursor.com/docs, docs.github.com), Gemini CLI source and docs cloned (sparse), Copilot CLI public repo cloned (changelog only; the CLI itself is closed source), CC Safety Net and Adrafinil cloned and their installers read, Cursor forum threads with staff replies read for CLI/worktree facts the docs omit. Local machine probed: no Cursor, `gemini`, `copilot` or `agent` binaries on PATH; `~/.gemini/settings.json` and `~/.copilot/config.json` exist (see §4.7, §5.7).

Not covered here: Claude Code and Codex hook details (other research docs); Codex appears only where the installers reveal facts worth cross-referencing (§6).

## 2. Cross-agent field map (what `airbag hook` must read per agent)

| Need | Cursor (`beforeShellExecution`) | Cursor (`preToolUse`, tool `Shell`) | Gemini (`BeforeTool`, `run_shell_command`) | Copilot (`preToolUse`, tool `bash`) |
|---|---|---|---|---|
| Shell command | `.command` | `.tool_input.command` | `.tool_input.command` | `.toolArgs.command` (toolArgs may arrive as a JSON *string*, see §5.4) |
| Working dir of the command | `.cwd` | `.tool_input.working_directory` (optional) else `.cwd` | `.tool_input.dir_path` (optional, relative to workspace) else `.cwd` | `.cwd` |
| Project roots | `.workspace_roots[]` | `.workspace_roots[]` | `.cwd` (= `GEMINI_PROJECT_DIR`) | `.cwd` |
| Session id | `.conversation_id` (+ `.generation_id` per turn) | same | `.session_id` (also env `GEMINI_SESSION_ID`) | `.sessionId` (camelCase) / `.session_id` (PascalCase) |
| Transcript | `.transcript_path` | same | `.transcript_path` | not in payload; `~/.copilot/session-state/<sessionId>/events.jsonl` |
| Event name | `.hook_event_name` = `beforeShellExecution` | `preToolUse` | `BeforeTool` | `preToolUse` (no event field in camelCase payload; present as `hook_event_name` only in PascalCase payload) |
| Agent fingerprint | `.cursor_version` present | same | `GEMINI_SESSION_ID` env, `hook_event_name` PascalCase + `run_shell_command` | camelCase keys + numeric `timestamp`; env `COPILOT_CLI=1` [likely] |
| Sandbox flag | `.sandbox` (bool) | — | — | — |
| Background flag | — | — | `.tool_input.is_background` | — |
| Allow | `{"permission":"allow"}` | same | `{"decision":"allow"}` or `{}` | `{}` or `{"permissionDecision":"allow"}` |
| Deny | `{"permission":"deny","user_message":"…","agent_message":"…"}` or exit 2 | same (exit 2 too) | `{"decision":"deny","reason":"…","systemMessage":"…"}` or exit 2 + stderr | `{"permissionDecision":"deny","permissionDecisionReason":"…"}` or exit 2 |
| Ask | `{"permission":"ask", …}` | accepted by schema, NOT enforced | `{"decision":"ask"}` forces the confirmation prompt in source (undocumented) [verified: source] | `{"permissionDecision":"ask", …}`; autopilot/cloud → deny |

Sources per column are in §3–§5.

## 3. Cursor (IDE and CLI)

### 3.1 Config files and precedence [verified]

Source: https://cursor.com/docs/agent/hooks (accessed 2026-10-16).

| Level | Path (macOS) | Notes |
|---|---|---|
| Enterprise (MDM) | `/Library/Application Support/Cursor/hooks.json` | Linux `/etc/cursor/hooks.json`, Windows `C:\ProgramData\Cursor\hooks.json` |
| Team | web dashboard (Enterprise only) | synced to members |
| Project | `<project-root>/.cursor/hooks.json` | loaded only in trusted workspaces; hooks run from the project root |
| User | `~/.cursor/hooks.json` | hooks run with cwd `~/.cursor/` |

Priority Enterprise > Team > Project > User; all matching hooks from every source run; for permissions `deny` beats `ask` beats `allow`; `user_message`/`agent_message` are concatenated; for other fields (e.g. `followup_message`) "the last response wins" — responses merge in priority order, so a *lower*-priority source overrides a higher-priority one for those fields. Third-party (Claude Code) files rank below all native sources (§3.6).

CLI settings that are *not* hooks: `~/.cursor/cli-config.json` (global; `permissions.allow`/`permissions.deny` with tokens like `Shell(rm)`), `<project>/.cursor/cli.json` (permissions only), override dir `CURSOR_CONFIG_DIR`. [likely — official docs text quoted in search results: https://cursor.com/docs/cli/reference/configuration, https://cursor.com/docs/cli/reference/permissions]

### 3.2 Schema [verified]

```json
{
  "version": 1,
  "hooks": {
    "beforeShellExecution": [
      { "command": "./scripts/approve-network.sh", "timeout": 30, "matcher": "curl|wget|nc" }
    ],
    "stop": [ { "command": "./audit.sh", "loop_limit": 10 } ]
  }
}
```

- `version`: required positive integer (use `1`).
- Per entry: `command` (string, required: shell string, absolute or relative path), `type` (`"command"` default or `"prompt"`), `timeout` (seconds; default "platform default", unspecified), `loop_limit` (for `stop`/`subagentStop`; default 5 for Cursor hooks, `null` = unlimited for Claude-Code-format hooks), `failClosed` (bool, default `false`: when `true`, crash/timeout/non-zero exit/empty output block), `matcher` (regex; `""` or `"*"` = all).
- Entries are flat (no inner `hooks` array as in Claude Code). Adrafinil's comment confirms "Cursor uses a flatter shape than Claude (`{"command": …}` entries directly, no inner `hooks` wrapper) and a `version` field on a fresh file" (verified on Cursor 3.12.17). [verified: Adrafinil `CursorIntegration.swift`]
- Plugin hooks reference `${CURSOR_PLUGIN_ROOT}` (CC Safety Net's `hooks/cursor.json`). [verified]

### 3.3 Events [verified]

Agent hooks: `sessionStart`, `sessionEnd`, `preToolUse`, `postToolUse`, `postToolUseFailure`, `subagentStart`, `subagentStop`, `beforeShellExecution`, `afterShellExecution`, `beforeMCPExecution`, `afterMCPExecution`, `beforeReadFile`, `afterFileEdit`, `beforeSubmitPrompt`, `preCompact`, `stop`, `afterAgentResponse`, `afterAgentThought`. Tab hooks: `beforeTabFileRead`, `afterTabFileEdit`. App lifecycle: `workspaceOpen` ("runs in the Cursor desktop app and CLI").

### 3.4 Stdin payloads [verified unless noted]

Common fields on every agent hook:

```json
{
  "conversation_id": "string",
  "generation_id": "string",
  "model": "string",
  "model_id": "string",
  "model_params": [{ "id": "string", "value": "string" }],
  "hook_event_name": "string",
  "cursor_version": "string",
  "workspace_roots": ["<path>"],
  "user_email": "string | null",
  "transcript_path": "string | null"
}
```

`beforeShellExecution` adds:

```json
{ "command": "<full terminal command>", "cwd": "<current working directory>", "sandbox": false }
```

`afterShellExecution` adds `command`, `output`, `duration` (ms), `sandbox`.

`preToolUse` adds `tool_name`, `tool_input`, `tool_use_id`, `cwd`, `model`, `model_id`, `model_params`, `agent_message`. Tool names: `Shell`, `Read`, `Write`, `Grep`, `Delete`, `Task`, MCP tools as `MCP:<tool_name>`. For `Shell`: `"tool_input": {"command": "npm install", "working_directory": "/project"}`. `postToolUse` adds `tool_output` (JSON-stringified result, not raw terminal text), `duration`.

`sessionStart`: `session_id`, `is_background_agent`, `composer_mode` (`agent|ask|edit`, optional). `sessionEnd`: `session_id`, `reason` (`completed|aborted|error|window_close|user_close`), `duration_ms`, `is_background_agent`, `final_status`, `error_message` (optional). Relation of `session_id` to `conversation_id` is not documented. [unverified]

`workspaceOpen` carries only `hook_event_name`, `cursor_version`, `workspace_roots`, `user_email`.

### 3.5 Output, blocking, exit codes, timeouts [verified]

Permission hooks (`beforeShellExecution`, `beforeMCPExecution`, `beforeReadFile`, `beforeTabFileRead`, `subagentStart`, `preToolUse`):

```json
{ "permission": "allow" | "deny" | "ask", "user_message": "shown in client when denied", "agent_message": "sent to agent when denied" }
```

- `preToolUse` additionally accepts `updated_input`; `"ask"` is "accepted by the schema but not enforced for `preToolUse` today". `subagentStart` treats `ask` as `deny`. So use `beforeShellExecution` when "ask" matters.
- `sessionStart` output: `env` (vars for the session, visible to later hooks), `additional_context`; it "runs as fire-and-forget". `sessionEnd`, `afterFileEdit`, `afterAgentThought`: no output.
- Exit codes: `0` = use JSON; `2` = block (= `permission: deny`, Claude Code parity); other codes, crashes, timeouts fail open (logged) unless `failClosed: true`. For permission hooks, invalid JSON or a schema-mismatching response blocks the action even with `failClosed: false` — so a stray log line on stdout is a block. Empty stdout: the docs list "no output" only among the failures that `failClosed` turns into a block (i.e. fail-open by default) and do not say whether a permission hook treats it as "invalid JSON"; treat the outcome as [unverified] and always print a JSON object.
- Env given to hook scripts (docs table): `CURSOR_PROJECT_DIR` (primary), `CURSOR_VERSION`, `CURSOR_USER_EMAIL` (if logged in), `CURSOR_TRANSCRIPT_PATH` (if transcripts enabled), `CURSOR_CODE_REMOTE="true"` (remote workspaces), `CLAUDE_PROJECT_DIR` (alias). [verified]
- Timeout unit seconds; default undocumented. CC Safety Net sets `timeout: 30, failClosed: true`. [verified: `src/hosts/cursor/install.ts`]
- Hook commands "start 40x faster" since 2.4. Debug: Hooks tab under Customize and the "Hooks" output channel.
- Cloud agents: run command hooks only from `.cursor/hooks.json` (+ team/enterprise); user hooks unavailable; `sessionStart`/`sessionEnd`/MCP/tab/`workspaceOpen` hooks do not run; hooks start once the environment is writable.

### 3.6 Claude Code hooks compatibility ("third-party hooks") [verified]

Source: https://cursor.com/docs/reference/third-party-hooks (accessed 2026-10-16); changelog https://cursor.com/changelog/2-4 (2026-01-22): "Added compatibility with Claude Code hooks in the CLI", plus `PreToolUse`/`PostToolUse` hooks, `stop` hook, Team/MDM hooks in CLI. The Jan 8 and Jan 16 2026 CLI posts add "Hooks now execute in parallel with merged responses" and "Added hooks for session start/end, prompt, and stop". [verified: https://cursor.com/changelog/cli-jan-16-2026, https://forum.cursor.com/t/cursor-cli-jan-8-2026-new-commands-and-performance-improvement/148372]

- Files loaded (highest priority first): `.claude/settings.local.json`, `.claude/settings.json`, `~/.claude/settings.json`. Plugins are not mentioned as a separate source.
- Enabled by default: Cursor Settings → Agents → Third-Party Imports → "Include Third-Party Plugins, Skills, and Other Configs". Claude-format hooks rank below all native sources in conflict resolution.
- Event mapping: `PreToolUse`→`preToolUse`, `PostToolUse`→`postToolUse`, `Stop`→`stop`, `SubagentStop`→`subagentStop`, `SessionStart`→`sessionStart`, `SessionEnd`→`sessionEnd`, `PreCompact`→`preCompact`, `UserPromptSubmit`→`beforeSubmitPrompt`; `Notification` and `PermissionRequest` unsupported; `SubagentStart` only in native format.
- Matcher mapping: `Bash`→`Shell`, `Edit`→`Write`, `Read`/`Write`/`Grep`/`Task`/`WebFetch`/`WebSearch` unchanged, `Glob` unsupported.
- Output mapping: Claude `hookSpecificOutput.permissionDecision/permissionDecisionReason/updatedInput` → Cursor `permission/user_message/updated_input`; `Stop` `decision: "block"` + `reason` → `followup_message`; exit 2 = deny; other exit codes fail open.
- Not documented: the stdin payload a Claude-format hook receives (Cursor-native `preToolUse` shape vs. a translated Claude shape). CC Safety Net's Cursor adapter reads the Cursor-native shape (`tool_name: "Shell"`, `tool_input.command`, `workspace_roots`, `conversation_id`) and treats a Claude-plugin install as a duplicate route inside Cursor, which implies the payload is Cursor's. [likely] Must be verified empirically before Airbag relies on it.
- Whether the import works in the CLI: the changelog says yes for 2.4; the doc page does not distinguish IDE/CLI. [verified changelog / unverified per-event in CLI]

### 3.7 Cursor CLI specifics

- Binary: installer pins `$HOME/.local/share/cursor-agent/versions/2026.10.16-e3cb207/cursor-agent`, symlinks `~/.local/bin/agent` (primary) and `~/.local/bin/cursor-agent` (legacy); download `https://downloads.cursor.com/lab/<ver>/<darwin|linux>/<x64|arm64>/agent-cli-package.tar.gz`; version format `YYYY.MM.DD-<shorthash>`; auto-updates by default (`agent update`). [verified: https://cursor.com/install script, https://cursor.com/docs/cli/installation]
- The versions directory also ships a `node` binary which agent shells prepend to PATH (forum bug, staff-acknowledged); a "background node process running cursor-agent" is reported after exit. [likely: https://forum.cursor.com/t/cli-agent-prepends-bundled-node-onto-path/168848, https://forum.cursor.com/t/runaway-cpu-in-cursor-agent/133483]
- Hooks config is the same as the IDE (`.cursor/hooks.json`, `~/.cursor/hooks.json`). Event support per Cursor staff (deanrie) in https://forum.cursor.com/t/cursor-cli-doesnt-send-all-events-defined-in-hooks/148316 [verified]:
  - 2026-01-08/09 (thread opener was on CLI 2026.01.02-80e4d9b; staff name no version): "partial hook support" — only `beforeShellExecution` and `afterShellExecution` fire; `beforeSubmitPrompt`, `afterAgentResponse`, `afterFileEdit` listed as roadmap.
  - 2026-04-12: `beforeShellExecution`, `afterShellExecution`, `afterFileEdit`, `postToolUse`, `stop`, `sessionStart` work; `afterAgentResponse`/`afterAgentThought` do not.
  - 2026-05-10 / 06-07: unchanged; cloud agents fire no lifecycle hooks at all (tool-level hooks work).
  - `sessionEnd`, `preToolUse`, `beforeSubmitPrompt` in the CLI: not stated by staff. [unverified]
  - `-p`/print mode: a user asked specifically; staff pointed to `--output-format stream-json` as a workaround, implying hooks may not be a reliable channel in print mode. [unverified]
- A third-party integration guide claims current CLI builds require top-level `"version": 1` with direct command entries and that the nested matcher/hooks group shape does not fire in the CLI. [likely: https://docs.nvidia.com/nemo/relay/v0.4.0/nemo-relay-cli/cursor]
- CLI chat storage: `~/.cursor/chats/<workspace-hash>/<chat-uuid>/` (staff reply), scoped per working directory; IDE transcripts `~/.cursor/projects/<project>/agent-transcripts/`; IDE/CLI histories do not sync. [likely: https://forum.cursor.com/t/cursor-agent-create-chat-and-how-to-delete-old-chats/156640, https://forum.cursor.com/t/unified-chat-store-across-ide-cli-acp-mode/159335]
- Permissions unified with the editor in 2.4: "Run Everything", "Auto-Run in Sandbox", "Ask Every Time (allowlist)"; by 3.5 the modes are Auto-review (default), Allowlist, Run Everything ("Ask Every Time" deprecated). [verified: changelog 2.4; https://cursor.com/docs/agent/security/run-modes]

### 3.8 How the Cursor agent spawns shell processes (attribution)

IDE:
- Parent of agent shells is the extension host: `Cursor Helper (Plugin): extension-host (agent-exec) <workspace>`; children are `/bin/zsh` running Cursor's wrapper `snap=$(command cat <&3); …; dump_zsh_state` (the wrapper reads a saved shell snapshot from fd 3 and dumps zsh state afterwards). Observed on Cursor 3.13.21, macOS 26.5.2 (July 2026), reproduced by staff. [verified: https://forum.cursor.com/t/orphaned-agent-exec-gh-shell-storm-maxes-cpu-after-plan-mode-multi-root/166863]
- The agent shell is a "bare zsh eval" that restores a saved zsh environment (staff: "a bug in how Agent Shell restores the saved zsh environment when it starts with a broken PATH", 3.12.29, fix in 3.14). [verified: https://forum.cursor.com/t/agent-shell-tool-runs-with-empty-path-basic-unix-commands-fail-command-not-found-tr-wasting-tokens/166316]
- The user-facing integrated terminal is spawned by `Cursor Helper: terminal pty-host` (chain Terminal process → pty-host → Cursor.app). [likely: forum]
- Env markers: `CURSOR_AGENT` is documented ("indicates a Cursor session"; used in `.zshrc` to skip p10k). [verified: https://cursor.com/docs/agent/terminal] `CURSOR_TRACE_ID` (also present in the regular Cursor terminal, so not agent-specific), `COMPOSER_NO_INTERACTION=1` (agent only), `PAGER` set only in agent mode, `TERM_PROGRAM=vscode` (not `cursor`). [likely: forum threads 96808, 37734, 101502]
- Sandbox (macOS Seatbelt via `sandbox-exec`, Cursor ≥2.0): child processes get `CURSOR_SANDBOX=seatbelt` (`native` on Linux), `CURSOR_ORIG_UID`, `CURSOR_ORIG_GID`; workspace read/write, `/tmp` writable unless disabled, protected paths `.git/config`, `.git/hooks`, `.vscode`, `.cursorignore`; config `~/.cursor/sandbox.json` and `<project>/.cursor/sandbox.json`; network modes "sandbox.json Only", "sandbox.json + Defaults" (default), "Allow All". [verified: run-modes doc]
- `beforeShellExecution` payload field `sandbox: true|false` tells the hook whether the command will be sandboxed. [verified]

CLI: `agent` → `cursor-agent` binary (+ bundled `node`) spawns the user's shell for commands; exact spawn chain not documented. [unverified]

### 3.9 Worktrees

- Fixed base path `~/.cursor/worktrees`, no setting to change it (staff deanrie, 2026-01-18: "Cursor uses a fixed path: `~/.cursor/worktrees`"; 2026-05-18: "still hardcoded … no customization yet"). [verified: https://forum.cursor.com/t/configure-worktree-location/149222]
- Subdirectory layout observed by users: `~/.cursor/worktrees/<repo>/<branch-or-random-suffix>`; agent branches look like `cursor/23283375`. [unverified: forum user reports]
- Docs (Cursor 3.5+): cleanup runs on an interval and keeps the newest worktrees up to a machine-wide cap; `cursor.worktreeMaxCount` (default 25 per machine), `cursor.worktreeCleanupIntervalHours` (example 6); exceeding the cap triggers immediate cleanup; worktrees created outside Cursor (`git worktree add`, `/worktree` skills) are eligible for deletion; `/apply-worktree` brings changes back, `/delete-worktree` removes; `/best-of-n` compares runs. Staff in March 2026 said "default ~20", "session-scoped sandboxes for parallel agents", "aren't meant to persist across sessions". [verified: https://cursor.com/docs/configuration/worktrees; https://forum.cursor.com/t/working-with-worktrees-in-cursor/153472]
- Setup script config `.cursor/worktrees.json` (looked up in the worktree, then the project root): keys `setup-worktree-unix`, `setup-worktree-windows`, `setup-worktree`; array of commands run sequentially in the worktree or a script path; env `ROOT_WORKTREE_PATH`; applies to Agents Window, IDE and CLI. [verified]
- Users report 9.8 GB of auto-created worktrees in 20 minutes (market report) and 22 worktrees in a week. [likely]

### 3.10 Airbag hook config for Cursor (user level, `~/.cursor/hooks.json`)

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      { "command": "/Applications/Airbag.app/Contents/MacOS/airbag hook cursor", "timeout": 5 }
    ],
    "sessionEnd": [
      { "command": "/Applications/Airbag.app/Contents/MacOS/airbag hook cursor", "timeout": 5 }
    ],
    "beforeShellExecution": [
      { "command": "/Applications/Airbag.app/Contents/MacOS/airbag hook cursor", "timeout": 20, "failClosed": false }
    ],
    "afterShellExecution": [
      { "command": "/Applications/Airbag.app/Contents/MacOS/airbag hook cursor", "timeout": 5 }
    ]
  }
}
```

Notes: use `beforeShellExecution` (not `preToolUse`) so `ask` is enforced and because it is the one event that fired in the CLI from day one; always print `{"permission":"allow"}` on the allow path (invalid JSON blocks; the effect of empty stdout is undocumented); write the absolute binary path at install time (user hooks run with cwd `~/.cursor/`, and PATH may not include Homebrew); keep `failClosed: false` for the snapshot path and implement the breaker's deny explicitly. Deny shape: `{"permission":"deny","user_message":"<localized>","agent_message":"<English rationale>"}`; ask shape identical with `"ask"`.

## 4. Gemini CLI

### 4.1 Config files and precedence [verified]

Source: `docs/hooks/index.md` (repo head 2026-10-16; https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/index.md). Precedence (highest first): project `.gemini/settings.json` → user `~/.gemini/settings.json` → system `/etc/gemini-cli/settings.json` → extensions. The enterprise doc gives the macOS system path as `/Library/Application Support/GeminiCli/settings.json` (Linux `/etc/gemini-cli/settings.json`), overridable with `GEMINI_CLI_SYSTEM_SETTINGS_PATH`. [verified: `docs/cli/enterprise.md`] Settings toggles: `hooksConfig.enabled` (default `true`), `hooksConfig.notifications` (default `true`). [verified: `docs/cli/settings.md`] Runtime commands: `/hooks panel`, `/hooks enable-all|disable-all`, `/hooks enable|disable <name>`. CC Safety Net installs via an extension instead (`~/.gemini/extensions/gemini-safety-net`, enablement in `~/.gemini/extensions/extension-enablement.json`). [verified: `src/hosts/gemini-cli/detect.ts`]

### 4.2 Schema [verified]

```json
{
  "hooks": {
    "BeforeTool": [
      {
        "matcher": "run_shell_command",
        "sequential": false,
        "hooks": [
          { "name": "airbag", "type": "command", "command": "/Applications/Airbag.app/Contents/MacOS/airbag hook gemini", "timeout": 20000, "description": "Airbag snapshot + circuit breaker" }
        ]
      }
    ]
  }
}
```

Hook definition: `matcher` (regex for tool events, exact string for lifecycle events; `*`/`""` = all), `sequential` (bool), `hooks[]`. Hook configuration: `type` (only `"command"`), `command`, `name`, `timeout` (ms, default 60000), `description`. Only `"command"` type exists (no prompt/http hooks). `$GEMINI_PROJECT_DIR`, `$GEMINI_CWD`, `$GEMINI_PLANS_DIR`, `$GEMINI_SESSION_ID`, `$CLAUDE_PROJECT_DIR` are expanded inside `command`. [verified: `hookRunner.ts` `expandCommand`]

### 4.3 Events [verified]

`SessionStart`, `SessionEnd`, `BeforeAgent`, `AfterAgent`, `BeforeModel`, `AfterModel`, `BeforeToolSelection`, `BeforeTool`, `AfterTool`, `PreCompress`, `Notification` (`types.ts` enum matches docs). Hooks run synchronously; the CLI waits for all matching hooks.

### 4.4 Stdin, tool names, shell tool fields [verified]

Base input on every hook: `session_id`, `transcript_path` (absolute path to the session JSONL), `cwd`, `hook_event_name`, `timestamp` (ISO 8601).

`BeforeTool` adds `tool_name`, `tool_input` (raw model args), `mcp_context`, `original_request_name`. `AfterTool` adds `tool_response` (`llmContent`, `returnDisplay`, `error`). Matchers compare against built-in names (`run_shell_command`, `read_file`, `write_file`, `replace`, …) or `mcp_<server>_<tool>`.

`run_shell_command` parameters (`docs/tools/shell.md`): `command` (required), `description`, `dir_path` (absolute or relative to workspace root), `is_background` (bool). The subprocess gets `GEMINI_CLI=1` in its environment.

`SessionStart` input `source`: `startup|resume|clear`. `SessionEnd` input `reason`: `exit|clear|logout|prompt_input_exit|other`. `Notification` input `notification_type: "ToolPermission"`, `message`, `details` — observability only, cannot grant.

### 4.5 Output, blocking, exit codes, env [verified]

Common output: `systemMessage` (shown to user), `suppressOutput`, `continue` (false = stop whole agent loop), `stopReason`, `decision` (`allow` | `deny`, alias `block`), `reason`.

`BeforeTool`: `decision: "deny"` + `reason` (sent to the agent as a tool error; the turn continues); `hookSpecificOutput.tool_input` merges over the model's args; exit code 2 blocks with stderr as reason. `ask`: not in `docs/hooks/reference.md`, but the source at head `ed96fae` accepts `decision: "ask"` (`HookDecision` union in `types.ts`; `isAskDecision()` in `hookAggregator.ts`, where deny beats ask beats allow; `scheduler/hook-utils.ts` returns `hookDecision: 'ask'` and `scheduler/scheduler.ts` then forces `PolicyDecision.ASK_USER` → confirmation prompt). [verified: source; undocumented, behaviour in non-interactive mode and in the released npm version unverified] `SessionStart`: `continue`/`decision` ignored, startup never blocked; `hookSpecificOutput.additionalContext` injected (interactive: first history turn; non-interactive: prepended to the prompt — so hooks do run in `gemini -p`). `SessionEnd`: the CLI "will not wait for this hook to complete" and ignores flow control. `PreCompress`: async, advisory.

Exit codes per docs: `0` parse stdout JSON (preferred even for denies); `2` block, stderr = reason; other = warning, proceeds with original params. "Silence is Mandatory": any non-JSON on stdout → parse failure → CLI defaults to Allow and shows the output as `systemMessage`. Timeout default 60 000 ms (`DEFAULT_HOOK_TIMEOUT`), timed-out hook is killed (process tree on Windows).

What the source actually does (`hookRunner.ts` `executeCommandHook` / `convertPlainTextToHookOutput`, head `ed96fae`) [verified: source]: `textToParse = stdout.trim() || stderr.trim()` — when stdout is empty, **stderr is parsed instead** (the docs' "never attempts to parse stderr" is wrong). If the text is valid JSON it is used as the hook output regardless of exit code (so exit 2 + `{"decision":"allow"}` on stdout = allow). If the text is not JSON: exit 0 → `allow` + text as `systemMessage`; exit 1 → `allow` + `Warning: <text>`; **any other non-zero exit (2, 3, 137, …) → `deny` with the text as `reason`**. Non-zero exit with no output at all → no decision (proceeds) plus a "Hook(s) [name] failed" warning in the UI. Consequence for Airbag: the allow path must print `{}` on stdout; a hook that prints nothing on stdout but logs to stderr will have its log shown as `systemMessage` (exit 0) or turned into a deny (exit ≥2).

Execution (`hookRunner.ts`): `spawn(shellConfig.executable, [...argsPrefix, command], {cwd: input.cwd, shell:false})` with env = sanitized `process.env` + `GEMINI_PROJECT_DIR`, `GEMINI_PLANS_DIR`, `GEMINI_CWD`, `GEMINI_SESSION_ID`, `CLAUDE_PROJECT_DIR` + per-hook `env`; JSON written to stdin. So the hook's parent process is the shell (`bash -c`), whose parent is the `gemini` node process.

### 4.6 Trust model [verified]

Project hooks are fingerprinted per project as `name:command` in `~/.gemini/trusted_hooks.json`; new/changed project hooks trigger a one-time warning ("These hooks will be executed. If you did not configure these hooks or do not trust this project…") and are then trusted; only evaluated in trusted folders. User-level hooks are not fingerprinted. Airbag should install at user level.

### 4.7 Attribution facts

- Process: `gemini` is a Node program (npm `@google/gemini-cli`, Homebrew formula `gemini-cli`); shell commands run with `GEMINI_CLI=1`. [verified env; packaging likely]
- Session transcripts: `~/.gemini/tmp/<project_name>/chats/session-<YYYY-MM-DDTHH-MM>-<8hex>.jsonl` (`getProjectTempDir()/chats`), project names mapped in `~/.gemini/projects.json` (`{"projects": {"/Users/…": "<name>"}}`); sub-agent transcripts are nested as `chats/<parentSessionId>/<sessionId>.jsonl` (`chatRecordingService.ts`). Confirmed on this machine: `~/.gemini/tmp/alnurkengesbay/chats/session-2026-06-14T19-03-0e8e9f10.jsonl` (7.7 MB for one 20-minute session). [verified: local + `chatRecordingService.ts`]
- Local `~/.gemini/settings.json` here contains only `security.auth.selectedType`; no hooks. [verified]

### 4.8 Airbag hook config for Gemini (user level, merged into `~/.gemini/settings.json`)

```json
{
  "hooks": {
    "SessionStart": [
      { "matcher": "*", "hooks": [ { "name": "airbag-session", "type": "command", "command": "/Applications/Airbag.app/Contents/MacOS/airbag hook gemini", "timeout": 5000 } ] }
    ],
    "SessionEnd": [
      { "matcher": "*", "hooks": [ { "name": "airbag-session", "type": "command", "command": "/Applications/Airbag.app/Contents/MacOS/airbag hook gemini", "timeout": 5000 } ] }
    ],
    "BeforeTool": [
      { "matcher": "run_shell_command", "hooks": [ { "name": "airbag-breaker", "type": "command", "command": "/Applications/Airbag.app/Contents/MacOS/airbag hook gemini", "timeout": 20000, "description": "Airbag: project snapshot and destructive-command breaker" } ] }
    ],
    "AfterTool": [
      { "matcher": "run_shell_command", "hooks": [ { "name": "airbag-after", "type": "command", "command": "/Applications/Airbag.app/Contents/MacOS/airbag hook gemini", "timeout": 5000 } ] }
    ]
  }
}
```

Allow: print `{}` (or `{"decision":"allow"}`), exit 0. Deny: `{"decision":"deny","reason":"<English, goes to the model>","systemMessage":"<localized, shown to user>"}`, exit 0. "ask" is undocumented (source-only, §4.5): do not rely on it until probed on an installed release; Airbag's "ask" rules should degrade to deny-with-explanation (the model can retry after the user adjusts) or to allow+snapshot, with `{"decision":"ask"}` as an opt-in once verified. Keep all logging on stderr, and always print JSON on stdout (empty stdout makes Gemini parse stderr, §4.5).

## 5. GitHub Copilot CLI

### 5.1 Config files and precedence [verified]

Source: https://docs.github.com/en/copilot/reference/hooks-reference and https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-hooks-reference (accessed 2026-10-16). Sources are combined (the CLI reference states the order as policy → user → repository → plugins, but its own list runs policy, repo files, user files, repo inline, user inline, plugins; every matching entry runs, so order only matters for logging). `~/.copilot/config.json` is no longer read for hooks (it was accepted in 1.0.8).

| Level | Path |
|---|---|
| Policy (admin) | `/etc/github-copilot/policy.d/*.json` (macOS/Linux), `C:\ProgramData\GitHub\Copilot\policy.d\*.json`, registry `HKLM\Software\Policies\GitHub\Copilot` |
| Repository | `.github/hooks/*.json`; inline `hooks` in `.github/copilot/settings.json`, `.github/copilot/settings.local.json`, `.claude/settings.json`, `.claude/settings.local.json` |
| User | `~/.copilot/hooks/*.json` (or `$COPILOT_HOME/hooks/`); inline `hooks` in `~/.copilot/settings.json` |
| Plugins | `hooks.json` or `hooks/hooks.json` in the plugin dir (`~/.copilot/installed-plugins/<marketplace>/<plugin>/`) |

Cloud coding agent loads only `.github/hooks/*.json`. `disableAllHooks: true` in a file skips that file; in `settings.json` it skips everything except policy hooks. Repo hooks load in `-p` mode when the folder is trusted (1.0.49). Hook commands without explicit `cwd` run in the project root. `allowManagedHooksOnly` enterprise policy exists. [verified: changelog]

### 5.2 Schema [verified]

```json
{
  "version": 1,
  "disableAllHooks": false,
  "hooks": {
    "preToolUse": [
      { "type": "command", "bash": "./scripts/pre.sh", "powershell": "./scripts/pre.ps1", "cwd": ".github/hooks", "env": {"X": "1"}, "timeoutSec": 30 }
    ]
  }
}
```

Fields: `type` = `command` (default) | `http` | `prompt`; `bash`/`powershell`/`command` (cross-platform fallback); `exec` + `args` (CLI only, runs the executable directly with no shell, so no pipes/redirection; do not combine with shell fields); `cwd`; `env` (with expansion); `timeoutSec` (default 30; `timeout` alias); `matcher` (regex on some events; since 1.0.36 "hooks with matcher run only for tool names that fully match the regex"). HTTP hooks need `https://` for `preToolUse`/`permissionRequest` (`http://localhost` only with `COPILOT_HOOK_ALLOW_LOCALHOST=1`). Prompt hooks only on `sessionStart`, not on resume or `-p`. The CLI also accepts Claude Code's nested `matcher`/`hooks` structure, PascalCase event names and files without `version` (1.0.5/1.0.6). [verified: changelog]

### 5.3 Events [verified]

| Event | Can block / change | Cloud agent |
|---|---|---|
| `sessionStart` | no; `additionalContext` | once |
| `sessionEnd` | no | once |
| `userPromptSubmitted` | `modifiedPrompt` (SDK hooks only) | once |
| `userPromptTransformed` | rewrite model-facing content | yes |
| `preToolUse` | allow / deny / ask / `modifiedArgs` | yes, `ask`→deny |
| `permissionRequest` | allow / deny | CLI only |
| `postToolUse` | `modifiedResult`, `additionalContext` | yes |
| `postToolUseFailure` | `additionalContext` | yes |
| `agentStop` | `decision: block` forces another turn (max 8) | yes |
| `subagentStart` | context only | yes |
| `subagentStop` | block / `modifiedResponse` | yes |
| `errorOccurred` | no | yes |
| `preCompact` | no | auto only |
| `notification` | fire-and-forget | CLI only |

Semantics that matter for a session registry: interactive sessions fire `sessionStart`/`sessionEnd` once per session (1.0.22); `/clear` fires `sessionEnd` (1.0.85); in `-p` and piped-stdin runs `sessionEnd` fires once per completed agent turn with `reason: complete|error` and not at shutdown (1.0.78, 1.0.92). `sessionStart.source` ∈ `startup|resume|new`; `sessionEnd.reason` ∈ `complete|error|abort|timeout|user_exit`. [verified]

### 5.4 Stdin payloads [verified]

Two formats chosen by the event-name casing in the config: camelCase events get camelCase fields and a numeric millisecond `timestamp`; PascalCase events (`PreToolUse`, VS Code / Claude compatible) get snake_case fields, `hook_event_name`, ISO `timestamp`, `tool_name`, `tool_input` (1.0.21). Every event has `sessionId`/`session_id`, `timestamp`, `cwd`; `traceparent` since the OpenTelemetry addition.

`preToolUse` (camelCase): `sessionId`, `timestamp`, `cwd`, `toolName`, `toolArgs`. Shell tool names: `bash` (Unix), `powershell` (Windows); others `view`, `create`, `edit`, `glob`, `grep`, `web_fetch`, `task`, `ask_user`. The official tutorial parses `toolArgs` as a JSON *string* (`jq -r '.toolArgs'` then `jq -r '.command'`), while CC Safety Net accepts both an object and a string — so Airbag must handle both. The CLI reference types `toolArgs` as `unknown` and describes the PascalCase `tool_input` as "parsed from JSON string when possible", which supports the string hypothesis. [verified: reference] [verified: https://docs.github.com/en/copilot/tutorials/copilot-cli-hooks; `src/hosts/copilot-cli/hook.ts`] Field for the shell command: `toolArgs.command`. Delivery is on stdin (`INPUT="$(cat)"` in the tutorial).

### 5.5 Output, blocking, exit codes, timeouts [verified]

`preToolUse` stdout: `{"permissionDecision": "allow"|"deny"|"ask", "permissionDecisionReason": "…", "modifiedArgs": {…}}`; empty output = default behavior; `permissionDecisionReason` required for `deny`; `ask` becomes `deny` in cloud agent and in CLI autopilot mode (1.0.97, 2026-10-13: "Autopilot denies a preToolUse hook's 'ask' decision instead of stopping on a permission dialog nobody is watching"). `permissionRequest` output: `behavior`, `message`, `interrupt`. `sessionStart`: `additionalContext` (joined with blank lines; capped). Output capped at 10 MiB; `{"type":"progress",…}` lines are stripped before parsing.

Exit codes (command hooks): `0` parse JSON; `2` = deny for `preToolUse`/`permissionRequest` even if stdout says allow (1.0.70); other non-zero: most events fail open, but `preToolUse` fails closed with "Denied by preToolUse hook (hook errored)" (1.0.57); timeout (default 30 s) kills the hook and fails open for every event including `preToolUse`. A user denial from the hook prompt reaches the model as "Denied by user via preToolUse hook prompt: <reason>".

### 5.6 Version timeline (from `changelog.md`, github/copilot-cli, head 2026-10-14) [verified]

0.0.396 (2026-01-27) `preToolUse` can deny and modify args · 0.0.401 (02-03) `agentStop`/`subagentStop` · 0.0.421 (03-03) `COPILOT_CLI=1` env in subprocesses · 0.0.422 (03-05) `~/.copilot/hooks` personal hooks · 1.0.4 (03-11) `ask` decision, `disableAllHooks` · 1.0.5 (03-13) files without `version` accepted · 1.0.6 (03-16) PascalCase names + Claude nested structure · 1.0.8 (03-18) inline hooks in `settings.json`/`settings.local.json`/`config.json` · 1.0.10 (03-20) repo hooks fire in `-p` · 1.0.21 (04-07) PascalCase payloads snake_case · 1.0.22 (04-09) session hooks once per session · 1.0.36 (04-24) `preToolUse.matcher` honored · 1.0.57 (06-01) hook errors deny · 1.0.62 (06-13) Claude-format plugin hooks carry Claude tool names · 1.0.66 (06-30) inline nested Claude-style groups handled · 1.0.70 (07-09) exit 2 denies · 1.0.78 (08-03) piped-stdin `sessionEnd` per turn · 1.0.85 (09-16) `sessionEnd` on `/clear` · 1.0.92 (10-05) single `sessionEnd` in prompt mode · 1.0.97 (10-13) autopilot `ask`→deny, agent-scoped hooks · 1.0.98 (10-14) "Command hooks complete reliably even when child-exit signals are lost under Node". Inline hooks in settings files require ≥1.0.8 (CC Safety Net version gate). [likely]

### 5.7 Attribution facts

- Install: `brew install copilot-cli` or `npm install -g @github/copilot`; `COPILOT_HOME` overrides `~/.copilot` (`--config-dir` deprecated). [verified: README, changelog]
- Subprocesses of shell commands carry `COPILOT_CLI=1`. CC Safety Net uses `COPILOT_CLI === '1'` inside a Claude-format hook to recognise it is running under Copilot (tool name `Bash`), which implies hook processes also see it. [verified env / likely for hooks]
- Session storage: `~/.copilot/session-state/<session-id>/` with `events.jsonl` (full history), `workspace.yaml` (metadata), `plan.md`, `checkpoints/`, `files/`; legacy `~/.copilot/history-session-state`; `/session id` prints the id; `--resume` accepts 7+ hex prefix. [verified: https://docs.github.com/en/copilot/how-tos/copilot-cli/cli-best-practices; changelog]
- Local machine: `~/.copilot/config.json` (131 bytes, "This file is managed automatically", user settings belong in `settings.json`), `~/.copilot/logs/process-<ts>-<pid>.log`; the log from 2026-09-29 says "Starting CLI in stdio mode (Rust JSON-RPC engine)", so the engine may now be a native process rather than node — relevant for process-name matching. [verified local; engine packaging unverified]
- CC Safety Net's Copilot route is a plugin (`cc-safety-net@cc-marketplace` in `~/.copilot/installed-plugins/cc-marketplace/cc-safety-net`, switch `enabledPlugins` in settings) or hook files in any of the §5.1 locations. [verified]

### 5.8 Airbag hook config for Copilot CLI (own file `~/.copilot/hooks/airbag.json`)

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      { "type": "command", "exec": "/Applications/Airbag.app/Contents/MacOS/airbag", "args": ["hook", "copilot"], "timeoutSec": 5 }
    ],
    "sessionEnd": [
      { "type": "command", "exec": "/Applications/Airbag.app/Contents/MacOS/airbag", "args": ["hook", "copilot"], "timeoutSec": 5 }
    ],
    "preToolUse": [
      { "type": "command", "matcher": "bash|powershell", "exec": "/Applications/Airbag.app/Contents/MacOS/airbag", "args": ["hook", "copilot"], "timeoutSec": 20 }
    ],
    "postToolUse": [
      { "type": "command", "matcher": "bash|powershell", "exec": "/Applications/Airbag.app/Contents/MacOS/airbag", "args": ["hook", "copilot"], "timeoutSec": 5 }
    ]
  }
}
```

`exec`/`args` avoids a shell and is CLI-only (fine: user-level hooks never reach the cloud agent). If `exec` turns out unsupported in an older build, fall back to `"bash": "/Applications/Airbag.app/Contents/MacOS/airbag hook copilot"`. Placement of `matcher` on the entry is per the reference's field list; verify on a real install. [likely] Allow: print `{}`; deny: `{"permissionDecision":"deny","permissionDecisionReason":"<English>"}`; ask: `"ask"` (knowing autopilot turns it into deny). Because a hook *error* denies, Airbag must never crash in this hook: catch everything and print `{}`.

## 6. What the two installers teach (CC Safety Net 2.6.12, Adrafinil 2026-10-14)

| Agent | CC Safety Net | Adrafinil |
|---|---|---|
| Claude Code | plugin `cc-safety-net@cc-marketplace`, `hooks/hooks.json` nested `PreToolUse` → `node ${CLAUDE_PLUGIN_ROOT}/dist/bin/cc-safety-net.js hook --coding-cli`; detects `installed_plugins.json` + `enabledPlugins` in `~/.claude/settings.json`; `CLAUDE_CONFIG_DIR` honoured | `~/.claude/settings.json` nested; `UserPromptSubmit`→acquire, `Stop`→release, `Notification` matcher `idle_prompt`, `SubagentStart/Stop` keyed on `agent_id`, `SessionEnd`, `SessionStart` matcher `clear`; env `CLAUDE_CODE_SESSION_ID` (not `CLAUDE_SESSION_ID`); Esc-interrupt fires no `Stop` |
| Cursor | `~/.cursor/hooks.json` (user only), `preToolUse` flat entry `{command:"npx -y cc-safety-net hook --cursor", timeout:30, failClosed:true}`; alt route: Cursor plugin marketplace (`~/.cursor/plugins/…`, `cursor-agent plugin marketplace remove`); adapter reads `tool_name:"Shell"`, `tool_input.command/working_directory`, `workspace_roots`, `conversation_id`; notes Cursor may run the Claude plugin too (double check) | `~/.cursor/hooks.json` flat, `beforeSubmitPrompt`→acquire with 1 h TTL, `stop`→release; "No `CURSOR_SESSION_ID` env var exists — Cursor passes `session_id` on the hook's stdin"; chats are long-lived so session-scoped holds were wrong |
| Gemini CLI | extension `~/.gemini/extensions/gemini-safety-net`; `BeforeTool` on `run_shell_command`, cwd from `tool_input.dir_path`; output `{decision:"deny", reason, systemMessage}`; session id `session_id` | `~/.gemini/settings.json` nested, `SessionStart`→acquire, `SessionEnd`→release; no session-id env var |
| Copilot CLI | plugin `cc-safety-net@cc-marketplace` in `~/.copilot/installed-plugins/`, or hook files (`.github/hooks`, `~/.copilot/hooks`, inline settings incl. `.claude/settings.json`); tools `bash|Bash|powershell|PowerShell`; `toolArgs` object or JSON string; output `{permissionDecision:"deny", permissionDecisionReason}`; version gates 0.0.422 (user hooks), 1.0.8 (inline) | not supported |
| Codex | `hooks/codex.json` nested `PreToolUse`, `${PLUGIN_ROOT}` | `~/.codex/hooks.json` nested (flat form silently ignored); `UserPromptSubmit`→acquire (`SessionStart` does not fire on resume), `Stop`→release; hooks do NOT run in `codex exec`; each handler must be trusted via `/hooks` (`trusted_hash` in `config.toml`); env `CODEX_THREAD_ID` |

Shared practices [verified in source]: atomic writes; parse-validate-merge preserving foreign entries; identify own entries by command string (CCSN) or a private key `_adrafinil: true` (Adrafinil; Cursor/Gemini tolerate the unknown key); canonicalise on reinstall (collapse duplicates, repair `timeout`/`failClosed`); uninstall removes only own handlers and drops empty event arrays; "doctor" command that reports drift and duplicate routes (e.g. hook installed both natively and via Claude import). CCSN keeps the Cursor hook `failClosed: true` with a 30 s timeout because a safety gate must not fail open; Airbag's snapshot step should not inherit that (see §8).

## 7. Compatibility matrix (local agents, Oct 2026)

| Agent / surface | Before-shell block | "Ask" | Session start | Session end | After-shell | Notes |
|---|---|---|---|---|---|---|
| Cursor IDE | yes (`beforeShellExecution`, `preToolUse`) | yes on `beforeShellExecution`; not enforced on `preToolUse` | yes (fire-and-forget) | yes (`reason`, `duration_ms`) | yes | Claude-format hooks also imported |
| Cursor CLI `agent` | yes (`beforeShellExecution`, since 2026-01) | likely (same event) [unverified] | yes (since 2026-04) | not confirmed [unverified] | yes | `-p` mode unclear |
| Cursor Cloud/background agents | yes | ? | no | no | yes | user hooks not loaded |
| Gemini CLI | yes (`BeforeTool` + `run_shell_command`) | undocumented `decision: ask` in source [unverified on release] | yes (advisory; also `resume`/`clear`) | yes but best-effort, not awaited | yes (`AfterTool`) | hooks also run in `-p` |
| Copilot CLI interactive | yes (`preToolUse` + `bash`) | yes (autopilot → deny) | yes (`startup|resume|new`) | yes (`/clear` too) | yes | hook error = deny, timeout = allow |
| Copilot CLI `-p` / piped | yes | → deny in autopilot | yes | per completed turn, `complete|error` | yes | |
| Claude Code (reference) | yes (`PreToolUse`/`Bash`) | yes | yes | yes | yes (`PostToolUse`) | see doc 02 |
| Codex (reference, from Adrafinil) | `PreToolUse` in TUI only | ? | `SessionStart` new sessions only | `Stop` per turn | ? | no hooks in `codex exec`; trust prompt per handler |

## 8. What this means for Airbag

1. **One hook binary, three native installers, zero reliance on Claude-import.** Install `~/.cursor/hooks.json` (merge), `~/.gemini/settings.json` (merge under `hooks`), `~/.copilot/hooks/airbag.json` (own file, no merge). Never write project-level hooks: Gemini warns and fingerprints them, Copilot and Cursor require trusted workspaces, and they would be committed. Install state must be verifiable ("doctor") and removable by command string match.
2. **Expect the same shell command to reach `airbag hook` more than once.** Cursor imports `~/.claude/settings.json` hooks by default and Copilot imports repo-level `.claude/settings.json`. If Airbag also installs Claude Code hooks (doc 02), a Cursor shell command can trigger Airbag twice (native `beforeShellExecution` + imported `preToolUse`). Mitigations: (a) the registry dedupes snapshots by `(project, normalized command, 3 s window)`; (b) the Claude-format entry checks for a Cursor-shaped payload (`cursor_version`, camelCase `hook_event_name`) and exits `{"permission":"allow"}` immediately when a native Cursor install is recorded; (c) `doctor` reports the duplicate route like CCSN does.
3. **Agent detection must not trust `CLAUDE_PROJECT_DIR`.** Cursor and Gemini both set it as an alias. Detect by payload shape first (table in §2), then by env (`GEMINI_SESSION_ID`, `COPILOT_CLI=1`, `CURSOR_AGENT`), and take the explicit `airbag hook <agent>` argument as the declared source; log a mismatch rather than guessing.
4. **Output discipline is a correctness requirement.** Cursor blocks on invalid JSON from permission hooks regardless of `failClosed` (empty stdout: undocumented); Gemini treats any stray stdout as parse failure (allows but spams the user), parses stderr when stdout is empty, and converts non-JSON output with exit ≥2 into a deny; Copilot denies on hook crash. Therefore: single JSON object on stdout, everything else on stderr, global panic handler that prints the allow shape, exit 0 on every non-deny path, and a unit test per agent for "empty input", "malformed JSON", "unknown event".
5. **Latency budget.** Hard limits: Copilot 30 s (then allow), Gemini 60 s (then warning+allow), Cursor undocumented (set 20 s explicitly). Target the pre-shell hook at <300 ms p50 / <2 s p95 on a 50k-file repo: rule evaluation first (microseconds), then snapshot via a persistent hidden git index primed by the GUI's FSEvents watcher (so the hook mostly does `write-tree` + `commit-tree` + `update-ref`), with a wall-clock cap after which the command is allowed and the miss is logged. Never block a command because the snapshot was slow; only the breaker denies.
6. **"Ask" is a second-class citizen everywhere except Cursor `beforeShellExecution`, Copilot interactive and Claude Code.** Gemini's ask is undocumented (source-only); Copilot autopilot and Cursor `preToolUse` degrade ask→deny. Airbag's rule engine needs a per-agent "ask fallback" setting (default: deny with an explanation that tells the model how the user can approve: e.g. run it manually or whitelist in Airbag).
7. **Session registry schema.** Keys: `(agent, session_id)` where session_id = Cursor `conversation_id`, Gemini `session_id`, Copilot `sessionId`. Store `cwd`, `workspace_roots`, `transcript_path` (Cursor/Gemini) or derived path (`~/.copilot/session-state/<id>/`), first/last seen, `is_background_agent`/`sandbox` flags, and the **agent process PID learned at hook time** by walking the hook's ancestor chain (`getppid` → `proc_pidinfo(PROC_PIDTBSDINFO)`): Gemini chain is `airbag ← sh/bash ← node(gemini)`; Cursor IDE chain ends in `Cursor Helper (Plugin): extension-host (agent-exec) …` → `Cursor`; Cursor CLI in `cursor-agent`/`node`; Copilot in `copilot` (node or Rust engine). This is the only moment a hook can tie a session id to a PID — the GUI's libproc poller then owns the PID→listening-socket attribution. Session end: Cursor `sessionEnd`, Copilot `sessionEnd`, Gemini `SessionEnd` best-effort — so the GUI must also retire sessions when the recorded PID dies.
8. **Radar attribution without hooks (and after the session dies).** Dev servers spawned by agents inherit env: `CURSOR_AGENT` (+`CURSOR_SANDBOX=seatbelt`, `COMPOSER_NO_INTERACTION=1`), `GEMINI_CLI=1`, `COPILOT_CLI=1`, Claude Code's own marker (doc 02). On macOS the environment of a same-uid process is readable via `sysctl KERN_PROCARGS2` without Full Disk Access or root [likely — standard libproc/sysctl behaviour, to be confirmed in the SwiftPM probe]. Reading it for listening PIDs lets the radar say "spawned by Gemini CLI" even for an orphan reparented to launchd, and combine with cwd (`PROC_PIDVNODEPATHINFO`) to map to a project/worktree. Caveat: `CURSOR_TRACE_ID` also appears in Cursor's normal terminal; use `CURSOR_AGENT`/`COMPOSER_NO_INTERACTION` to distinguish agent shells.
9. **Worktree awareness is mandatory, not optional.** Cursor's agent worktrees live outside the project at `~/.cursor/worktrees/<repo>/<name>` (fixed), are capped at ~20–25 per machine and pruned on a timer; Claude Code uses `.claude/worktrees/`, Codex creates worktrees by default since 2025-09-22 (market report). Airbag's "protected project" must therefore mean the git *common dir*: resolve any hook `cwd` with `git rev-parse --git-common-dir`, watch the worktree roots with FSEvents too, and keep the snapshot store keyed by common dir with the worktree path recorded per snapshot. Deleting a Cursor worktree is also a destructive event worth a last snapshot (the `cursor.worktreeMaxCount` cleanup gives no hook). The v1.1 disk cleaner gets Cursor's directory for free.
10. **Cursor sandbox interaction.** When `sandbox: true`, the command cannot write outside the workspace/`/tmp` — the breaker can relax `rm -rf outside project` rules but should still snapshot; the hidden snapshot store must not live where the agent's sandboxed command could modify it (keep it under `~/Library/Application Support/Airbag/`, not inside the project).
11. **Localization split.** User-facing strings (`user_message` in Cursor, `systemMessage` in Gemini, the CLI's rendering of `permissionDecisionReason` in Copilot) can be RU/EN per Airbag's locale; agent-facing strings (`agent_message`, `reason`, `permissionDecisionReason`) should stay English and actionable ("Airbag blocked `git reset --hard`: 3 uncommitted files would be lost; snapshot abc123 taken; ask the user to approve in Airbag").
12. **Hook integrity (v2 in the market report) is cheap once the installers exist.** Airbag already parses `~/.cursor/hooks.json`, `~/.gemini/settings.json`, `~/.copilot/hooks/*.json`, `~/.claude/settings.json`: diffing them against a stored fingerprint on each GUI poll gives the "foreign hook appeared" alert for free.
13. **What not to build.** No per-agent "ask" UI inside the agent (Cursor and Copilot already prompt); no attempt to use Cursor's Claude-import or Copilot's `.claude/settings.json` import as the install path (undocumented payload shape, lower priority, repo-scoped for Copilot); no project-level hooks.

## 9. Open questions (each is a 15-minute probe once the agents are installed on the dev machine)

1. Cursor: exact stdin payload delivered to an *imported* Claude-format `PreToolUse` hook (Cursor-native `preToolUse` shape or translated Claude shape?). Determines the dedupe heuristic in §8.2.
2. Cursor CLI: does `sessionEnd` fire at all; do hooks fire in `agent -p` (print) mode; what is the "platform default" timeout; does `ask` from `beforeShellExecution` show a prompt in the CLI.
3. Cursor: relation between `sessionStart.session_id` and `conversation_id`; whether `conversation_id` is stable across `agent --resume`.
4. Cursor CLI process chain for shell commands (`cursor-agent` → `node` → `zsh`?) and which env markers the CLI (not the IDE) sets — `CURSOR_AGENT` is documented for "a Cursor session" without saying CLI vs IDE.
5. Cursor worktree directory naming inside `~/.cursor/worktrees/<repo>/` and whether cleanup fires any hook.
6. Gemini: whether `~/.gemini/settings.json` tolerates comments (JSONC) and unknown keys inside hook entries; whether `SessionEnd` fires on SIGINT/terminal close; confirmation that `BeforeTool` fires for `run_shell_command` inside sub-agents (`invoke_agent`).
7. Copilot: is `toolArgs` an object or a JSON string in the current build (the tutorial double-parses); does the `exec`/`args` entry accept `matcher`; do hook processes receive `COPILOT_CLI=1`; is the Homebrew `copilot-cli` binary a native (Rust) process or node (process-name matching in the radar).
8. Copilot: the `.claude/settings.json` import — does it also map `Bash`→`bash` payloads to Claude shape (changelog 1.0.62 says Claude-format *plugin* hooks carry Claude tool names)?
9. macOS: confirm `sysctl KERN_PROCARGS2` returns the environment for same-uid processes of all three agents (Electron/Node children sometimes have oversized args blocks) and measure its cost at radar polling frequency.
10. Gemini: does `{"decision":"ask"}` from `BeforeTool` show the confirmation prompt on the released npm/Homebrew build (source at head `ed96fae` says yes, docs say nothing); what happens in `gemini -p` (non-interactive) — deny or allow.
11. Measured hook latency on this machine for each agent (hook spawn overhead alone, then with a warm snapshot) — Cursor claims a 40× startup improvement in 2.4; none of the three documents the overhead.

## 10. Sources (all accessed 2026-10-16/17)

Cursor: https://cursor.com/docs/agent/hooks · https://cursor.com/docs/reference/third-party-hooks · https://cursor.com/changelog/2-4 · https://cursor.com/changelog/cli-jan-16-2026 · https://cursor.com/docs/configuration/worktrees · https://cursor.com/docs/agent/terminal · https://cursor.com/docs/agent/security/run-modes · https://cursor.com/docs/cli/overview · https://cursor.com/docs/cli/installation · https://cursor.com/install (installer script) · forum (staff replies): https://forum.cursor.com/t/cursor-cli-doesnt-send-all-events-defined-in-hooks/148316 · https://forum.cursor.com/t/configure-worktree-location/149222 · https://forum.cursor.com/t/working-with-worktrees-in-cursor/153472 · https://forum.cursor.com/t/orphaned-agent-exec-gh-shell-storm-maxes-cpu-after-plan-mode-multi-root/166863 · https://forum.cursor.com/t/agent-shell-tool-runs-with-empty-path-basic-unix-commands-fail-command-not-found-tr-wasting-tokens/166316 · https://forum.cursor.com/t/cursor-cli-jan-8-2026-new-commands-and-performance-improvement/148372 · https://forum.cursor.com/t/how-do-hooks-work-in-cursor-cli/150201 · (secondary) https://forum.cursor.com/t/cli-agent-prepends-bundled-node-onto-path/168848 · https://forum.cursor.com/t/cursor-agent-create-chat-and-how-to-delete-old-chats/156640 · https://cursor.com/docs/cli/reference/configuration (via search).

Gemini CLI (repo `google-gemini/gemini-cli`, head ed96fae, 2026-10-16): `docs/hooks/index.md`, `docs/hooks/reference.md`, `docs/hooks/writing-hooks.md`, `docs/tools/shell.md`, `docs/cli/settings.md`, `docs/cli/enterprise.md`, `packages/core/src/hooks/{hookRunner,hookRegistry,trustedHooks,types}.ts`, `packages/core/src/services/chatRecordingService.ts`, `packages/core/src/config/storage.ts` — https://github.com/google-gemini/gemini-cli.

Copilot CLI: https://docs.github.com/en/copilot/reference/hooks-reference · https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-hooks-reference · https://docs.github.com/en/copilot/tutorials/copilot-cli-hooks · https://docs.github.com/en/copilot/how-tos/copilot-cli/cli-best-practices · https://github.com/github/copilot-cli (`changelog.md`, `README.md`, head c01c663, 2026-10-14).

Installers: https://github.com/kenryu42/claude-code-safety-net (v2.6.12, head 8f62e92; `src/hosts/{cursor,gemini-cli,copilot-cli,claude-code}/*.ts`, `src/hosts/install/*.ts`, `hooks/*.json`) · https://github.com/kageroumado/adrafinil (head 29d3434; `REFERENCE.md`, `AdrafinilShared/Sources/AdrafinilShared/Installer/Integrations/*.swift`).

Local probes (2026-10-16/17): `~/.gemini/settings.json`, `~/.gemini/projects.json`, `~/.gemini/tmp/*/chats/`, `~/.copilot/config.json`, `~/.copilot/logs/`; no `cursor`, `agent`, `cursor-agent`, `gemini` or `copilot` on PATH; no `~/.cursor`.

## 11. Verification log (independent re-check, 2026-10-17)

Method: a second engineer re-fetched the primary sources listed below (official docs via HTTP, GitHub raw files at the stated heads, forum threads) and re-ran the local probe. Verdicts: **confirmed** = source supports the claim as written; **corrected** = doc text changed above; **downgraded** = evidence weaker than the tag claimed.

| # | Claim checked | Source / probe | Verdict |
|---|---|---|---|
| 1 | Cursor config paths, `version: 1`, entry fields (`command`, `type`, `timeout` s/"platform default", `failClosed` default false, `matcher`, `loop_limit` 5 / null for Claude-format), priority Enterprise>Team>Project>User, deny>ask>allow, project hooks need trusted workspace, user hooks run from `~/.cursor/` | https://cursor.com/docs/agent/hooks (fetched 2026-10-17, HTML grep) | confirmed; **corrected** the merge rule for non-permission fields (docs: "the last response wins … a lower-priority source overrides a higher-priority one", not "highest priority wins") |
| 2 | Cursor `beforeShellExecution` stdin (`command`, `cwd`, `sandbox` + common fields incl. `conversation_id`, `generation_id`, `cursor_version`, `workspace_roots`, `transcript_path`, `user_email`, `model`), output `permission/user_message/agent_message`, exit 2 = deny, other codes fail open, invalid JSON blocks permission hooks even with `failClosed: false`, `ask` not enforced for `preToolUse`, `sessionStart` fire-and-forget, `sessionEnd` reasons/`duration_ms`, Shell `tool_input {command, working_directory}` | same page | confirmed except **"empty stdout blocks"**: docs list "no output" only as a `failClosed`-class failure (fail-open by default) and never equate it with invalid JSON → **downgraded to [unverified]** in §3.5, §3.10, §8.4, TL;DR 8. Added the documented env table (`CURSOR_PROJECT_DIR` primary, `CLAUDE_PROJECT_DIR` alias). |
| 3 | Cursor Claude-hooks import: files `.claude/settings.local.json` > `.claude/settings.json` > `~/.claude/settings.json`, on by default (Settings → Agents → Third-Party Imports), mapping `PreToolUse→preToolUse`, `Bash→Shell`, `Edit→Write`, `Glob` unsupported, `Notification`/`PermissionRequest` unsupported, exit 2 = deny, `permissionDecisionReason→user_message` | https://cursor.com/docs/reference/third-party-hooks; https://cursor.com/changelog/2-4 ("Added compatibility with Claude Code hooks in CLI", 2026-01-22) | confirmed; page still does not describe the stdin payload or IDE-vs-CLI scope (unchanged [likely]/[unverified] tags) |
| 4 | Cursor CLI event support per staff (deanrie): Jan 8/9 only shell hooks; Apr 12 + `afterFileEdit`, `postToolUse`, `stop`, `sessionStart`; `afterAgentResponse`/`afterAgentThought` never; May 10/Jun 7 cloud agents fire no lifecycle hooks; `--output-format stream-json` offered for `--print` | https://forum.cursor.com/t/cursor-cli-doesnt-send-all-events-defined-in-hooks/148316 | confirmed; **corrected** attribution of the CLI version string (it is the thread opener's, not staff's); `sessionEnd`/`preToolUse`/`beforeSubmitPrompt` in the local CLI remain unstated by staff |
| 5 | Cursor worktrees: fixed `~/.cursor/worktrees` (staff 2026-01-18 and 2026-05-18), `cursor.worktreeMaxCount` default 25 per machine, `cursor.worktreeCleanupIntervalHours` (6 is an example, no default stated), worktrees created outside Cursor eligible for deletion, `.cursor/worktrees.json` keys, `ROOT_WORKTREE_PATH` | https://forum.cursor.com/t/configure-worktree-location/149222; https://cursor.com/docs/configuration/worktrees | confirmed (docs page gives no path at all — the path rests on staff forum replies only; tag kept at [verified: staff]) |
| 6 | Gemini config precedence project `.gemini/settings.json` > user > system `/etc/gemini-cli/settings.json` > extensions; nested `{matcher, sequential, hooks:[{type, command, name, timeout ms default 60000, description}]}`; `type` required, only `command`; `hooksConfig.enabled` default true | `docs/hooks/index.md`, `docs/hooks/reference.md`, `docs/cli/settings.md` at head `ed96fae` (2026-10-16) | confirmed |
| 7 | Gemini `BeforeTool` input (`session_id`, `transcript_path`, `cwd`, `hook_event_name`, `timestamp`, `tool_name`, `tool_input`), `run_shell_command` params (`command`, `description`, `dir_path`, `is_background`), `GEMINI_CLI=1` in subprocesses, output `decision allow/deny(block)`, `reason`, `systemMessage`, exit 2 blocks with stderr, "other = warning", no `ask`, "Silence is Mandatory" | `docs/hooks/reference.md`, `docs/hooks/index.md`, `docs/tools/shell.md`; `packages/core/src/hooks/{hookRunner,hookAggregator,types}.ts`, `packages/core/src/scheduler/{hook-utils,scheduler}.ts` | docs confirmed, but **corrected against source**: (a) `decision: "ask"` exists and forces `PolicyDecision.ASK_USER` (undocumented); (b) when stdout is empty stderr is parsed; (c) non-JSON output with any exit code ≥2 becomes `deny`, exit 1 → warning+allow; (d) valid JSON wins over the exit code |
| 8 | Gemini hook execution env (`GEMINI_PROJECT_DIR`, `GEMINI_PLANS_DIR`, `GEMINI_CWD`, `GEMINI_SESSION_ID`, `CLAUDE_PROJECT_DIR`, sanitized `process.env`), `spawn(shell executable, [...argsPrefix, command], {cwd: input.cwd, shell:false})`, `SessionEnd` "will not wait", `~/.gemini/trusted_hooks.json` keyed `name:command` per project, transcripts `getProjectTempDir()/chats/session-<ts>-<8hex>.jsonl` | `hookRunner.ts` L347-366, `docs/hooks/reference.md` SessionEnd, `trustedHooks.ts`, `hookRegistry.ts`, `chatRecordingService.ts` L780-820 | confirmed; added sub-agent transcript nesting |
| 9 | Copilot hook sources (policy dirs, `.github/hooks/*.json`, inline in `.github/copilot/settings(.local).json` and `.claude/settings(.local).json`, `~/.copilot/hooks/*.json` / `$COPILOT_HOME`, inline `~/.copilot/settings.json`, plugins), schema (`version` 1, `type command/http/prompt`, `bash/powershell/command`, `exec+args` CLI-only no shell, `cwd`, `env`, `timeoutSec` default 30 + `timeout` alias, `matcher` full-match), `disableAllHooks`, cloud agent loads only `.github/hooks` | https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-hooks-reference; https://docs.github.com/en/copilot/reference/hooks-reference | confirmed; noted the reference's inconsistent statement of load order and that `config.json` is no longer read |
| 10 | Copilot `preToolUse` payload (`sessionId`, ms `timestamp`, `cwd`, `toolName` `bash`, `toolArgs`), output `permissionDecision allow/deny/ask` + `permissionDecisionReason` + `modifiedArgs`, exit 2 = deny even if stdout says allow, hook error = deny ("hook errored"), timeout = fail-open, `ask`→deny in autopilot and cloud, tutorial double-parses `toolArgs` | same reference pages; https://docs.github.com/en/copilot/tutorials/copilot-cli-hooks; cc-safety-net `src/hosts/copilot-cli/hook.ts` (head `4fd49ef`) | confirmed; `toolArgs` typed `unknown`, PascalCase `tool_input` "parsed from JSON string when possible" (added) |
| 11 | Copilot changelog attributions: 0.0.396 deny/modify; 0.0.421 `COPILOT_CLI=1`; 0.0.422 `~/.copilot/hooks`; 1.0.4 `ask`, `disableAllHooks`, `timeout` alias; 1.0.6 PascalCase + nested; 1.0.8 inline settings; 1.0.21 PascalCase payloads; 1.0.22 session hooks once per session; 1.0.36 matcher; 1.0.49 repo hooks in `-p` when trusted; 1.0.57 errors deny; 1.0.62 Claude tool names; 1.0.70 exit 2; 1.0.78 piped `sessionEnd` per turn; 1.0.85 `/clear`; 1.0.92 single `sessionEnd` in prompt mode; 1.0.97 autopilot ask→deny; 1.0.98 (2026-10-14) latest; session-state dirs (0.0.342) | `changelog.md` at head `c01c663` (2026-10-14), line-to-version check | confirmed; added 1.0.5 (no `version` field), 1.0.10 (repo hooks in `-p`), 1.0.66 |
| 12 | CC Safety Net Cursor install: `~/.cursor/hooks.json`, `preToolUse` flat entry `{command: "npx -y cc-safety-net hook --cursor", timeout: 30, failClosed: true}`, identifies entries by command string, requires `version: 1` | `src/hosts/cursor/install.ts`, `src/hosts/managed-command.ts`, `src/hosts/cursor/hook.ts` at head `4fd49ef` (package 2.6.13) | confirmed |
| 13 | Local probe: no `cursor`/`agent`/`cursor-agent`/`gemini`/`copilot` (nor `claude`/`codex`) on PATH; no `~/.cursor`; `~/.gemini/settings.json` = `security.auth.selectedType` only; `~/.copilot/config.json` auto-managed (131 B); log 2026-09-29 "Starting CLI in server mode (stdio)" then "Starting CLI in stdio mode (Rust JSON-RPC engine)"; no `~/.copilot/session-state` | `command -v`, `ls`, `cat`, `grep` on 2026-10-17 | confirmed |

Not re-checked this pass (tags unchanged): Cursor CLI installer layout and bundled `node` (§3.7), Cursor IDE agent-exec process chain and env markers (§3.8, forum-based, [verified]/[likely] as tagged), Cursor chat storage paths ([likely]), Adrafinil installer details (§6), Codex column of §7.

