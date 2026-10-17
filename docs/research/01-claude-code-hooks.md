# Claude Code hooks (2.1.295) — research note for Airbag

Date: 2026-10-17. Scope: Claude Code hooks, settings, checkpointing, worktrees, the desktop app's launch path and the session/registry files Claude Code keeps on disk, as they matter for Airbag's hook bridge (snapshots before shell commands, circuit breaker, session registry, port radar). Primary sources were fetched on 2026-10-16/17 as raw Markdown from `https://code.claude.com/docs/en/<page>.md` and the GitHub CHANGELOG (already at 2.1.302 on fetch day). Local facts were verified on this Mac (macOS 15.7.9, Apple M4, Claude Desktop 2.31226.1 bundling Claude Code 2.1.295) with read-only inspection of `~/.claude` plus one throw-away `claude -p` run whose SessionStart/SessionEnd hooks were captured (the run itself failed auth before any API call, so no tokens were spent).

Tags: [verified] = read in the primary source or observed locally today; [likely] = strong inference or secondary source; [unverified] = not confirmed.

## TL;DR

1. Hooks are the right attachment point: 33 events, fired identically in terminal, desktop app, IDE and `-p` runs; `PreToolUse` on `Bash` runs before any permission check in every mode, and its `deny` holds even under `--dangerously-skip-permissions` [verified].
2. Stdin JSON for Bash: `{session_id, prompt_id, transcript_path, cwd, scratchpad_dir, permission_mode, effort, hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command, description?, timeout?, run_in_background?}, tool_use_id}`; `PostToolUse` adds `tool_response:{stdout, stderr, interrupted, isImage, noOutputExpected?, bashEditDiff?}` and `duration_ms` [verified].
3. Decision = exit 0 + `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow|deny|ask|defer","permissionDecisionReason":"…","updatedInput":{…}}}`, or exit 2 + stderr (= deny). Precedence across hooks: deny > defer > ask > allow. `ask` forces a prompt even in auto mode (since 2.1.211); in `dontAsk`/headless-without-host it becomes a deny; under `bypassPermissions` it is undocumented [verified/unverified as marked].
4. Failure semantics are fail-open by default: timeout, crash, missing binary or exit 1 let the tool run. `"onFailure":"block"` (new in 2.1.295) flips that; use it only for the circuit-breaker hook, never for the snapshot hook [verified].
5. Config lives in `~/.claude/settings.json` (user), `.claude/settings.json`, `.claude/settings.local.json`, managed; `hooks` arrays merge across files, identical handlers run once, and a file watcher hot-reloads hook edits into running sessions (no `/hooks` review step; `/hooks` is read-only). Interactive sessions hold back all settings hooks until the folder is trusted [verified].
6. Hooks run with `CLAUDE_PROJECT_DIR` (launch root, fixed), `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`, `CLAUDE_EFFORT`, `CLAUDE_CODE_ENTRYPOINT=claude-desktop`, messaging socket vars; `cwd` in the JSON follows `cd`/worktrees, the env var does not [verified by capture].
7. Processes the Bash tool spawns inherit `CLAUDE_CODE_SESSION_ID` and `CLAUDE_PID`, keep them after reparenting to launchd, and a same-uid process can read them via `KERN_PROCARGS2` without root (verified with Homebrew node and CLT python3; Apple-restricted binaries like `/bin/sleep` hide their env). This gives the radar a durable session tag that issue #43944 claimed does not exist [verified].
8. Checkpointing (`/rewind`) covers only Edit/Write/NotebookEdit of the main agent, keeps 100 checkpoints per session in `~/.claude/file-history/<session>/<hash>@v<N>`, swept after `cleanupPeriodDays` (30), skips Bash changes, most subagent edits, external edits, symlinks/hardlinks [verified].
9. Claude Desktop launches the bundled binary `~/Library/Application Support/Claude/claude-code/<ver>/<hash>/claude.app/Contents/MacOS/claude` via `disclaimer --pgroup` with `--setting-sources=user,project,local --permission-mode=auto --allow-dangerously-skip-permissions --permission-prompt-tool=stdio` and stream-json I/O, so user/project hooks apply; `~/.claude/sessions/<pid>.json` is the live registry (pid, sessionId, cwd, name, status, entrypoint, procStart) [verified].
10. Background Bash commands have no time limit in terminal/desktop/VS Code sessions (the 30-minute limit from 2.1.285 was narrowed to unattended runs in 2.1.288), so orphan dev servers remain a real problem for Airbag to solve [verified].

## 1. Hook events (complete list as of 2.1.295)

Source: hooks reference, "Hook lifecycle" and "Exit code 2 behavior per event" tables, https://code.claude.com/docs/en/hooks (accessed 2026-10-16) [verified].

| Event | Fires | Matcher filters on | Exit 2 blocks? | Handler types |
| --- | --- | --- | --- | --- |
| `SessionStart` | new/resumed/cleared/compacted/forked session | `startup`, `resume`, `clear`, `compact`, `fork` | no (stderr shown to user) | command, mcp_tool (mcp_tool skipped at launch) |
| `Setup` | only `--init-only`, or `-p --init` / `--maintenance` | `init`, `maintenance` | no | command |
| `InstructionsLoaded` | CLAUDE.md / rules file loaded | `session_start`, `nested_traversal`, `path_glob_match`, `include`, `compact` | no | command, http, mcp_tool |
| `UserPromptSubmit` | prompt submitted (also scheduled tasks, background-subagent reports, cross-session messages) | none | yes | all five |
| `UserPromptExpansion` | typed `/command` expands | command name | yes | all five |
| `MessageDisplay` | assistant text displayed | none | no | command, http, mcp_tool |
| `PreToolUse` | before any tool call except `EndConversation` | tool name | yes | all five |
| `PermissionRequest` | Claude Code is about to prompt | tool name | no (use `decision` object) | command, http, mcp_tool, prompt |
| `PostToolUse` | tool succeeded | tool name | no (stderr shown to Claude) | all five |
| `PostToolUseFailure` | tool threw / MCP error | tool name | no | all five |
| `PostToolBatch` | after a batch of parallel tool calls | none | yes (stops loop) | all five |
| `PermissionDenied` | auto-mode classifier denied | tool name | no (`retry` only) | all five (output read only from command) |
| `Notification` | notification sent | `permission_prompt`, `idle_prompt`, `auth_success`, `elicitation_*`, `agent_needs_input`, `agent_completed`, `quota_auto_resume_*` | no | command, http, mcp_tool |
| `SubagentStart` | Agent tool spawn/resume, teammate message | agent type | no | command, http, mcp_tool |
| `SubagentStop` | subagent finished | agent type | yes | all five |
| `TaskCreated` / `TaskCompleted` | TaskCreate / TaskUpdate | none | yes | all five |
| `Stop` | main agent finished a turn (not on user interrupt) | none | yes | all five |
| `StopFailure` | turn ended by API error | error type | no (output ignored) | command, http, mcp_tool |
| `TeammateIdle` | agent-team teammate about to idle | none | yes | all five |
| `ConfigChange` | settings/managed/skill file changed | `user_settings`, `project_settings`, `local_settings`, `policy_settings`, `skills` | yes (not `policy_settings`) | command, http, mcp_tool |
| `CwdChanged` | main conversation `cd` | none | no | command, http, mcp_tool |
| `DirectoryAdded` | `/add-dir` or SDK `register_repo_root` | `slash_command`, `register_repo_root` | no | command, http, mcp_tool |
| `FileChanged` | watched file changed (fs watcher, any writer) | literal filenames (`.env\|.envrc`) | no | command, http, mcp_tool |
| `WorktreeCreate` / `WorktreeRemove` | worktree creation/removal; replaces git logic | none | any non-zero fails | command, http, mcp_tool |
| `PreCompact` / `PostCompact` | before/after compaction | `manual`, `auto` | Pre: yes; Post: no | command, http, mcp_tool |
| `PreModelSwitch` / `PostModelSwitch` | requested model switch / after switch | canonical model name | Pre: yes; Post: no | command, http, mcp_tool |
| `Elicitation` / `ElicitationResult` | MCP server asks for input / before reply | MCP server name | yes | command, http, mcp_tool |
| `SessionEnd` | session ends | `clear`, `resume`, `logout`, `prompt_input_exit`, `other` | no | command, http, mcp_tool |

Cadence note: per session `SessionStart`/`SessionEnd`; per turn `UserPromptSubmit`/`Stop`/`StopFailure`; per tool call `PreToolUse`/`PostToolUse` [verified]. Hooks were released in 1.0.38 (CHANGELOG, https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md, accessed 2026-10-16) [verified].

## 2. Stdin JSON: common fields and per-event schemas

### 2.1 Common input fields [verified]

| Field | Notes |
| --- | --- |
| `session_id` | current session UUID; changes on `/clear` |
| `prompt_id` | UUID of the prompt being processed; absent until first user input |
| `transcript_path` | `~/.claude/projects/<slug>/<session_id>.jsonl`; written asynchronously, may lag |
| `cwd` | working directory when the hook fires; follows `cd` and worktree entry |
| `scratchpad_dir` | `/private/tmp/claude-<uid>/<slug>/<session>/scratchpad` on macOS; absent without scratchpad; needs v2.1.257+ |
| `permission_mode` | `default` (Manual), `plan`, `acceptEdits`, `auto`, `dontAsk`, `bypassPermissions`; not on every event |
| `effort` | `{"level": "low|medium|high|xhigh|max"}`; tool-context events only |
| `hook_event_name` | event name |
| `agent_id`, `agent_type` | present inside subagents / `--agent` sessions |

Only `SessionStart` may carry `model`. There is no `$CLAUDE_MODEL` env var [verified].

### 2.2 Captured on this machine (2.1.295, `claude -p`, exact bytes modulo path shortening) [verified]

SessionStart (no `permission_mode`, `prompt_id`, `scratchpad_dir` or `model` in this run):

```json
{
  "session_id": "00000000-0000-4000-8000-000000000002",
  "transcript_path": "/Users/me/.claude/projects/-private-tmp-claude-501-…--yne95t/00000000-0000-4000-8000-000000000002.jsonl",
  "cwd": "/private/tmp/claude-501/…/scratchpad/probe",
  "hook_event_name": "SessionStart",
  "source": "startup"
}
```

SessionEnd:

```json
{
  "session_id": "00000000-0000-4000-8000-000000000002",
  "transcript_path": "…/00000000-0000-4000-8000-000000000002.jsonl",
  "cwd": "/private/tmp/claude-501/…/scratchpad/probe",
  "prompt_id": "00000000-0000-4000-8000-000000000003",
  "hook_event_name": "SessionEnd",
  "reason": "other"
}
```

Note the transcript project slug: the working-directory path with every non-alphanumeric character replaced by `-`, truncated to 200 chars plus a hash suffix (`--yne95t` above) when longer (sessions doc, https://code.claude.com/docs/en/sessions, accessed 2026-10-16) [verified].

### 2.3 PreToolUse for Bash (docs example, field set confirmed by docs table) [verified]

```json
{
  "session_id": "abc123",
  "prompt_id": "550e8400-e29b-41d4-a716-446655440000",
  "transcript_path": "/home/user/.claude/projects/.../transcript.jsonl",
  "cwd": "/home/user/my-project",
  "scratchpad_dir": "/tmp/claude-1000/-home-user-my-project/abc123/scratchpad",
  "permission_mode": "default",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_input": {
    "command": "npm test",
    "description": "Run test suite",
    "timeout": 120000,
    "run_in_background": false
  },
  "tool_use_id": "toolu_01ABC123..."
}
```

Other tool inputs that matter: `Write {file_path, content}`, `Edit {file_path, old_string, new_string, replace_all}`, `NotebookEdit`, `Agent {prompt, description, subagent_type, model?, run_in_background?}` (local transcript shows `run_in_background` on Agent calls), `PowerShell` (same as Bash; Windows only), `Monitor` (long-running command tool, separate name), `EnterWorktree {name?|path?}`, `ExitWorktree {action, discard_changes?}` [verified]. File paths in `tool_input` are always absolute (`~` and relative paths expanded before hooks) [verified].

### 2.4 PostToolUse for Bash [verified]

```json
{
  "...common fields...": "",
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "tool_input": {"command": "npm test", "description": "Run test suite"},
  "tool_response": {
    "stdout": "...", "stderr": "", "interrupted": false, "isImage": false,
    "noOutputExpected": false,
    "bashEditDiff": {"changedFiles": ["/abs/path.ts"], "files": [{"filePath": "...", "hunks": []}], "moreFiles": 0, "unavailable": false, "skipped": false, "shared": false}
  },
  "tool_use_id": "toolu_01ABC123...",
  "duration_ms": 4187
}
```

`tool_response` keys `stdout, stderr, interrupted, isImage, noOutputExpected, bashEditDiff` were confirmed in a local transcript's `toolUseResult`; `bashEditDiff` (v2.1.269+, public beta) is recorded only in auto/bypass mode by default or everywhere with `bashEditDiffEnabled: true` in user/managed settings; max 200 paths, 5 diffs, git-ignored files and submodules excluded, background and read-only commands carry none [verified]. `updatedToolOutput` can replace what Claude sees (must match the Bash shape) [verified].

### 2.5 PostToolUseFailure [verified]

Same as PostToolUse without `tool_response`; adds top-level `error` (for Bash: first line `Exit code N`, then interleaved output, middle-truncated), `is_interrupt`, `duration_ms`. Does not fire for permission denials, schema rejections, or cancelled tools.

### 2.6 Stop / SubagentStop [verified]

Stop input: `stop_hook_active`, `last_assistant_message`, `background_tasks[]`, `session_crons[]`. Each `background_tasks` entry: `{id, type: "shell|subagent|monitor|workflow|teammate|cloud session|MCP task", status, description, command? (shell only, 1000 chars), agent_type?, server?, tool?, name?}`. SubagentStop adds `agent_id`, `agent_type`, `agent_transcript_path` (`…/<session>/subagents/agent-<id>.jsonl`), and the same arrays scoped to the parent. An 8-consecutive-block cap applies (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`).

### 2.7 Other events in one line each [verified]

`UserPromptSubmit {prompt, session_title?}`; `Notification {message, title?, notification_type}`; `SubagentStart {agent_id, agent_type}`; `PreCompact {trigger: manual|auto, custom_instructions|null}`; `PostCompact {trigger, compact_summary}`; `SessionEnd {reason}`; `PermissionRequest {tool_name, tool_input, permission_suggestions[]}` (no `tool_use_id`); `PermissionDenied {tool_name, tool_input, tool_use_id, reason}` where reason looks like `[Irreversible Local Destruction]`; `ConfigChange {source, file_path?}`; `CwdChanged {old_cwd, new_cwd}`; `FileChanged {file_path, event: change|add|unlink}`; `WorktreeCreate {name}` (command hook prints the created path as last stdout line); `WorktreeRemove {worktree_path}`; `DirectoryAdded {directory, source}`.

## 3. Bash tool call facts

- `tool_input.timeout` is milliseconds; default foreground timeout 2 min (`BASH_DEFAULT_TIMEOUT_MS`), ceiling 10 min (`BASH_MAX_TIMEOUT_MS`); values above the max are clamped (tools reference, https://code.claude.com/docs/en/tools-reference, accessed 2026-10-16) [verified].
- A foreground command that hits its timeout is moved to the background instead of killed (unless it starts with `sleep`); the result says `Command did not complete within its 120s timeout and was moved to the background` [verified].
- `run_in_background: true` commands: no time limit in terminal, desktop app, or VS Code sessions. The limit (30 min default, `timeout` honoured up to 2 h; 10 min in `-p` with a text prompt) applies only to unattended sessions (`-p`, SDK, CI, cloud). Introduced 2.1.285, narrowed 2.1.288 [verified]. Idle background shells are reaped under critical memory pressure (2.1.193; tightened 2.1.274) [verified]. Background teardown for background sessions sends SIGTERM before SIGKILL (2.1.160) [verified]. Nothing in the docs says an interactive session kills its background shells on normal exit; issue #43944 reports they are reparented to launchd (https://github.com/anthropics/claude-code/issues/43944, accessed 2026-10-16, closed "not planned" by the stale bot on 2026-06-07 with no maintainer comment) [verified].
- Bash tool subprocess on macOS is `/bin/zsh -c 'source ~/.claude/shell-snapshots/snapshot-zsh-<ts>-<rand>.sh …; <command>'`, a direct child of the `claude` process (observed via `ps`); the snapshot file is per session and removed on clean exit [verified].
- Hooks do not fire for: `!`-prefixed commands the user types, `@file` mentions (inserted without a Read call), `EndConversation`, and tool calls rejected by schema validation [verified].
- Output inline cap ~30,000 chars (`bashOutputMaxChars`), larger results spill to `~/.claude/projects/<slug>/<session>/tool-results/` [verified].

## 4. PreToolUse decision control

### 4.1 Exit codes and stdout (hooks reference "Exit code output") [verified]

| stdout | exit 0 | exit 2 | other exit |
| --- | --- | --- | --- |
| valid JSON object | fields apply | blocked; fields cannot unblock | fields alone decide (counts as failure if `onFailure: "block"`) |
| unparseable / schema-invalid JSON | non-blocking error | blocked; stderr is the reason | non-blocking error |
| plain text / nothing | success, no decision | blocked; stderr is the reason | non-blocking error, action proceeds |

- Exit 2 on `PreToolUse` blocks the call; Claude sees `PreToolUse:Bash hook error: [<command>]: <stderr>`. Exit 1 does not block unless `onFailure: "block"` [verified].
- Timeout cancels a command/http/mcp_tool hook and discards its output; on PreToolUse the call proceeds through the normal permission flow unless `onFailure: "block"` (2.1.295+) [verified].
- A hook that prints a decision then leaves a background child with inherited stdout open makes Claude Code block the call with `refusing to honor the suspect capture`; redirect the child's stdio [verified].
- Claude never sees stderr of a hook that exits 0; stdout of a successful hook goes to the debug log only (except UserPromptSubmit/UserPromptExpansion/SessionStart/PostModelSwitch, where plain stdout becomes context) [verified].

### 4.2 JSON output fields [verified]

Universal: `continue` (false stops Claude entirely; takes precedence over event decisions), `stopReason` (shown to user, stays in conversation), `suppressOutput` (accepted, no effect), `systemMessage` (warning shown to user; arrives as `SDKInformationalMessage` in stream-json/SDK), `terminalSequence` (OSC 0/1/2/9/99/777 or BEL only; ignored in `-p`/SDK). `additionalContext`, `systemMessage`, `initialUserMessage` and plain stdout are capped at 10,000 chars each; overflow is spilled to a file with a 2,000-char preview.

PreToolUse-specific, inside `hookSpecificOutput` with `hookEventName: "PreToolUse"`:

| Field | Semantics |
| --- | --- |
| `permissionDecision` | `allow` skips the prompt (except actions no mode auto-approves and network-path reads); `deny` blocks; `ask` prompts; `defer` only in `-p` (resume later) |
| `permissionDecisionReason` | `ask`: shown in the prompt; `deny`: shown to Claude; `allow`/`defer`: debug log only; in a `-p` run with nobody to answer, Claude reads it as the denial reason |
| `updatedInput` | replaces the whole input object; permission rules and auto-background eligibility are evaluated on the rewritten input; since 2.1.300 validated like Claude's own input (unknown keys dropped, rejected input denies the call) |
| `additionalContext` | injected next to the tool result |

Multiple hooks: all run in parallel to completion; combined precedence `deny > defer > ask > allow`; if several return `updatedInput` the last to finish wins (non-deterministic) [verified]. Deprecated top-level `decision: approve|block` still maps to allow/deny [verified].

### 4.3 What `ask` really does per mode

- Default/acceptEdits/plan: prompts; the prompt is labelled `[settings]`, `[plugin:<name>]` or `[skill]` by source [verified].
- Auto mode: `ask` forces the permission prompt; the classifier may still deny but cannot silently approve (fixed in 2.1.211) [verified].
- `dontAsk`: every call that would prompt is auto-denied, so `ask` is effectively deny [likely, inferred from permission-modes doc].
- `-p` without a permission host: the call is denied and Claude reads `permissionDecisionReason` [verified]. With `--permission-prompt-tool`/SDK `canUseTool` the host receives the prompt [verified].
- `bypassPermissions` / `--dangerously-skip-permissions`: `deny` is honoured ("blocks the tool even in bypassPermissions mode") [verified]; the docs do not state what `ask` does there [unverified; test before relying on it]. Desktop sessions run `--permission-mode=auto --allow-dangerously-skip-permissions --permission-prompt-tool=stdio`, so an `ask` surfaces as a desktop permission card [likely].

### 4.4 Limits a hook cannot cross [verified]

- `allow` never overrides deny rules or ask rules; a matching ask rule still prompts.
- `allow` never approves `rm`/`rmdir` on a critical path (`/`, `~`, the working directory, `"$VAR"/*` forms, `$(pwd)` targets, nested `sh -c 'rm -rf ~'`, etc.), network-path reads, `requiresUserInteraction` MCP tools, or non-read-only calls in plan mode (permission-modes, https://code.claude.com/docs/en/permission-modes, accessed 2026-10-16).
- A user-installed mod (plugin with in-process `tool.check` hook) can approve a call that a settings-file `PreToolUse` hook blocked, unless the hook is in managed settings (permissions doc, https://code.claude.com/docs/en/permissions, accessed 2026-10-16). Airbag's breaker is therefore not a security boundary against hostile plugins, only against the model.
- Settings hooks are held back in interactive sessions until the folder passes workspace trust; `-p`/SDK runs treat the folder as trusted and run project hooks [verified].

## 5. Configuration: matchers, handler types, fields, timeouts, async

### 5.1 Matchers [verified]

- `"*"`, `""` or omitted: every occurrence.
- Only `[A-Za-z0-9_- ,|]`: exact string or list split on `|` or `,` (`Bash`, `Edit|Write`, `Edit, Write`). Case-sensitive. Hyphenated names exact-match since 2.1.195.
- Any other character: unanchored JavaScript regex (`mcp__.*`, `^Edit$`). `Edit.*` also matches `NotebookEdit`.
- `FileChanged` and `StopFailure` use a narrower exact set (`[A-Za-z0-9_|]`); `FileChanged` matcher doubles as the literal watch list.
- MCP tools are `mcp__<server>__<tool>`; plugin servers `mcp__plugin_<plugin>_<server>__<tool>`.
- Handler-level `if` uses permission-rule syntax (`Bash(git *)`, `Edit(*.ts)`), tool events only; it is best effort: checked per subcommand including `$()`/backticks, and the hook runs anyway when the command cannot be parsed. Not a security filter.

### 5.2 Handler types and fields [verified]

`type`: `command`, `http`, `mcp_tool`, `prompt`, `agent` (agent hooks experimental; at most 12 prompt/agent hooks of one event run concurrently since 2.1.302).

Common: `if`, `timeout` (seconds), `statusMessage`, `once` (honoured only in skill frontmatter; ignored in settings files).

Command: `command` (required), `args` (presence switches to exec form: no shell, `PATH` lookup, placeholders substituted per element), `async`, `asyncRewake` (exit 2 wakes Claude with stderr), `shell` (`bash`|`powershell`), `onFailure` (`continue`|`block`, 2.1.295+). Shell form on macOS is `sh -c`, not the user's zsh snapshot. Placeholders `${CLAUDE_PROJECT_DIR}`, `${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_PLUGIN_DATA}` are substituted and also exported as env vars.

HTTP: `url`, `headers`, `allowedEnvVars`, `onFailure`; `allowedHttpHookUrls` / `httpHookAllowedEnvVars` settings gate them. MCP tool: `server`, `tool`, `input` with `${tool_input.file_path}` substitution. Prompt/agent: `prompt` with `$ARGUMENTS`, `model`, `continueOnBlock` (prompt only).

### 5.3 Timeouts [verified]

Default 600 s for command/http/mcp_tool; lowered to 30 s on `UserPromptSubmit`, `PreModelSwitch`, `PostModelSwitch` and 10 s on `MessageDisplay`; prompt 30 s; agent 60 s. `SessionEnd` hooks share a 1.5 s budget, raised to the largest per-hook `timeout` in settings files up to 60 s, or set by `CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS`. `DirectoryAdded` runs in the background with 600 s.

### 5.4 Async hooks [verified]

`"async": true` (command hooks only): Claude continues immediately; `decision`/`permissionDecision`/`continue` have no effect; `additionalContext`/`systemMessage` are delivered on the next turn; `timeout` is not enforced once running; in `-p` any async hook still running at teardown is killed. `asyncRewake` keeps `timeout` and can wake an idle session on exit 2.

### 5.5 Execution environment [verified]

All matching hooks run in parallel; an identical handler defined in several settings files runs once (plugin/skill copies stay separate). Hooks run in the current directory (falls back to launch dir, project root, `$HOME`, temp if deleted), in their own session with no controlling terminal (`/dev/tty` unavailable), unsandboxed even when the Bash sandbox is on, with the parent environment minus `OTEL_*` exporters. `SessionStart` hooks at launch run in the background (user can type; the first model response waits). Debug: `claude --debug-file <path>` or `~/.claude/debug/<session-id>.txt`; since 2.1.296 each command hook logs `Hooks: PostToolUse:Write [cmd] finished with status 0 (31ms)`.

## 6. Settings files, precedence, hot reload, idempotent install

Source: settings doc, https://code.claude.com/docs/en/settings and settings reference, https://code.claude.com/docs/en/settings-reference (accessed 2026-10-16) [verified].

- Files: `~/.claude/settings.json` (user, every project), `.claude/settings.json` (shared project), `.claude/settings.local.json` (project local; Claude Code adds `**/.claude/settings.local.json` to the global git excludes when it creates the file), managed (`managed-settings.json`, MDM, server-managed). `~/.claude.json` is a separate app-state file (auth, `projects[<path>]` with `hasTrustDialogAccepted`, `allowedTools`, `mcpServers`, …; observed per-project keys locally match).
- Precedence: managed > `--settings` (one session) > project local > shared project > user. List keys merge; `hooks` merge across every level and managed hooks cannot be removed from lower levels. `disableAllHooks` is read after precedence, so a project `false` overrides a user `true`; `--settings '{"disableAllHooks":true}'` wins for one run. `allowManagedHooksOnly` (managed) blocks user/project/local/plugin hooks entirely.
- Hot reload: "Claude Code watches your settings files and reloads them when they change, so it applies most edits to the running session without a restart, including edits to permissions, hooks, and credential helpers." Each detected change fires `ConfigChange` (`user_settings`, `project_settings`, `local_settings`), whose hook may block the change. A file created mid-session loads if its folder existed at start (always for the project `.claude/`). The `/hooks` menu is a read-only browser; there is no review/approval step for project hooks in 2.1.295 [verified]. The older "hooks are snapshotted at startup, review in /hooks" behaviour is gone; I could not pin the exact release that removed it (settings hot-reload already existed by 2.1.140 per CHANGELOG) [likely].
- Validation: invalid JSON in a user/project/local file shows a Settings Error dialog at interactive start (fix / exit / continue without); an unknown hook event name is a warning and only that entry is skipped; a `-p` run silently skips broken files [verified].
- Local-settings location: in a git repo Claude Code reads/writes `.claude/settings.local.json` at the repository root (since 2.1.211); in a worktree, at the main checkout's root [verified].
- Desktop worktree sessions read settings, hooks, skills, `.mcp.json` from the main checkout root; hook commands run there and `${CLAUDE_PROJECT_DIR}` points there [verified].

### 6.1 Copy-pasteable Airbag hook block (user scope)

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "/Applications/Airbag.app/Contents/MacOS/airbag", "args": ["hook"], "timeout": 5 } ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash|PowerShell|Monitor",
        "hooks": [ { "type": "command", "command": "/Applications/Airbag.app/Contents/MacOS/airbag", "args": ["hook"], "timeout": 30 } ] }
    ],
    "PostToolUse": [
      { "matcher": "Bash|PowerShell|Monitor",
        "hooks": [ { "type": "command", "command": "/Applications/Airbag.app/Contents/MacOS/airbag", "args": ["hook"], "timeout": 30 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "/Applications/Airbag.app/Contents/MacOS/airbag", "args": ["hook"], "timeout": 10 } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "/Applications/Airbag.app/Contents/MacOS/airbag", "args": ["hook"], "timeout": 1 } ] }
    ]
  }
}
```

Exec form (`args` present) means no `sh -c`, no quoting problems with the space in `Application Support`, and ~2.5 ms less spawn overhead per call (section 12). One binary dispatches on `hook_event_name` from stdin, so the JSON stays small and dedupe-friendly. Add `"onFailure": "block"` only to the PreToolUse entry and only when the user opts into strict mode; otherwise a missing or crashed `airbag` would block every shell command.

Idempotent install algorithm (all [verified] against the merge/dedupe rules above):

1. Read `~/.claude/settings.json` if present (create `{}` otherwise; keep mode 0600 as observed locally). Parse with a JSON parser that preserves unknown keys; never regenerate the file from a template.
2. For each event, find handler objects whose `command` equals the Airbag binary path (any `args`); replace them in place or append a new matcher group; leave all other groups untouched. Because identical handlers run once, a stale copy in a project file is harmless but should still be removed on uninstall.
3. Write atomically (temp file + `rename(2)`) so the file watcher sees one valid change; running sessions reload hooks and fire `ConfigChange` with `source: "user_settings"`.
4. Uninstall = remove exactly those handler objects, drop empty groups/arrays, keep every other key.
5. Detect `allowManagedHooksOnly` / managed `disableAllHooks` (read `/status` is not scriptable; check the managed files' presence under `/Library/Application Support/ClaudeCode/managed-settings.json` and tell the user) [likely for the path; the docs defer it to the managed-settings page].
6. New hooks apply to already-running sessions through the watcher, except sessions in folders the user has not trusted (held back) and `--bare` sessions (never read).

## 7. Environment variables available to hooks

Captured from the probe hook process on 2.1.295 (SessionStart; secrets redacted) [verified]:

| Variable | Value / meaning |
| --- | --- |
| `CLAUDE_PROJECT_DIR` | launch root; hook-only (not in Bash tool env); does not move with worktrees or `cd` |
| `CLAUDE_CODE_SESSION_ID` | equals `session_id`; also in Bash tool env; updated on `/clear` |
| `CLAUDE_PID` | pid of the `claude` process (v2.1.214+); also in Bash tool env |
| `CLAUDE_EFFORT` | `xhigh` etc. |
| `CLAUDE_ENV_FILE` | `~/.claude/session-env/<session>/sessionstart-hook-0.sh`; present only on SessionStart, Setup, CwdChanged, FileChanged (absent in the SessionEnd capture) |
| `CLAUDE_CODE_MESSAGING_SOCKET` / `_TOKEN` | `/tmp/cc-socks/<pid>.sock` inbox socket + per-session token; present while the inbox is bound (present at SessionStart, absent at SessionEnd) |
| `CLAUDECODE=1`, `CLAUDE_CODE_CHILD_SESSION=1` | "spawned by Claude Code" markers |
| `CLAUDE_CODE_ENTRYPOINT` | `claude-desktop` in desktop-hosted sessions (inherited by the probe) |
| `CLAUDE_CODE_HOST_SESSION_ID` | `local_<uuid>`, the desktop's own session id |
| `CLAUDE_CODE_EXECPATH` | absolute path of the running `claude` binary |
| `CLAUDE_CODE_DESKTOP_APP_VERSION`, `CLAUDE_AGENT_SDK_VERSION`, `CLAUDE_CODE_SESSION_ATTENDED=1`, `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true` | desktop host details |
| `CLAUDE_CODE_OAUTH_SCOPES` | present; `CLAUDE_CODE_OAUTH_TOKEN` is in the `claude` process env but absent from Bash-tool children (verified) and hooks (likely) |
| `PWD`, `TMPDIR`, `HOME`, `PATH`, `SSH_AUTH_SOCK`, … | inherited login environment |

Documented but not captured here: `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA` (plugin hooks), `CLAUDE_CODE_REMOTE=true` (cloud), `CLAUDE_CODE_BRIDGE_SESSION_ID` (Remote Control connected), `CLAUDE_JOB_DIR` (background sessions, `~/.claude/jobs/<id>`), `CLAUDE_CODE_SHELL_PREFIX` (wraps every Bash/hook/status-line command; exec-form hooks skip it), `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` strips credentials from subprocess envs (env-vars doc, https://code.claude.com/docs/en/env-vars, accessed 2026-10-16) [verified].

## 8. Coverage: background Bash, subagents, plugins, worktrees, layouts

- Background Bash: `PreToolUse` fires for every Bash call, `run_in_background` is just a field; `PostToolUse` fires when the tool returns (immediately for background launches, with the task id and output-file path; no `bashEditDiff`) [verified]. A foreground command auto-moved to background at timeout returns at the move [likely].
- Subagents (Agent tool, `/fork`, teammates): settings/managed/plugin hooks run inside subagents for their tool calls with `agent_id`/`agent_type` in the input; `SubagentStart`/`SubagentStop` fire in the parent; subagent frontmatter hooks run only while it runs and need the agent file's folder trusted (2.1.218+) [verified]. Subagent transcripts: `~/.claude/projects/<slug>/<session>/subagents/agent-<16hex>.jsonl` + `.meta.json {"toolUseId": "toolu_…"}` (observed) [verified].
- Plugins: hooks in `hooks/hooks.json` under the plugin root (wrapped in a top-level `"hooks"` key), merged with user/project hooks when enabled; plugin subagents cannot carry frontmatter hooks (plugins reference, https://code.claude.com/docs/en/plugins-reference, accessed 2026-10-16) [verified].
- Worktree sessions: `claude --worktree <name>` creates `<repo>/.claude/worktrees/<name>/` on branch `worktree-<name>` (generated names like `bright-running-fox`; PR worktrees `pr-<number>`); `EnterWorktree` creates under `.claude/worktrees/` with name segments of `[A-Za-z0-9._-]`, max 64 chars (tool schema, observed); subagents with `isolation: worktree` and background sessions also get temporary worktrees under `.claude/worktrees/` (the `agent-<id>` directory naming reported in issue #93794 is [unverified] here). Desktop default is `<project-root>/.claude/worktrees/`, configurable in Settings > Claude Code, with an optional branch prefix (desktop doc, https://code.claude.com/docs/en/desktop, accessed 2026-10-16) [verified].
- cwd semantics: `cwd` in hook JSON = worktree root after entry, and the new directory after `cd`; `CLAUDE_PROJECT_DIR` stays at the launch root; the transcript moves under the worktree's slug when Claude enters a git worktree (2.1.198+) [verified]. Claude Code writes a marker into the git metadata of worktrees it creates, holds `git worktree lock` while an agent runs, and a periodic sweep removes subagent/background worktrees older than `cleanupPeriodDays` that hold no changes/untracked files/unpushed commits (worktrees doc, https://code.claude.com/docs/en/worktrees, accessed 2026-10-16) [verified]. `worktree.bgIsolation: "none"` disables the move for background sessions [verified].
- Isolation enforcement blocks Edit/Write into the main checkout and git redirects, but not `cp`/redirects by shell commands [verified].

## 9. Checkpointing (`/rewind`)

Source: https://code.claude.com/docs/en/checkpointing and https://code.claude.com/docs/en/claude-directory (accessed 2026-10-16) [verified].

- A checkpoint is taken for every prompt that starts a turn; file snapshots are kept for the 100 most recent checkpoints per session (each file's first snapshot is kept as the VS Code diff baseline); checkpoints are saved with the conversation so `/rewind` works after resume.
- Storage: `~/.claude/file-history/<session-id>/<16-hex>@v<N>` (observed: e.g. `23490efa94cd82aa@v5`, 344 KB total on this machine). The transcript carries `file-history-snapshot` records (`{messageId, snapshot:{messageId, trackedFileBackups, timestamp}, isSnapshotUpdate}`) and `file-history-delta` records (`{messageId, snapshotMessageId, trackingPath, backup:{backupFileName, version, backupTime, realParentDir}}`) (observed; internal format) [verified].
- Retention: the retention sweep deletes a session's snapshots about 30 days after the last one (`cleanupPeriodDays`, min 1, `0` rejected); rewinding afterwards fails with `No files were restored`. Desktop/Cowork transcripts are kept at any age unless `desktopSessionCleanupPeriodDays` is set (2.1.248+). `~/.claude/.last-cleanup` holds the last sweep time (observed; purpose [likely]).
- Not tracked: "Checkpointing does not track files modified by Bash commands" (`rm`, `mv`, `cp` examples); subagent edits except a foreground `context: fork` skill; manual/external edits and other sessions' edits; symlinked and hard-linked paths are skipped on restore with `Restored the code, but skipped N files`; mid-turn queued messages have no checkpoint of their own.
- UI: `/rewind` or double `Esc` offers Restore code and conversation / Restore conversation / Restore code / Summarize from here / Summarize up to here. `/undo` is an alias (2.1.108). A `--rewind-files` flag exists (CHANGELOG 2.1.260) [verified]. Desktop sessions run with `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true`, which backs the desktop diff view [likely].

## 10. How the Claude desktop app runs `claude`

Observed on this Mac (2026-10-16) [verified]:

- Process chain: `Claude.app` (Electron, pid 94586) → `/Applications/Claude.app/Contents/Helpers/disclaimer --pgroup -- <claude binary> …` → `<claude binary>` → `/bin/zsh -c source ~/.claude/shell-snapshots/… ; <command>` for Bash tool calls. The binary is `~/Library/Application Support/Claude/claude-code/2.1.295/9d6405864fdc/claude.app/Contents/MacOS/claude` (also in `CLAUDE_CODE_EXECPATH`). There is no `claude` on `PATH` on this machine; the `sh -> node` tail from the task brief was not observed in this chain.
- Arguments: `--output-format stream-json --verbose --input-format stream-json --effort=xhigh --model=<model> --permission-prompt-tool=stdio --allowedTools=<desktop MCP tools> --disallowedTools=SubscribePR --setting-sources=user,project,local --permission-mode=auto --allow-dangerously-skip-permissions --include-partial-messages --await-initialize --thinking-display omitted --replay-user-messages --settings '{"deniedMcpServers":[…]}'`.
- Consequences: user, project and local settings (and thus Airbag's hooks) load in desktop sessions; the docs confirm "Hooks and skills defined in settings apply to both" and that hook events fire identically in the desktop app. Permission prompts go to the desktop UI over stdio (`canUseTool` host), so `PermissionRequest` hooks run alongside the host and whichever decides first applies; `Notification permission_prompt` fires about 6 s after a prompt appears in these sessions (2.1.233+; `CLAUDE_CODE_DISABLE_PERMISSION_PROMPT_NOTIFY_HOOKS=1` turns it off) [verified].
- Differences: terminal-dialog commands "behave differently in the Code tab" (`/permissions` replies "isn't available in this environment"); `/hooks` is in the same family [likely]. Desktop has no `dontAsk` mode; bypass appears only after the Settings toggle. Desktop sessions have no background-command time limit. Desktop keeps a "Dev servers" menu for preview servers configured in `.claude/launch.json` at the session's root folder, with port-conflict handling [verified].
- Desktop SSH sessions run a helper and Claude Code under `~/.claude/remote/` on the remote host; their transcripts appear locally under `~/.claude/projects/ssh-<uuid>/` (observed) [verified].

## 11. Session registry and transcript files Airbag can read

### 11.1 `~/.claude/sessions/<pid>.json` [verified locally; docs: "one small file per running session, used to detect concurrent sessions and crashes … removed when its session exits and crash leftovers cleared on the next launch"]

```json
{
  "pid": 11328,
  "sessionId": "00000000-0000-4000-8000-000000000001",
  "cwd": "/Users/…/scratch-2026-10-17-80fbb5",
  "startedAt": 1792208372825,
  "procStart": "Sat Oct 17 03:39:32 2026",
  "version": "2.1.295",
  "peerProtocol": 1,
  "peerFeatures": ["notify_idle", "reply_across_default_dirs", "artifact_yield"],
  "kind": "interactive",
  "entrypoint": "claude-desktop",
  "hostSessionId": "local_00000000-…",
  "pidDomain": "darwin",
  "messagingSocketPath": "/tmp/cc-socks/11328.sock",
  "name": "Project plan",
  "nameSource": "user",
  "nameSince": 1792208384132,
  "status": "busy",
  "updatedAt": 1792208849396,
  "statusUpdatedAt": 1792208849396,
  "bridgeSessionId": "session_01XXXXXXXXXXXXXXXXXXXXXX"
}
```

Alongside each JSON sits `<pid>.<sha256>.key` (108 bytes, mode 0600; purpose [unverified], most plausibly the inbox-socket auth material) and the inbox socket `/tmp/cc-socks/<pid>.sock` (0600; docs mention a `/tmp/cc-socks-<uid>` fallback). `status` values seen: `idle`, `busy`; `claude agents --json` documents `busy|waiting|idle` plus `waitingFor`. `procStart` lets a reader detect PID reuse. CHANGELOG 2.1.246 fixed headless sessions not cleaning stale entries. The file is the single best source for pid → session id → cwd → human name while a session is alive [verified].

### 11.2 Transcripts and per-session directories [verified locally]

- `~/.claude/projects/<slug>/<session>.jsonl` with records `user`, `assistant`, `attachment` (environment snapshot incl. `workingDirectory`, `isWorktree`, `isGitRepo`, `scratchpadDirectory`), `queue-operation`, `custom-title {customTitle}`, `agent-name {agentName}`, `bridge-session {bridgeSessionId, ownerAccountUuid, …}`, `last-prompt`, `mode`, `system` (`stop_hook_summary` with `hookCount`, `hookErrors`, `preventedContinuation`; `api_error`), `file-history-snapshot`/`-delta`, `cost-state`, `frame-link`, `atis-latch`. Every message record carries `cwd`, `gitBranch`, `version`, `entrypoint`, `permissionMode`, `sessionId`. Assistant `tool_use` blocks hold the exact `tool_input` (`command`, `description`) and user records hold `toolUseResult`.
- `~/.claude/projects/<slug>/<session>/`: `custom-title.json`, `subagents/`, `tool-results/`, `workflows/`; `~/.claude/projects/<slug>/memory/` (auto memory, exempt from the sweep).
- Docs explicitly call the JSONL format internal and version-unstable; `claude agents --json` (fields `cwd, kind, startedAt, id, state, pid, status, waitingFor, sessionId, name`) is the supported programmatic interface for background and live sessions; `~/.claude/jobs/<id>/state.json`, `~/.claude/daemon/roster.json`, `~/.claude/daemon.log` back agent view [verified].
- Session names for enrichment, in order of freshness: `sessions/<pid>.json.name` (+`nameSource`), `custom-title.json`, `custom-title`/`agent-name` records, `session_title` in SessionStart/UserPromptSubmit hook input, `--name`, else the default display name `<dir>-<2 chars>` (2.1.196+) [verified].
- Other `~/.claude` entries observed: `session-env/<session>/` (CLAUDE_ENV_FILE scripts), `shell-snapshots/`, `backups/.claude.json.backup.<ts>` (five newest), `plugins/`, `skills/`, `telemetry/`, `uploads/`, `worktrees/` (empty here; used by non-git WorktreeCreate examples), `.last-cleanup`, `settings.json` (0600), `settings.local.json`. No `history.jsonl` on this desktop-only install [verified].

## 12. Measured numbers (this machine, 2026-10-16)

| Measurement | Result |
| --- | --- |
| Spawn + stdin read, `sh -c 'cat >/dev/null'` (shell-form hook floor) | median 3.8 ms, p95 4.6 ms |
| Spawn `/bin/cat` directly (exec-form hook floor) | median 1.4 ms, p95 1.8 ms |
| `sh -c 'jq -r .tool_input.command'` | median 4.4 ms, p95 5.1 ms |
| `python3 -I -c 'json.load(...)'` | median 46.2 ms |
| `node -e JSON.parse` (Homebrew node 26.3.1) | median 47.5 ms, p95 59.8 ms |
| `git rev-parse --show-toplevel` | median 5.5 ms |
| Env visibility of a reparented child (`ppid=1`) via `KERN_PROCARGS2`, same uid, no root | Homebrew `node`: 29 `CLAUDE_*` vars visible incl. `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`, `CLAUDE_CODE_HOST_SESSION_ID`; CLT `python3`: same; `/bin/sleep` (Apple restricted binary): 0 vars |
| Hook JSON caps | 10,000 chars per context string; 2,000-char preview on overflow |
| Timeouts | command 600 s default; UserPromptSubmit 30 s; SessionEnd 1.5 s budget (≤60 s) |
| Bash tool | 2 min default, 10 min max foreground; background unlimited in interactive sessions; 30 min / 2 h in unattended |
| Checkpoints | 100 per session; sweep at 30 days |
| Local `~/.claude/file-history` | 344 KB for 4 sessions; one 9.2 MB transcript for a 10-day session |

Interpretation: a native Swift `airbag hook` invoked in exec form should add roughly 2 to 5 ms per tool call before any real work; node/python wrappers add ~45 ms. Snapshot cost dominates and must be engineered separately (section 13).

## 13. What this means for Airbag

1. One binary, one hook entry per event, exec form, absolute path. `airbag hook` reads stdin, switches on `hook_event_name`, and must exit 0 fast. Register `SessionStart`, `PreToolUse`/`PostToolUse` on `Bash|PowerShell|Monitor`, `Stop`, `SessionEnd`. Keep `onFailure` unset (fail-open) for the snapshot path; expose a "strict breaker" toggle that writes `"onFailure":"block"` on the PreToolUse handler only. Document that `allowManagedHooksOnly` machines cannot run Airbag's hooks.
2. The snapshot runs synchronously inside PreToolUse, so its latency is added to every shell command. Budget 50 to 100 ms warm. Design: the GUI keeps the hidden git index pre-staged from FSEvents; the hook only does `write-tree` + `commit-tree` + `update-ref` (and falls back to a full `add -A` when the GUI is not running). Tag the commit with `session_id`, `tool_use_id`, `prompt_id`, `cwd`, the command text and `run_in_background`; PostToolUse with the same `tool_use_id` closes the pair and can attach `bashEditDiff.changedFiles` as a hint (auto/bypass only; never rely on it).
3. Circuit breaker = `permissionDecision` from the same PreToolUse hook: `deny` with a reason for the hard list, `ask` for the soft list (`ask` forces a prompt in auto mode; it becomes a deny in `dontAsk`/unattended `-p`; behaviour under `bypassPermissions` must be tested). Claude Code already refuses `rm -rf /`, `rm -rf ~`, the working directory and `"$VAR"/*` forms in every mode, so Airbag's value is `rm -rf` outside the project, `git reset --hard`, `git clean -fdx`, `git push --force`, `prisma migrate reset --force`, `DROP DATABASE`, plus anything the user adds. Evaluate rules in-binary over the full command string (compound commands, `$()`, `sh -c`), not with the best-effort `if` field. Remember a user-installed mod can override a settings-file block.
4. Settings management must be a surgical JSON edit of `~/.claude/settings.json` (keep unknown keys, atomic rename, 0600). The watcher applies it to running sessions; no restart or `/hooks` review. Offer project-scope install as an option but warn that committed hooks run for teammates (and for anyone running `claude -p` in the repo).
5. Session registry: SessionStart/SessionEnd hooks write rows keyed by `session_id` with `cwd`, `CLAUDE_PID`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_HOST_SESSION_ID`, `transcript_path`, `session_title`/`name`. SessionEnd may be skipped on crash and has a 1.5 s budget, so liveness must come from `~/.claude/sessions/<pid>.json` + `kill(pid,0)` + `procStart` comparison, and names from that file's `name` or `custom-title.json`. Treat `source: clear` as a new session id under the same pid.
6. Radar attribution ladder (all verified mechanisms): (a) while the session lives, walk `proc_bsdinfo` parent chains to a `claude` pid; (b) read the candidate process environment with `sysctl KERN_PROCARGS2` and match `CLAUDE_CODE_SESSION_ID` / `CLAUDE_PID` / `CLAUDE_CODE_HOST_SESSION_ID`; this survives reparenting to launchd and needs no root for same-uid processes, but fails for Apple-restricted binaries and for processes started with a cleaned environment or inside Docker; (c) match the process cwd (`PROC_PIDVNODEPATHINFO`) against registered projects and `.claude/worktrees/<name>`; (d) match argv against commands recorded by PreToolUse (`run_in_background: true`) and by the Stop hook's `background_tasks[].command`; (e) fall back to `claude agents --json` for background sessions. Mark a process orphan when its session row is dead and no live `claude` ancestor exists. Stop with SIGTERM then SIGKILL as a separate action, as Claude Code itself does for background sessions.
7. Do not count on Claude Code to clean up: interactive sessions have no background time limit, and the only cleanup promised is memory-pressure reaping and background-session teardown. Issue #43944's premise ("no way to tag Claude-spawned processes") is outdated because the env tag exists; Airbag should say so plainly in its docs.
8. Worktrees: the GUI should watch `<repo>/.claude/worktrees/*` (and any configured desktop worktree location) as separate snapshot roots, label ports by worktree name, and read `cwd` (not `CLAUDE_PROJECT_DIR`) from hooks to know which worktree a command ran in. Respect Claude Code's own sweep and `git worktree lock` when the disk cleaner arrives in v1.1.
9. Checkpointing gap is confirmed verbatim ("Checkpointing does not track files modified by Bash commands"), plus subagent edits, external edits, symlinks, 100-checkpoint window and 30-day sweep. Airbag's timeline can also index `~/.claude/file-history/<session>/` read-only to show "what /rewind could restore" next to its own snapshots, but should not depend on that internal format.
10. Privacy: hook stdin contains the full command text and transcripts contain everything; Airbag's registry should store command text locally with owner-only permissions and never ship it anywhere (no telemetry is already a product rule). `CLAUDE_CODE_OAUTH_TOKEN` is not in the hook env, so there is nothing to accidentally log.

## 14. Open questions

1. Does `permissionDecision: "ask"` prompt under `bypassPermissions` / `--dangerously-skip-permissions`, or is it treated as allow? Docs cover `deny` only. Needs an interactive test in a terminal session (desktop runs auto mode, where `ask` prompts).
2. Exact directory naming of subagent (`isolation: worktree`) and background-session worktrees under `.claude/worktrees/` (`agent-<id>`?); not documented, only reported in issue #93794.
3. Purpose and format of `~/.claude/sessions/<pid>.<sha256>.key`; whether the `.json` is written for `-p` sessions and for VS Code/JetBrains sessions, and what `entrypoint` values exist besides `claude-desktop` (`cli`? `vscode`? `sdk-ts`?).
4. Does the desktop Code tab honour `/hooks` at all, and does it show the Settings Error dialog when `~/.claude/settings.json` is invalid, or silently skip the file? Relevant to the installer's failure modes.
5. Whether `CLAUDE_CODE_SHELL_PREFIX` can be set from a settings `env` block and whether it could wrap every Bash command (process-group tagging) without breaking stdio MCP servers; probably too invasive for v1.
6. Real cost of the snapshot step inside PreToolUse on large repos (node_modules excluded) and the FSEvents pre-staging design; needs a prototype measurement with the Swift binary (spawn floor measured here is 1.4 to 3.8 ms).
7. When exactly the hook file watcher removed the old "snapshot at startup / review in /hooks" behaviour (the current docs state hot reload; the CHANGELOG line was not found).
8. Whether Claude Code kills still-running background shells when an interactive terminal session exits normally (docs are silent; #43944 says they are reparented). Measure on this machine with a dev server before writing the radar copy.
9. Cursor, Codex and Gemini CLI hook payloads (out of scope here) and whether the same env-tag trick applies to them.

## Sources (all accessed 2026-10-16/17)

- Hooks reference: https://code.claude.com/docs/en/hooks
- Hooks guide: https://code.claude.com/docs/en/hooks-guide
- Checkpointing: https://code.claude.com/docs/en/checkpointing
- Settings and precedence: https://code.claude.com/docs/en/settings ; settings reference: https://code.claude.com/docs/en/settings-reference
- Sandboxing: https://code.claude.com/docs/en/sandboxing
- Permissions: https://code.claude.com/docs/en/permissions ; permission modes: https://code.claude.com/docs/en/permission-modes
- Tools reference (Bash tool behaviour): https://code.claude.com/docs/en/tools-reference
- Environment variables: https://code.claude.com/docs/en/env-vars
- Worktrees: https://code.claude.com/docs/en/worktrees ; subagents: https://code.claude.com/docs/en/sub-agents ; agent view: https://code.claude.com/docs/en/agent-view
- Desktop app: https://code.claude.com/docs/en/desktop
- `.claude` directory and retention: https://code.claude.com/docs/en/claude-directory ; sessions: https://code.claude.com/docs/en/sessions ; cross-session messaging: https://code.claude.com/docs/en/cross-session-messaging
- Headless mode: https://code.claude.com/docs/en/headless ; CLI reference: https://code.claude.com/docs/en/cli-reference ; plugins reference: https://code.claude.com/docs/en/plugins-reference
- CHANGELOG: https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md (versions 1.0.38, 2.1.140, 2.1.160, 2.1.193, 2.1.195, 2.1.208, 2.1.211, 2.1.214, 2.1.246, 2.1.260, 2.1.269, 2.1.285, 2.1.288, 2.1.295, 2.1.296, 2.1.300, 2.1.302 cited above)
- GitHub issue #43944 (orphaned Bash processes, closed not planned): https://github.com/anthropics/claude-code/issues/43944
- Local inspection: `~/.claude/{sessions,projects,file-history,session-env,shell-snapshots,backups,settings.json}`, `~/.claude.json`, `/tmp/cc-socks`, `ps -Eww` of the desktop-launched `claude` processes, a `claude -p` run with probe hooks, and `KERN_PROCARGS2` reads of reparented child processes (scripts kept in the session scratchpad under `probe/`).
