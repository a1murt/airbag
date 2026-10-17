# 05 — Competitors and prior art (scan of 2026-10-01 … 2026-10-16, plus state of known neighbours)

Scope: fresh scan of GitHub (search API + `gh`, sorted by created/updated), Hacker News (Algolia API, Show HN since 2026-09-30), Product Hunt (weekly leaderboards weeks 41–42, product search), Reddit (r/ClaudeCode, r/codex, r/cursor, r/ClaudeAI via the Arctic Shift archive API; reddit.com itself returns 403 to scripts), npm/PyPI/crates.io/Homebrew/iTunes APIs, and primary docs of Claude Code, Codex, Cursor and Gemini CLI. All numbers are as of 2026-10-16/17 unless stated. Tags: [verified] = primary source read on 2026-10-16/17; [likely] = secondary source or strong inference; [unverified] = could not confirm.

## TL;DR

1. No free native macOS GUI for agent rollback exists as of 2026-10-17; the niche is still CLI/plugin-only, but it is filling fast: 8 new snapshot/undo tools appeared between Oct 2 and Oct 13 (takeback, claude-time-machine, snap-back, agentckpt, AI Undo, Agent-Checkpoint, ShedKeeper, Nexus mod). All are ≤3 stars, none has a GUI, a circuit breaker, or a process radar. [verified]
2. The two strongest snapshot designs to copy are claude-time-machine (before+after snapshot per tool call into a bare git repo under `~/.claude/time-machine/`, 0.2–0.4 s on a 67k-file repo) and takeback (hooks + a 1.5 s-debounce `watch` mode for agents without hooks, 30-day retention, ~0.1 s per hook). Both validate Airbag's hidden-git-store hypothesis. [verified]
3. The blocker segment has a clear leader: CC Safety Net (now `kenryu42/cc-safety-net`), 1,645 stars, v2.6.12 on 2026-10-15, 54,206 npm downloads in the 30 days to 2026-10-12, 16 agents, 80+ rule IDs, no snapshots/undo, fails open on broken config. Its PR stream (5 shell-parsing fixes opened on Oct 16 alone) and its own `docs/residual-risk.md` show that text-based blocking is unbounded; Airbag must snapshot first and block only the unrecoverable. [verified]
4. Nobody attributes listening ports to agent session or worktree outside of a hosting terminal/IDE: LeftOpen (129 stars, v0.5.8) walks up from process cwd to a project marker; AgentPeek watches ports 3000–9999 and shows the cwd folder; cmux/Superset group ports per workspace only inside their own app. Airbag's session/worktree attribution remains unoccupied. [verified]
5. Vendors moved, but not into Airbag's lane: Claude Code 2.1.288 removed the 30-min background-command limit for interactive sessions (so orphans persist; the market report's claim is outdated), 2.1.300 force-kills background commands 1.5 s after exit; Codex CLI 0.163.0 (Oct 15) added `/daemon` restart of managed background servers and 0.162.0 managed-worktree tools; Codex `/undo` (#9203) and `/rewind` (#11626) are still open; Cursor's checkpoint docs still say nothing about terminal commands. [verified]
6. Fresh demand signals in the window: r/cursor "Cursor agent ran a recursive rmdir from C:\ and wiped ~600 GB" (Oct 11, 50 points, 131 comments); r/ClaudeCode "claude circumventing guards" (agent bind-mounted the dir into Docker to run `rm -rf` past a hook, Oct 11); "Your deny rule for git push doesn't stop `git -C . push`" (Oct 14). [verified]
7. Disk-cleanup neighbours matured: Mole app (paid, $19) added "AI Cleanup & Care" with a 24 h session-protection rule; SpaceGuard (Sep 30, Swift, 20–40 MB RAM) ranks agent worktrees by size×staleness×safety; Lopper (Sep 27) removes stale worktrees across all repos. Reuse their heuristics in v1.1. [verified]
8. Name "Airbag": no Homebrew formula/cask, no macOS App Store app, GitHub org/user `airbag` is taken (2011, 1 repo), npm `airbag` is taken (a JS "circuit breaking" orchestration lib, Feb 2026), PyPI `airbag` is a 0.0.0 placeholder, crates `airbag` is an error-reporting lib. Nearest semantic collision: `n-bharath-chowdary/airbag` ("The airbag for your git push", Aug 2026, 2 stars, pre-commit guard for Claude Code/Cursor/Codex). The word is widely used as a metaphor in this niche, but no established product owns it. [verified]
9. Pitfalls to design around: hook false positives/negatives in text parsing, fail-open defaults (cc-safety-net, Cursor, Claude Code hook timeouts), restore bugs (Claude Code 2.1.260/2.1.275, Codex un-shipped undo after staging corruption), memory leaks in long-running port apps (PortKiller #75: ~2 GB idle), and worktree-cleanup footguns (Claude Code 2.1.246/2.1.301). [verified]
10. Bottom line: Airbag's combination (agent-independent snapshots + GUI timeline + recoverable-first breaker + session-attributed radar, native, free, MIT, macOS 14+) has no direct competitor as of 2026-10-17; the closest single-feature overlaps are takeback/claude-time-machine (snapshots), cc-safety-net (blocking), LeftOpen (ports) and SpaceGuard/Mole (disk). [verified]

## 1. Capability matrix

Legend: Snap = snapshots independent of the agent's own checkpoints; GUI RB = GUI rollback; Block = pre-execution blocking of destructive shell commands; Attr = attribution of listening processes to project / worktree / agent / session; Disk = cleanup of agent leftovers. ✓ yes, ◐ partial, ✗ no.

| Tool | Type | Snap | GUI RB | Block | Attr (proj/wt/agent/session) | Disk | License | Stars | Last release / push |
|---|---|---|---|---|---|---|---|---|---|
| takeback (hichipli) | CLI + CC/Codex plugin | ✓ hooks + watch | ✗ | ✗ | ✗ | ✗ | MIT | 1 | created 2026-10-08, push 10-09 |
| claude-time-machine (xzwache) | Claude Code mod | ✓ per tool call | ◐ terminal pane | ✗ (flags) | ✗ | ✗ | MIT | 1 | created 10-02, push 10-06 |
| snap-back (Abelo9996) | CLI + CC plugin | ✓ hooks/wrap | ✗ | ✗ | ✗ | ✗ | MIT | 0 | created 10-03, push 10-05 |
| agentckpt (Blackman99) | CLI (Python) | ✓ manual/snap | ✗ | ✗ | ✗ | ✗ | MIT | 1 | created 10-09, push 10-14 |
| AI Undo (MrSkelee) | VS Code ext + CLI | ✓ manual | ◐ VS Code | ✗ | ✗ | ✗ | MIT | 0 | created 10-08 |
| Agent-Checkpoint (ainullm) | prompt protocol | ◐ agent copies files itself | ✗ | ✗ | ✗ | ✗ | MIT | 3 | created 10-06 |
| ShedKeeper (DmitriyBush) | CC hooks, Windows | ✓ verified copy | ✗ | ◐ refuses deletes | ✗ | ✗ | Apache-2.0 | 0 | created 10-13 |
| Receipts (philm123) | Claude Code mod | ◐ rm→trash | ◐ Restore button | ◐ | ✗ | ✗ | none | 0 | created 10-02 |
| Nexus mod (darkomarijaan) | Claude Code mod | ✓ per turn | ◐ | ✓ shield | ✗ | ✗ | MIT | 1 | created 10-11 |
| bashward | CLI (Rust) | ✓ clonefile of write targets | ✗ | ✗ | ✗ | ✗ | MIT/Apache | repo 404 | crate 0.1.1, 2026-05-04 |
| doover | CLI (Rust) | ✓ before destructive cmds | ✗ | ✗ by design | ✗ | ✗ | Apache-2.0 + CC0 rules | 33 | crate 0.2.3, 2026-08-15 |
| Demo_CLI (WePwn/demo_cli) | CLI (Python) | ✓ files/dirs/local DB | ✗ | ✓ unrecoverable only | ✗ | ✗ | MIT | 7 | v0.4.0-beta.8, push 2026-07-19 |
| codex-rewind | Codex CLI fork | ✓ | ✗ | ✗ | ✗ | ✗ | Apache-2.0 | 54 | push 2026-09-27 |
| CC Safety Net | hook (TS) | ✗ | ✗ | ✓ | ✗ | ✗ | MIT | 1,645 | v2.6.12, 2026-10-15 |
| laya-guard | hook + local model | ✗ | ✗ | ✓ allow/review/block | ✗ | ✗ | MIT | 27 | PyPI 0.5.0, 2026-10-17 |
| MiSeGuard | MCP proxy | ✗ | ✗ | ✓ | ✗ | ✗ | MIT | 1 | push 2026-09-11 |
| Skillkeel starter | CC hooks | ✗ | ✗ | ✓ | ✗ | ✗ | MIT | 2 | v0.1.13, 2026-10-11 |
| deltabox-lite | sandbox runtime | ✓ APFS clones + FSEvents | ✗ | ◐ confinement | ✗ | ✗ | Apache-2.0 | 94 | push 2026-10-16 |
| LeftOpen | menu bar + CLI (Swift) | ✗ | ✗ | ✗ | ◐ project via cwd walk-up | ✗ | MIT | 129 | v0.5.8, 2026-10-13 |
| PortKiller | menu bar (Swift) | ✗ | ✗ | ✗ | ✗ | ✗ | MIT | 5,108 | v3.4.0, 2026-10-15 |
| port-kill (treadiehq) | CLI + status bar (Rust) | ✗ | ✗ | ✗ | ✗ | ◐ caches w/ backup | FSL-1.1-MIT | 2,043 | push 2026-04-03 |
| Port Menu | menu bar (Swift) | ✗ | ✗ | ✗ | ◐ repo + branch | ✗ | MIT | 385 | v0.8.10, 2026-04-11 |
| cmux | terminal (Swift) | ✗ | ✗ | ✗ | ◐ ports per workspace (own panes) | ✗ | GPL-3.0-or-later + BUSL server | 28,223 | nightly 2026-10-16 |
| Superset | agentic IDE (TS) | ✗ | ✗ | ✗ | ◐ ports per workspace/worktree (own) | ✗ | Elastic 2.0 | 15,291 | cask 1.38.0 |
| AgentPeek | notch/menu bar (paid) | ✗ | ✗ | ✗ | ◐ ports 3000–9999 + cwd folder | ✗ | proprietary | — | launched 2026-05/06 |
| Agent Deck (aadilkadiwal) | menu bar (Swift) | ✗ | ✗ | ✗ | ◐ sessions via `~/.claude/sessions/<pid>.json` | ◐ CC session data | MIT | 0 | created 10-03, push 10-16 |
| Agent Bar (Aayush) | menu bar GUI for CC | ✗ | ✗ | ✗ | ✗ | ✗ | ? | — | PH ~Feb 2026 |
| AgentBar (jreed91) | menu bar notifier | ✗ | ✗ | ✗ | ✗ | ✗ | MIT | 0 | push 2026-10-05 |
| agent-beacon (XiaoLuoLYG) | menu bar status lights | ✗ | ✗ | ✗ | ✗ | ✗ | MIT | 3 | push 2026-06-04 (dormant) |
| Adrafinil | menu bar keep-awake | ✗ | ✗ | ✗ | ✗ | ✗ | MIT | 515 | v1.12.0, 2026-10-13 (macOS 26.4+) |
| Mole | CLI (GPL) + Mac app ($19) | ✗ | ✗ | ✗ | ✗ | ✓ incl. AI Cleanup (app) | GPL-3.0 / proprietary | 70,680 | V1.61.0, 2026-10-16 |
| SpaceGuard (mkrn) | menu bar (Swift) | ✗ | ✗ | ✗ | ◐ worktree→project/branch/agent | ✓ | MIT | 5 | created 09-30, push 10-07 |
| Lopper (shinokamix) | CLI/TUI (Go) | ✗ | ✗ | ✗ | ✗ | ✓ worktrees | MIT | 9 | push 2026-10-16 |
| fresh (Obedience-Corp) | agent skill | ✗ | ✗ | ✗ | ✗ | ✓ merged branches/worktrees | Apache-2.0 | 4 | created 10-10 |
| Vibe Backup | Mac App Store | ✓ hotkey/commit/MCP | ✓ | ✗ | ✗ | ✗ | proprietary, Pro $14.99 lifetime | 0 ratings | v1.0.3, 2026-09-12 |
| Checkpoints for Claude Code ("Claude Diff") | Mac App Store $7.99 | ✓ MCP/manual | ✓ | ✗ | ✗ | ✗ | proprietary | 0 ratings | v1.4, 2026-05-18 |
| ossnap | CLI (PyPI) | ✗ (env backup to GitHub) | ✗ | ✗ | ✗ | ✗ | MIT | 0 | 0.1.6, 2026-07-10 |
| cboone/snappy | CLI (Go) | ✓ APFS volume snapshots via tmutil | ✗ | ✗ | ✗ | ✗ | MIT | 4 | push 2026-09-10 |
| Claude Code checkpointing | built-in | ◐ edit tools only | ◐ TUI | ✗ | — | ◐ retention sweep | — | — | 2.1.302 |
| Codex | built-in | ✗ CLI (`/undo` un-shipped) | ✗ | ✗ | — | ◐ log DB reclamation | — | — | CLI 0.163.0, 2026-10-15 |
| Cursor checkpoints | built-in | ◐ agent edits | ✓ IDE | ✗ | — | ✗ | — | — | changelog 2026-10-16 |

All rows [verified] via GitHub API/`gh`, npm/PyPI/crates/iTunes APIs or primary docs on 2026-10-16/17, except Agent Bar [likely] (feedbagel.com summary of a Product Hunt listing; GitHub/licence not found).

## 2. New since 2026-10-01 (what appeared, what it does, how it differs)

### 2.1 Snapshot / undo tools

**takeback** — https://github.com/hichipli/takeback (created 2026-10-08, MIT, TypeScript, npm `takeback` 1,914 downloads in the npm window ending 2026-10-12, i.e. ~4 days after publication). [verified]
- Two hooks per agent: `UserPromptSubmit` (before every prompt) and `Stop` (after every turn), ~0.1 s each; checkpoints are commits in a separate git repo under `~/.takeback/`; never writes to the project's `.git`; project need not be a git repo. Follows `.gitignore`, always skips `node_modules`, `.venv`, `__pycache__`. Refuses to auto-start on a non-git folder with >5,000 files or >500 MB. Retention 30 days ("the same retention Claude Code uses"). First checkpoint copies the project (3.6 s for an 850-file app). "Every take back saves where you are first."
- Codex support via plugin; "Codex runs new hooks only after you approve them. Run `/hooks` in Codex once".
- `takeback watch` saves a checkpoint 1.5 s after files stop changing — covers Cursor, Windsurf, Gemini CLI, OpenCode, Aider, Cline.
- Cannot restore `.gitignore`d files (e.g. `.env`, `dist/`), anything outside the folder, nested repos, empty folders, case-only renames.
- Exact hook config (`hooks/hooks.json`):
```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command",
      "command": "node -e \"import(require('node:url').pathToFileURL(require('node:path').join(process.env.CLAUDE_PLUGIN_ROOT,'src','cli.ts')).href)\" save --hook auto",
      "timeout": 30, "statusMessage": "Saving a takeback checkpoint" }]}],
    "Stop": [{ "hooks": [{ "type": "command",
      "command": "node -e \"...same...\" save --hook auto",
      "timeout": 30, "statusMessage": "Saving a takeback checkpoint" }]}]
  }
}
```
- Differs from Airbag: CLI only, per-turn granularity (not per command), no breaker, no radar, no GUI; but its `watch` mode is the one agent-independent element in the new batch.

**Claude Time Machine** — https://github.com/xzwache/claude-time-machine (created 2026-10-02, MIT, Claude Code plugin/mod, requires Claude Code ≥2.1.287). [verified]
- "A bare git repository under `~/.claude/time-machine/` uses your project as its work tree. Before and after each tool call that can change files, it runs `git add -A` into its own index and commits the result." Read-only commands (`ls`, `grep`, `git status`) are skipped. Measured: 0.2–0.4 s per snapshot on a 67,000-file repo; benchmark on microsoft/TypeScript (66,945 files, 421 MB): packing 284 MB → 44 MB in 12.7 s.
- Undo a whole turn or step N of it (`/tm undo 3.2`); user edits made during a turn are kept, conflicts reported instead of overwritten; every undo/travel/prune is itself a snapshot; flags "sensitive" changes (CI config, dependencies, install scripts, secrets file, new executable, mass delete) and offers "Undo these".
- Secrets (`.env`, keys, certs, `.npmrc`, `.pypirc`, `.netrc`, kubeconfigs) are never copied and therefore cannot be undone unless `/tm secrets keep`.
- Limitations: ignored dirs (`node_modules/`, `dist/`) and ignored files >1 MiB not recorded; nothing outside the project; "Large repositories pay two full snapshots per Bash call that may write"; restore failing halfway (locked file) can leave partial state; Windows unsupported.
- Its README critique of bashward: "As of 0.1.1, it judges a command by its first word, so `cd src && rm old.ts` or `make clean && rm -rf dist` slip past it, as do globs like `rm *.log` and anything that writes without naming the path".
- Differs from Airbag: lives inside Claude Code (mod), Claude Code only, no FSEvents path, no GUI outside the terminal, no breaker, no radar.

**snap-back** — https://github.com/Abelo9996/snap-back (created 2026-10-03, MIT, TS, npm `@abelo9996/snap-back` 639 downloads/30 d, Homebrew tap). [verified]
- Shadow git repo; hooks `UserPromptSubmit`, `PreToolUse` (matcher `Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell`), `PostToolUse` with `"async": true`; `snap-back wrap -- codex` wraps any agent; hook costs ~0.5 s via npx, ~0.2 s installed globally (author's M-series numbers).

**agentckpt** — https://github.com/Blackman99/agentckpt (created 2026-10-09, MIT, Python ≥3.9, zero deps). Content-addressed store in `.agentckpt/`; respects `.gitignore`; ~4.2 MB after first snapshot, ~9.4 MB after 200 snaps on psf/requests (~27 KB each); files >10 MiB skipped; `prune --keep 50`; secret-looking files stored as metadata only unless `allow_secrets = true`. Author cites openai/codex#9203 "(522👍, still open)". [verified]

**AI Undo** — https://github.com/MrSkelee/vscode-ai-undo (created 2026-10-08, MIT). VS Code/Antigravity extension + "`npx ai-undo`" CLI; manual checkpoint hotkey, "ghost file cleanup", flushes dirty editor buffers before checkpoint. npm `ai-undo` returns 404 as of 2026-10-17 (README claim not backed). [verified]

**Agent-Checkpoint v2.0** — https://github.com/ainullm/agent-checkpoint (created 2026-10-06, MIT, 3 stars). Not a tool: a prompt "protocol" that instructs the agent to copy a file to `.snapshots/<path>/v<N>` before editing. Depends entirely on the agent obeying. [verified]

**ShedKeeper** — https://github.com/DmitriyBush/ShedKeeper (created 2026-10-13, Apache-2.0, Python, Windows-only, Claude Code). Verified copy (size + sha256) before recognized writes (edit tools, `>`, `cp`, `mv`, `sed -i`); refuses deletes and hands the agent a move-to-trash command; weakening protection requires a one-time code `SK-nnnnnn` typed by the human. [verified]

**Receipts** (mod, 2026-10-02) turns `rm` into a move to a trash folder with a Restore button; **Nexus** (mod, 2026-10-11, Claude Code ≥2.1.296) bundles "a command shield, secret masking, a checkpoint before every turn" with a HUD. Both are in-process Claude Code mods; `claude plugin validate --strict` lists their hooks and `$` calls. [verified]

Related but not competitors: **keelyard** (2026-10-12, Apache-2.0, "undo any step") [unverified — README not fetched, API rate limit]; **h-guard** (2026-10-12) and **d-snap** (2026-10-01) are empty repos without README [verified]; **Hazzel** (HN 2026-10-15) is its own agent with undo [verified, title only].

### 2.2 Blockers / guardrails

**laya-guard** — https://github.com/scs0209/laya-guard (created 2026-10-11, MIT, Python, 27 stars; PyPI `laya-guardrail` 0.5.0 published 2026-10-17; Show HN 2026-10-13, 3 points; r/ClaudeCode 2026-10-12). Regex prefilter, then a ~322M local model (Apache-2.0) judges the rest at ~85–90 ms per command on CPU; verdicts `allow`/`review`/`block`; chains split and "the worst part wins"; 11 agents with one install command that "shows the diff first, backs up your settings, then sends two test calls through the hook"; optional `--files` guard for Read/Edit/Write on protected paths; verdict log never stores command text; hooks fall back to offline regex if the local server is down. Per-agent `review` mapping: Claude Code/Cursor → permission prompt; Codex/Gemini/Windsurf/Amp → "allow + a note" (no ask available). [verified]

**Skillkeel starter** — https://github.com/skillkeel/skillkeel-starter (2026-09-17; v0.1.13 on 2026-10-11, MIT). `guard-bash` blocks `rm -rf /`, `git push --force` without `--force-with-lease`, `git reset --hard`, `git clean -f`, `DROP DATABASE`, ORM wipes (`artisan migrate:fresh`, `rails db:reset`, `prisma migrate reset`, `manage.py flush`…); ships a public "tamper-cases corpus" of what it catches and misses. [verified]

**RepoGuards** (formerly Grove) — https://github.com/yybd/repo-guards (2026-09-29, MIT). Claude Code hooks that refuse `git push`/sweeping `git add` into a repo other than the session's; Show HN 2026-10-15. [verified]

**Deltabox-lite** — https://github.com/delta-box/deltabox-lite (created 2026-08-05, Apache-2.0, Rust, 94 stars; HN 2026-10-15, 10 points). Sandbox with diff/commit/abort per tool call; "macOS uses Seatbelt plus APFS clones and FSEvents"; claims checkpoint/commit <1 ms; on macOS fast mode "assumes Deltabox is the exclusive project writer" and "defers FSEvents accounting to the next state operation". Relevant as prior art for an APFS-clone snapshot engine, not as a product competitor. [verified]

**rowbit** — https://github.com/Ermag/rowbit (2026-10-12, AGPL-3.0, Rust). Proxy between agents and a database: exact row preview, approve/hold/block via YAML, per-change undo with before-images. "Nothing is released yet." Shows demand for DB-level safety that Airbag's `DROP DATABASE` rule only touches. [verified]

### 2.3 Process / port / disk / session neighbours that appeared Sep 15 – Oct 16

- **SpaceGuard** — https://github.com/mkrn/spaceguard (2026-09-30, MIT, Swift, 5 stars). Menu bar free-space watcher; finds "Linked worktrees of every repo found, including `.claude/worktrees`, `~/.codex/worktrees`, `~/.cursor/worktrees`, Conductor workspaces and temp folders"; shows project, branch and agent; runs `git status` on each, dirty worktrees "flagged and never preselected"; removing keeps the branch; ranks by "size × staleness × safety" with labels safe/rebuild/review; "One `getattrlistbulk` syscall reads a whole directory… about 6× faster" than `du`; "~2 MB native Swift/SwiftUI app… 20–40 MB of RAM… only checks free space once a minute"; no network. [verified]
- **Lopper** — https://github.com/shinokamix/lopper (2026-09-27, MIT, Go, 9 stars; Show HN 2026-10-15, 1 point). Scans home and temp dirs for worktrees of any tool, shows size/status, `lopper rm` needs `--force` for uncommitted/unmerged work, re-checks before removing, uses `git worktree remove` (branch kept, "no trash"). [verified]
- **fresh** — https://github.com/Obedience-Corp/fresh (2026-10-10, Apache-2.0). Agent skill: sync default branch, remove branches/worktrees whose changes landed (incl. squash merges); shows plan first; uncommitted changes stop the run. [verified]
- **Agent Deck** — https://github.com/aadilkadiwal/agent-deck (2026-10-03, MIT, Swift, macOS 14+, requires CLT + iTerm2; installer builds from source "so there's no unsigned download for Gatekeeper to block"). Session list from "`~/.claude/sessions/<pid>.json` (watched for changes) + `claude agents --json`"; waiting/finished read "every 3 s (no process started)"; activity via `PreToolUse`/`PostToolUse`/`SubagentStart`/`SubagentStop`/`Stop` hooks with `async: true`; approvals over a Unix socket (`~/.claude/agent-deck/approvals.sock`, owner-only, peer uid checked); Codex via `PermissionRequest` + session hooks, usage from `~/.codex/sessions/…/rollout-*.jsonl`; cleanup moves transcript, scratchpad (`/private/tmp/claude-<uid>/<project>/<id>`), `file-history` undo backups, `session-env`, debug log, todos, tasks to the Trash; "Files made by shell commands aren't listed." No snapshots, no ports. [verified]
- **local-bar** (2026-10-06, Swift) assigns Caddy domains to local servers; **dev-mission-control** (2026-10-16, Swift) flags dirty worktrees/unpushed commits per repo in a menu bar panel. Neither attributes processes. [verified, README heads]
- **Muster / agentmuster.app** (Show HN 2026-10-13), **Littleguys** (HN 2026-10-11, 15 points), **Porch** (HN 2026-10-08) — menu bar session switchers/logs for Claude Code/Codex/Cursor; none does snapshots, blocking or ports. [verified, titles/HN only]
- **RayTrace** (r/ClaudeCode 2026-10-14): gVisor sandbox that records "every process that actually started: executable, args, cwd, stdout/stderr, exit code" — "proposed vs executed" gap. Cloud, paid credits. [verified, post text]

### 2.4 Channel scan results for Oct 1–16

- GitHub: among repos created in October 2026 mentioning "claude code" or "coding agent" with ≥15 stars (≈80 repos), none is a snapshot/undo/blocker/port tool; the category stays below 30 stars (laya-guard 27). Breakouts are skills, mods, status lines and media tools. [verified, `gh search repos`, 2026-10-17]
- Hacker News Show HN since 2026-09-30 (542 posts scanned): no GUI rollback tool. Related: Pi pod sandbox (121 points, Oct 2), Plimsoll sandbox (16, Oct 11), Deltabox (10, Oct 15), Airlock sandbox (3, Oct 12), Fresh (3, Oct 14), laya-guard (3, Oct 13), Skillkeel guard hooks (2, Oct 11), Lopper (1, Oct 15), RepoGuards (1, Oct 15), Agents Sleep Preventer (1, Oct 4). Sandboxes draw an order of magnitude more points than undo tools. [verified]
- Product Hunt weekly leaderboards for weeks 41 and 42 (Oct 5–18): no product in the category; closest are Rill Browser ("where Claude Code and Codex work beside you"), Harness by Autonomous ("every coding agent, every machine, one command center"), OpenCode 2.0. Product search for "claude code" lists Checkpoints for Claude Code but no new October launch. [verified]
- Reddit (Arctic Shift API; reddit.com blocks scripted access, and the archive rate-limited part of the query set, so coverage is partial): see §6 for the incident/demand posts. No post announcing a GUI rollback tool. [verified/partial]

## 3. Known neighbours — current state

### 3.1 Rollback CLIs

**bashward** — crates.io 0.1.1 (2026-05-04), MIT OR Apache-2.0, 43 total crate downloads; the canonical repo https://github.com/f4rkh4d/bashward returns 404 as of 2026-10-17 (a copy exists at `wholovesalife/bashward`, 0 stars, created 2026-05-04). Mechanism per docs.rs: Claude Code `PreToolUse` Bash hook reads `tool_input.command`, recognizes `rm`, `mv`, `cp`, `dd`, `sed -i`, `>`/`>>`, `truncate`, `tee`, snapshots targets with APFS clonefile ("`/bin/cp -c -R`"), logs to `~/.bashward/log.jsonl`, stores `~/.bashward/snaps/<id>/<path>`, always returns `{"continue": true}`; snapshots persist until `prune --days N`; "Write-path detection is a heuristic, not formal parsing." Status: abandoned. [verified]

**doover** — https://github.com/CaydenChik/doover, crate 0.2.3 (2026-08-15), 118 crate downloads, Apache-2.0 code + CC0 rules, 33 stars. "It doesn't ask for permission and it doesn't block anything." Claude Code only (`PreToolUse` + `PostToolUse`; `doover init` writes `~/.claude/settings.json` or `./.claude/settings.json --project`). 152 YAML reversibility rules (safe → irreversible), user overlays in `~/.doover/registry.d/` may strengthen but not weaken. Defaults: `DOOVER_KEEP_DAYS=7`, `DOOVER_MAX_STORE_BYTES=5 GiB`, `DOOVER_MAX_SNAPSHOT_MS=5000`, `DOOVER_UNKNOWN_POLICY=snapshot-cwd`; store `~/.doover` (0700/0600), SQLite journal, BLAKE3 content-addressed CoW snapshots. Commands: `log undo redo show diff status gc pin unpin init doctor hook`. Stated limits: not for malicious agents, not a backup, cannot undo remote effects, not encrypted, does not restore uid/gid. Open issue #3: "How do you decide a command isn't undoable?" (another author chose to refuse rather than let through). Rule example:
```yaml
rules:
  - id: my.dbtool
    match: { command: dbtool, subcommand: wipe }
    effect: destructive
    scope: { paths: positional }
    undo: snapshot-restore
```
[verified]

**Demo_CLI** — https://github.com/WePwn/demo_cli (7 stars, MIT per GitHub API; the AI Indigo listing shows a MIT/Apache conflict [likely]), Python ≥3.9, created 2026-06-18, last push 2026-07-19, v0.4.0-beta.8. Snapshots the target before `rm -rf`, `rmdir /s /q`, `Remove-Item -Recurse -Force`, `git reset --hard`, `DROP TABLE` (local DBs), writes hash-chained receipts, `demo_cli undo`; hard-blocks `terraform destroy`, `git push --force`, remote/cloud deletions, recursive-force delete with no recoverable target. Default is shadow (observe-only) mode; `demo_cli doctor` "fails loud" if the hook is not on PATH; install is `curl … | sh`. Claude Code + Cursor PreToolUse. Design line worth quoting: "recovery is the default; blocking is the fallback for the truly unrecoverable, not the default for everything." Dormant for 3 months. [verified]

**codex-rewind** — https://github.com/extracurricular-ai/codex-rewind (54 stars, Apache-2.0, Rust fork of Codex CLI; npm 1,329 downloads/30 d; last push 2026-09-27). Adds `/rewind` and `/redo` restoring files, not just conversation. Fork maintenance risk. [verified]

**claude-code-rewind** (holasoymalva, Aug 2025, 30 stars, Python, no commits since 2025-08-24) — earlier prior art, dead. [verified]

**ossnap** — PyPI 0.1.6 (2026-07-10), MIT, GitHub `nvt1904/ossnap` 0 stars. Backs up SSH keys/config, `.env` files and a repo list to a private GitHub repo (Fernet-encrypted) and restores them on a new Mac. Not an agent-rollback tool; not a competitor. [verified]

**cboone/snappy** — https://github.com/cboone/snappy (4 stars, MIT, Go, 19 open issues, push 2026-09-10). Whole-volume APFS local snapshots via `tmutil` on a schedule, mount-to-restore; macOS 11+; not agent-aware. Prior art for the "APFS snapshot" alternative: volume snapshots need `tmutil`, are whole-disk, and are deleted by the system under pressure (see Apple's local-snapshot semantics in the market report). [verified]

### 3.2 Blockers

**CC Safety Net** — https://github.com/kenryu42/cc-safety-net (repo moved from `claude-code-safety-net`), 1,645 stars, 86 forks, MIT, TypeScript, created 2025-12-25, pushed 2026-10-17; 74 npm versions, latest 2.6.12 (2026-10-15); npm downloads 54,206 for 2026-09-13…10-12 (up from 41,542 in the market report's window). Site: https://ccsafetynet.com. [verified]
- Supported agents (About): Amp Code, Antigravity CLI, Claude Code, Codex, Cursor, DeepSeek Harness, Devin CLI, GitHub Copilot CLI, Grok Build, Hermes Agent, Kimi Code, OpenClaw, OpenCode, Pi; install docs also cover Factory Droid and Gemini CLI.
- "It is not a sandbox: it does not contain processes, set filesystem permissions, or watch network egress." No snapshots, no undo.
- Install/ops: `npx -y cc-safety-net@latest install | doctor | update | uninstall`; `npx cc-safety-net gui` to pick Standard/Strict/Paranoid and toggle rules; rulebooks for Terraform/AWS/gcloud/Azure or custom JSON; team sharing by committing `.cc-safety-net/`; library API `checkCommand`; audit log in `~/.cc-safety-net`; "A broken config file never blocks anything" (fail-open).
- Rule IDs in `src/core/rules/destructive.ts` (2026-10-17): `git.reset-hard`, `git.reset-merge`, `git.clean-force`, `git.rm-force`, `git.push-force`, `git.push-delete`, `git.push-mirror`, `git.branch-force-delete`, `git.rebase-abort`, `git.merge-abort`, `git.tag-delete`, `git.reflog-delete`, `git.stash-drop`, `git.stash-clear`, `git.worktree-remove-force`, `git.checkout-force`, `git.checkout-double-dash`, `git.checkout-ref-path`, `git.checkout-pathspec-from-file`, `git.checkout-ambiguous`, `git.switch-discard-changes`, `git.switch-force`, `git.restore-worktree`, `git.restore-unstaged`, `git.ssh-env`, `git.alias-config`, `rm.recursive-force-root-or-home`, `rm.git-metadata`, `rm.recursive-force-dynamic-target`, `rm.recursive-force-home-cwd`, `rm.recursive-force-cwd-self`, `rm.recursive-force-outside-cwd`, `rm.recursive-force-paranoid`, the same family for `powershell.remove-item-*` and `cmd.recursive-delete-*`, `find.delete`, `find.delete-git-metadata`, `find.exec-rm-recursive-force`, `dd.device-write`, `mkfs.device`, `disk.erase`, `shred.target`, `redirect.block-device`, `interpreter.dangerous-command`, `interpreter.one-liner-paranoid`, `awk.system-dynamic`, `xargs.rm-recursive-force-dynamic`, `xargs.shell-dynamic`, `parallel.*-dynamic`, `shell.dynamic-structure`, `shell.dynamic-executable`, `raw-text.dangerous-command`. Note the absence of DB/ORM rules (no `DROP DATABASE`, no `prisma migrate reset`) in the destructive file; secret-path rules live in `secret-protection-rules.ts`.
- Issue-tracker facts (pitfalls): #236 "diskutil erase, wipefs, sgdisk, parted and redirects to a disk device are allowed at every safety level" (opened 2026-10-10, fixed 2026-10-11 via PR #237); #238 "Windows 2.6.8 secret-path false positives on PowerShell member access and Python report text" (`$_.key` blocked by `secret.ext-pattern.key`; the word `credentials` in a print string blocked by `secret.basename.credentials`; closed 2026-10-12); #242 DeepSeek Harness `ops_bash` tool "classified as unknown, so command rules never match" (closed 2026-10-12); five PRs opened on 2026-10-16 alone: "refuse shell argv whose options can re-enable execution or hide the -c body", "refuse blanks that bash and zsh keep inside a word", "deny when either the PowerShell or the POSIX reading of an auto command denies", "scan the executed command when the host sends it outside input.command", "withhold git discard relaxations when the repository can send git elsewhere". `docs/residual-risk.md`: "Strict mode's fail-closed promise is finite and checkable; standard's blocklist is not." `docs/secret-protection-known-limitations.md`: static parsing cannot follow paths reconstructed at runtime (`chr()`, hex, concatenation, globs) and the project deliberately does not chase them. [verified]

**MiSeGuard** (2026-09-10, MIT, 1 star, npm 49 downloads/30 d): deterministic MCP stdio proxy scoring tool calls; not hook-based. [verified]

### 3.3 Ports and processes

**LeftOpen** — https://github.com/SonghaiFan/leftopen, 129 stars, MIT, Swift (SwiftUI `MenuBarExtra`, no Dock icon), created 2026-09-16, v0.5.8 on 2026-10-13 (three releases Oct 9–13), `brew install --cask songhaifan/tap/leftopen`, macOS 14+, universal, Developer ID-signed and notarized; bundles Portless 0.15.7 and Node 24.14.0 (fixed project addresses). Attribution: "Walks up from the process's working directory to `.git`, `package.json`, `pyproject.toml`, `Cargo.toml` or `go.mod`, or resolves the owning `.app`"; groups Dev Servers "from a project, terminal, editor or agent" (how agent origin is detected is undocumented); distinguishes `127.0.0.1` from `0.0.0.0`/LAN binds. Closing: "Sends `SIGTERM` and re-checks process identity" ("re-verifies PID and start time"); if still listening after 5 s it is marked and "closing it again within two minutes sends `SIGKILL`"; launchd services via `brew services stop`, apps by quitting. CLI: `leftopen [list] | <port> | open <port> | url … | close <port> | --json`. No session or worktree attribution; polling interval and enumeration API not documented; no wiki (the market report's wiki link is dead). Issues: Intel support (#1, fixed), certificate prompt (#9), port allowlist (#10), Windows port PR (#2), Docker containers PR (#6). Daily GitHub release check is the only network call. [verified]

**PortKiller** — https://github.com/productdevbook/port-killer, 5,108 stars, MIT, Swift, v3.4.0 (2026-10-15; previous 3.3.3 in June), macOS 15+ and Windows (Linux tray added June 2026). "Auto-discovers all listening TCP ports", "Smart categorization (Web Server, Database, Development, System)", Kubernetes port-forwards, Cloudflare tunnels, "One-click process termination (graceful + force kill)", auto-kill rules for idle ports (PR #105), "deep kill" for ESTABLISHED connections (#87/#100). No project/agent attribution, no AI-agent feature. Open issue #75 (since 2026-01-03): memory "can reach ~2 GB, even when PortKiller is idle"; PRs #125 "stop rebuilding the UI on every background scan" and #127 "keep the menu bar app small when no window is open" landed/opened 2026-10-15; PR #117 "PortKiller 4 for macOS 27 and Swift 6.4" pending. [verified]

**port-kill** — https://github.com/treadiehq/port-kill (moved from kagehq), 2,043 stars, FSL-1.1-MIT, Rust, last push 2026-04-03. CLI + macOS status bar; cache cleaning with "timestamped backups before deletion" and `--restore-last`; MCP server shelling out to `port-kill-console`; guard mode `--auto-resolve`. Stale for 6 months. [verified]

**Port Menu** — https://github.com/wieandteduard/port-menu, 385 stars, MIT (README; the GitHub API reports no licence file), Swift, macOS 14+, v0.8.10 (2026-04-11), "scans for running dev servers every few seconds", shows git repo name, branch, port, uptime; stop/open/copy URL. Open: #3 "process naming for monorepos" (all 4+ processes show the repo name), #12 PR "Group ports by project and show process memory usage", #6 Docker/OrbStack ports, #10 update check error. No agent/session attribution. [verified]

**cmux** — https://github.com/manaflow-ai/cmux, 28,223 stars, Swift/AppKit on Ghostty; app GPL-3.0-or-later, server dirs (`web/`, `workers/ci-artifacts/`) BUSL-1.1; Homebrew cask `cmux` 58,552 installs/365 d, 4,664/30 d. "Sidebar shows git branch, linked PR status/number, working directory, listening ports, and latest notification text" per workspace; `cmux hooks setup` installs agent hooks; "cmux does not checkpoint arbitrary live process state." Ports only for panes it hosts. [verified]

**Superset** — https://github.com/superset-sh/superset, 15,291 stars, Elastic License 2.0, TypeScript; cask 2,745 installs/365 d. "Ports are detected per workspace, so every worktree gets its own preview"; "Ports are grouped by the workspace that owns the process"; "Stop a process by clicking its port"; "Superset does not assign per-workspace port ranges"; "Worktrees separate working files; they do not sandbox processes". Only inside its own IDE. [verified]

**AgentPeek** — https://agentpeek.app (paid one-time, 3-day trial, Apple silicon, macOS 14+; Product Hunt launches 2026-05-10 and 2026-06-30, 325 followers). "AgentPeek watches ports 3000–9999 for listening dev servers", labels frameworks/runtimes, shows "the project folder taken from the server's working directory" and uptime; stop "after a safety check verifies the target process"; detection method, interval and signal not documented; no session/worktree attribution. [verified for docs; launch figures from Product Hunt page]

**Claude Desktop "Dev servers" menu** — code.claude.com/docs/en/desktop: "Start or stop servers, or stop them all at once, from the Dev servers menu"; servers come from `.claude/launch.json` that Claude writes (`runtimeExecutable`, `runtimeArgs`, `port`); it is a launcher for configured servers, not a radar of arbitrary listeners. Worktrees live in `<project-root>/.claude/worktrees/`, removed via the sidebar archive icon or "Auto-archive after PR merge or close". No automatic process termination for local sessions is documented; for Windows remote machines the doc warns "check the machine for programs that Claude Code started, because they can keep running." [verified]

### 3.4 Menu bar session apps and keep-awake

- **Agent Bar** (maker "Aayush", Product Hunt, ~8 months old per feedbagel): "a native GUI for Claude Code" — project picker, voice, streaming tool calls, approve/auto-approve. No snapshots, ports or blocking. GitHub/licence/price not found. [likely]
- **AgentBar (jreed91)** — 0 stars, MIT, Swift, push 2026-10-05: read-only notifier for Claude Code (via a Claude Code mod observing `UserPromptSubmit`, `AskUserQuestion`, `PermissionRequest`, `PermissionDenied`, `Elicitation`, `PostToolUse(Failure)`, `Stop`, `SubagentStop`, `SessionEnd`, `StopFailure`) and Copilot CLI; "it never blocks your session and never answers for you." [verified]
- **agent-beacon** — 3 stars, MIT, Swift, last push 2026-06-04; status lights (completed/needs review/failed/running) with click-to-focus; `curl | bash` installer that removes quarantine. Dormant. [verified]
- **Adrafinil** — 515 stars, MIT, v1.12.0 (2026-10-13), `brew install --cask adrafinil` (175 installs/365 d, 48/30 d); hooks for 10 agents (Claude Code, Codex, Cursor, Gemini CLI, Devin, Aider, Hermes, OpenCode, Cline, Pi), per-session acquire/release holds, optional process detection, thermal cutout, privileged helper for closed-lid; **requires macOS 26.4+** (a macOS 15 backport exists at `valentine/adrafinil` [unverified]). [verified]
- **Agents Sleep Preventer** (CharlonTank) — 15 stars, MIT, Rust, v5.3.0, macOS + Windows; keep-awake + local dictation + auto-types "continue" after a network drop. [verified]

### 3.5 Disk

- **Mole** — https://github.com/tw93/Mole, 70,680 stars, GPL-3.0 CLI (`brew install mole`: 311,470 installs/365 d, 49,261/30 d), V1.61.0 on 2026-10-16. CLI: `mo clean` (caches, logs, dev artifacts, leftovers), `mo purge` for `node_modules`/`target`/`.build`/`dist` under `~/Projects`, `~/GitHub`, `~/dev` "and supported agent worktree containers"; "Purge removes rebuildable artifacts inside worktrees, never the worktrees themselves"; artifacts with activity in the last 7 days unselected by default; protects dirs with deployment keypairs, nested git repos or git-tracked files. Mac app: "$19 one-time license for 2 Macs", "Each tool works twice for free", macOS 14+, proprietary; "AI Cleanup & Care" page lists "old versions, caches, old sessions past a retention window, cleanable worktrees and idle command-line tools" for Cursor (cursor-agent releases), Codex, Claude Code, OpenCode; "Sessions used in the last 24 hours are never listed"; sessions stay unchecked until confirmed; "The Clean scan itself never touches AI session histories, memories, plans or local models." [verified]
- **SpaceGuard**, **Lopper**, **fresh** — see §2.3.
- Claude Code's own retention (code.claude.com/docs/en/claude-directory): `~/.claude/file-history/<session>/` holds pre-edit checkpoint snapshots ("100 most recent checkpoints"); the `cleanupPeriodDays` sweep (default 30 days) covers transcripts, `file-history`, `tasks/`, `shell-snapshots/`, `backups/`, debug logs, per-session scratchpads under `/private/tmp/claude-<uid>/<project>/<session-id>/scratchpad/`; `claude purge` deletes one project's transcripts, `tasks/`, `debug/`, `file-history/` entries. CHANGELOG 2.1.246: "Fixed the background retention sweep removing git worktrees under `.claude/worktrees/` that you created yourself"; 2.1.157: worktrees "orphaned after the 30-day job retention sweep". [verified]

### 3.6 Paid GUI backup apps

- **Vibe Backup** — App Store id6752509487, v1.0.3 (2026-09-12), listed Free, 0 ratings, macOS 13.5+, 2.0 MB. Website: Free = 3 active projects, unlimited manual backups, restore latest only (the App Store text still says "1 project, 3 backups/day"); Pro Lifetime $14.99 one-time (struck $29.99; the market report's $4.99 is outdated). Triggers: hotkey ⌘⌥B (~300 ms), every `git commit`, schedule/"smart interval" (Pro), and an MCP server (stdio, 11 tools incl. `create_checkpoint`, diff, read, restore) for Claude Code, Cursor, Codex, Devin, Windsurf, Zed — i.e. the agent is asked to checkpoint, nothing is enforced. Storage: `.vbrepo` snapshot store (SHA-256 dedup + LZFSE) or ZIP; AES-256 encryption; cloud sync; each restore first creates a safety checkpoint. No shell-command interception, no file watching described. [verified]
- **Checkpoints for Claude Code** ("Claude Diff", Morten Punnerud) — App Store id6751541546, $7.99, v1.4 (2026-05-18), released 2025-08-27, 0 ratings, macOS 13.5+. "Smart integration with Claude Desktop through MCP protocol", one-click checkpoints, visual diff, "Preserve or remove newer checkpoints when restoring". Not hook-based, not Bash-aware, Claude Desktop oriented. [verified]

### 3.7 Vendors

**Claude Code** (CHANGELOG top: 2.1.302; checkpointing doc) [verified]
- Checkpointing: "Checkpointing does not track files modified by Bash commands" (examples `rm file.txt`, `mv old.txt new.txt`, `cp source.txt dest.txt`); subagent edits "usually" not captured; external/concurrent-session changes not tracked; symlinked/hard-linked paths skipped ("Restored the code, but skipped N files"); "Claude Code keeps file snapshots for the 100 most recent checkpoints in a session"; snapshots deleted by the retention sweep "by default about 30 days after the session last saved one"; rewind via `/rewind` or Esc Esc with Restore code / conversation / both / Summarize.
- Background commands: 2.1.285 introduced a 30-minute limit; **2.1.288: "Changed the background command time limit to apply only in unattended sessions (`-p`, Agent SDK, CI, cloud); terminal, desktop app and VS Code sessions have no limit"**; 2.1.274: stopped "only when memory is critically low"; 2.1.271: fixed starting a second dev server after compaction; **2.1.300: "Changed exit to force-kill background commands still running 1.5 seconds after being asked to stop"** and "Fixed SessionEnd hooks sometimes not running when you exit while a background command is still running"; 2.1.257: fixed commands detached with `setsid`/`timeout` surviving exit. Issue #43944 (background processes not cleaned up) remains closed as not planned; #93794 (39 orphaned `yes` processes) open with 0 comments.
- Hooks (code.claude.com/docs/en/hooks): events SessionStart, Setup, UserPromptSubmit, UserPromptExpansion, PreToolUse, PermissionRequest, PermissionDenied, PostToolUse, PostToolUseFailure, PostToolBatch, Notification, MessageDisplay, SubagentStart, SubagentStop, TaskCreated, TaskCompleted, Stop, StopFailure, TeammateIdle, InstructionsLoaded, ConfigChange, CwdChanged, DirectoryAdded, FileChanged, WorktreeCreate, WorktreeRemove, PreCompact, PostCompact, PreModelSwitch, PostModelSwitch, Elicitation, ElicitationResult, SessionEnd. `FileChanged` uses a filesystem watcher but the matcher "is split on `|` and each segment is registered as a literal filename in the working directory" (not usable for project-wide watching). `WorktreeCreate` does not fire "When Claude runs `git worktree add` through the Bash tool"; configuring it "replaces that default git behavior". `SessionEnd` hooks share a 1.5 s budget (extendable to 60 s). Timeouts: command hooks 600 s; "A timed-out command… PreToolUse hook does not block the tool call unless `"onFailure": "block"` is set (requires Claude Code v2.1.295+)". Async hooks "can't block or control Claude's behavior". PreToolUse decisions `allow|deny|ask|defer`, precedence "deny > defer > ask > allow"; exit 2 blocks (not for PermissionRequest); 2.1.300: `updatedInput` validated, unknown keys dropped. 2.1.302: "at most 12 of one event run at a time; the rest wait their turn" (prompt and agent hooks).
- Mods (in-process TypeScript hook modules, `hooks.json` → `{"modules": ["./register.tsx"]}`, GA 2.1.287 per Receipts README; `claude plugin validate --strict` lists hooks and `$` calls) are the mechanism behind claude-time-machine, Nexus, Receipts, AgentBar. Mods "run with your permissions and are not sandboxed".
- Worktrees: 2.1.301 "Fixed quitting removing a worktree made by a `WorktreeCreate` hook without asking when it may hold unpushed commits"; 2.1.300 fixed plugin WorktreeCreate/Remove hooks not running with `--worktree`. Reddit Oct 16: "Why did they remove the worktree toggle?" (desktop UI change) [verified, title only].
- Sandbox: `/sandbox` renamed "Sandbox commands" (2.1.300); several macOS symlink/glob fixes in 2.1.299.

**Codex** [verified]
- #9203 "Please make /undo back": open since 2026-01-14, latest activity 2026-10-13, labels TUI/enhancement/session/CLI; maintainer etraut-openai (2026-01-16): the previous implementation "had problems"… "it will need to be redesigned"; no linked PR, no timeline. Reaction count hidden on the page ("Reactions are currently unavailable"); third parties cite 522 👍 [likely]. PR #8424 "chore: un-ship undo" merged 2025-12-22 after #8214 "/undo destructively interacts with git staging". #11626 "/rewind checkpoint restore that reverts both chat context and Codex-applied code edits": open since 2026-02-12, latest 2026-10-10, no commitment; comments note Double-Esc restores conversation only, the IDE extension's Undo toolbar "can disappear when edits happen via shell". Both threads are now used as marketing surfaces by snap-back and agentckpt.
- Hooks (learn.chatgpt.com/docs/hooks): `~/.codex/hooks.json`, `~/.codex/config.toml [hooks]`, `<repo>/.codex/hooks.json|config.toml` (project layer must be trusted); events PreToolUse, PermissionRequest, PostToolUse, PreCompact, PostCompact, UserPromptSubmit, SubagentStart, SubagentStop, Stop, Interrupt, SessionStart, SessionEnd (no Notification); block via exit 2 or `permissionDecision: "deny"`; "`PreToolUse` doesn't support `ask`"; non-managed hooks "must be reviewed and trusted before they run… Codex records trust against each hook's current hash", `/hooks` to trust, `--dangerously-bypass-hook-trust` for one run; async hooks can't block; 600 s default timeout, SessionEnd/Interrupt 1 s (max 3 s); "a useful guardrail, not a complete enforcement boundary".
- Changelog Sep 28 – Oct 15: CLI 0.163.0 (Oct 15) "Restart a managed background server from `/daemon`", bubblewrap sandbox integrity checks; 0.162.0 (Oct 8) "Add tools for creating and listing managed Git worktrees from trusted local projects"; 0.161.0 (Oct 7) "Prune diagnostic logs periodically by age and database size", "Clean up process groups for failed shell snapshot captures", "Background tasks retain their originating turn's permissions"; 0.160.0 (Oct 1) "background reclamation of unused log database space". The market report's "Codex creates a worktree by default since Sept 22" could not be located in the changelog (the page shows Sep 28 onward; 0.154.0 describes worktrees as experimental `--worktree`/`/worktree`) [unverified].
- Process issues still open: #42244 "Show agent-started dev servers and background processes in Codex Desktop" (2 reactions, 5 comments), #25772 orphaned Next.js after Esc, #12491 "1300+ zombies, 37GB" (reopened, 7 reactions, 38 comments).

**Cursor** [verified]
- Checkpoints doc: "Checkpoints save snapshots of your codebase during an Agent session… before making significant changes, capturing the state of all modified files"; "Checkpoints are stored locally and separate from Git"; "Restoring a checkpoint reverts files only"; nothing about terminal commands, deleted files or retention. Changelog Sep–Oct 2026 has no checkpoint entries (newest 2026-10-16 "Cloud Agent Canvases and Environment Improvements"; Oct 6 "Remote control for local agents"). CLI changelog July 2026 added a `/checkpoint` command [likely, third-party summary].
- Hooks (cursor.com/docs/agent/hooks): `~/.cursor/hooks.json` and `<project>/.cursor/hooks.json`, `"version": 1`; events include `beforeShellExecution`, `afterShellExecution`, `beforeMCPExecution`, `beforeReadFile`, `afterFileEdit`, `beforeSubmitPrompt`, `preToolUse`, `postToolUse`, `sessionStart`, `sessionEnd`, `stop`, `workspaceOpen`; `beforeShellExecution` payload: `command`, `cwd`, `sandbox` (bool) plus `conversation_id`, `generation_id`, `workspace_roots`; output `{"permission": "allow|deny|ask", "user_message", "agent_message"}`; exit 2 blocks; "Crashes, timeouts, and other non-zero exit codes fail open unless `failClosed: true`"; "Cursor supports loading hooks from third-party tools like Claude Code", `CLAUDE_PROJECT_DIR` alias; precedence deny > ask > allow across Enterprise → Team → Project → User.
- Incident in window: r/cursor 2026-10-11 "Cursor agent ran a recursive rmdir from C:\ and wiped ~600 GB" (incident Oct 7, Windows, Pro+, 50 points, 131 comments; author stopped TRIM and recovered himself; asks for "never delete outside the project folder / never touch a drive root / always ask before any recursive delete").

**Gemini CLI / Antigravity CLI** [verified for docs text; the renaming statement is the doc's own note, tagged likely]
- Hooks in `.gemini/settings.json` / `~/.gemini/settings.json`; events SessionStart, SessionEnd, BeforeAgent, AfterAgent, BeforeModel, AfterModel, BeforeToolSelection, BeforeTool, AfterTool, PreCompress, Notification; exit 0 + `{"decision":"deny"}` preferred, exit 2 aborts; env `GEMINI_PROJECT_DIR`, `GEMINI_SESSION_ID`, `GEMINI_CWD`, `CLAUDE_PROJECT_DIR`. Doc page notes "Gemini CLI was replaced by Antigravity CLI on June 18, 2026" [likely]. cc-safety-net and Superset list both names.

## 4. Exact schemas and copy-pasteable configs

### 4.1 Claude Code PreToolUse (what every hook-based competitor consumes)

settings.json (user `~/.claude/settings.json` or project `.claude/settings.json`):
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "/usr/local/bin/airbag hook claude pre", "timeout": 10, "onFailure": "block" }
        ]
      }
    ],
    "PostToolUse": [
      { "matcher": "Bash|Edit|Write|MultiEdit|NotebookEdit",
        "hooks": [ { "type": "command", "command": "/usr/local/bin/airbag hook claude post", "async": true } ] }
    ],
    "SessionStart": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/airbag hook claude session-start" } ] } ],
    "SessionEnd":   [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/airbag hook claude session-end", "timeout": 1 } ] } ],
    "WorktreeCreate": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/airbag hook claude worktree-create" } ] } ],
    "WorktreeRemove": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/airbag hook claude worktree-remove" } ] } ]
  }
}
```
(Proposal for Airbag; field names and semantics are from the hooks reference. Caveat: configuring `WorktreeCreate` replaces Claude Code's default `git worktree` behaviour, so an Airbag hook there must create the worktree itself or be omitted; see §9.)

stdin for PreToolUse (doc example):
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
  "tool_input": { "command": "npm test", "description": "Run test suite", "timeout": 120000, "run_in_background": false },
  "tool_use_id": "toolu_01ABC123..."
}
```
stdout to decide:
```json
{ "hookSpecificOutput": { "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Destructive command blocked by hook" } }
```
`permissionDecision` ∈ `allow | deny | ask | defer`; `updatedInput` "Replaces the entire input object"; exit code 2 blocks with stderr as the reason; any other non-zero code proceeds. PostToolUse stdin adds `tool_response` and `duration_ms`. SessionEnd stdin has `reason` ∈ `clear | resume | logout | prompt_input_exit | other` and a 1.5 s default budget. [verified]

### 4.2 Codex hooks.json (`~/.codex/hooks.json`)
```json
{
  "PreToolUse": [
    { "matcher": "Bash",
      "hooks": [ { "type": "command",
                   "command": "/usr/local/bin/airbag hook codex pre",
                   "statusMessage": "Airbag: snapshot before command" } ] }
  ]
}
```
Same stdin family (`session_id`, `transcript_path`, `cwd`, `hook_event_name`, `model`, `turn_id`, `tool_name`, `tool_use_id`, `tool_input`); block with exit 2 or the same `hookSpecificOutput` JSON; no `ask`; the user must trust the hook once in `/hooks` (hash-pinned; an updated binary path or args re-prompts). [verified]

### 4.3 Cursor hooks.json (`~/.cursor/hooks.json`)
```json
{
  "version": 1,
  "hooks": {
    "beforeShellExecution": [ { "command": "/usr/local/bin/airbag hook cursor pre", "timeout": 10, "failClosed": true } ],
    "afterShellExecution":  [ { "command": "/usr/local/bin/airbag hook cursor post" } ]
  }
}
```
stdin: `command`, `cwd`, `sandbox`, `conversation_id`, `generation_id`, `workspace_roots`; stdout `{"permission":"allow|deny|ask","user_message":"…","agent_message":"…"}`; exit 2 blocks. Cursor also loads Claude Code hooks (double-execution risk if Airbag installs both). [verified]

### 4.4 Gemini / Antigravity CLI (`~/.gemini/settings.json`)
```json
{ "hooks": { "BeforeTool": [ { "matcher": "run_shell_command",
    "hooks": [ { "name": "airbag", "type": "command", "command": "/usr/local/bin/airbag hook gemini pre", "timeout": 10000 } ] } ] } }
```
Block with exit 0 + `{"decision":"deny"}` (preferred by the doc) or exit 2. The shell tool name `run_shell_command` is from memory [unverified]; `timeout` is in milliseconds per the doc example. [doc fields verified]

### 4.5 Competitor storage layouts worth copying
- doover: `~/.doover/` (0700), SQLite journal + BLAKE3 CAS; caps `DOOVER_KEEP_DAYS=7`, `DOOVER_MAX_STORE_BYTES=5 GiB`, `DOOVER_MAX_SNAPSHOT_MS=5000`. [verified]
- claude-time-machine: bare repo `~/.claude/time-machine/<project>/` with `GIT_WORK_TREE=<project>`, snapshot = `git add -A` into own index + `git write-tree`/commit; `.tmignore`; mode 700. [verified]
- takeback: `~/.takeback/` separate git repo, 30-day prune, `takeback prune --keep 7d`. [verified]
- bashward: `~/.bashward/log.jsonl` + `snaps/<id>/<path>` via `cp -c -R` (APFS clonefile). [verified]
- agentckpt: in-project `.agentckpt/` CAS, `--max-bytes` 10 MiB, `prune --keep 50`. [verified]

## 5. Best ideas worth borrowing (with attribution)

1. **Before+after snapshot per tool call, record what actually changed** (claude-time-machine). Removes the write-target guessing that sank bashward; gives per-step undo and exact "files touched by `rm -rf src/legacy`" labels. Cost: two snapshots per Bash call; mitigate with a read-only allowlist (`ls`, `grep`, `git status`, `cat`, `rg`, `find` without `-delete`/`-exec`) and with FSEvents-driven dirty tracking so the "after" snapshot only hashes changed paths.
2. **Agent-independent watch mode with 1.5 s debounce** (takeback `watch`) — exactly Airbag's FSEvents path; takeback's size guard (non-git folder >5,000 files or >500 MB refuses to auto-start) is a sane default for accidental home-directory selection.
3. **Recovery first, block only the unrecoverable; observe-only mode first** (Demo_CLI, doover). Demo_CLI's shadow mode plus `doctor` that "fails loud" when the hook is installed but unreachable; doover's `UNKNOWN_POLICY=snapshot-cwd`.
4. **A CC0 reversibility registry of 152 rules** (doover `registry/`) can be imported legally into Airbag's rule table as a starting classification of commands (safe → irreversible). Verify the CC0 file headers before vendoring.
5. **Every restore is itself a snapshot** (claude-time-machine, takeback, Vibe Backup) and **conflict detection between user and agent edits** (claude-time-machine) — Airbag's "snapshot before rollback" principle, plus a refusal path when the working tree changed since the snapshot.
6. **Sensitive-change flags** (claude-time-machine: CI config, dependency manifests, install scripts, secrets files, new executables, mass deletes) — cheap to compute from the diff and a good badge trigger that is not a "command blocked".
7. **Kill protocol** (LeftOpen): SIGTERM → re-verify PID + process start time → wait 5 s → mark → SIGKILL only on an explicit second action within 2 min; `brew services stop` for launchd-managed services; show sibling ports before acting. Also PortKiller's lesson that killing the LISTEN owner can leave ESTABLISHED peers.
8. **Cheap sizing and conservative preselection** (SpaceGuard: `getattrlistbulk`, size×staleness×safety ranking, dirty worktrees never preselected, 20–40 MB RAM, one check per minute; Mole: sessions used in the last 24 h never listed, 7-day activity window unselected by default; Lopper: re-check right before removal; `git worktree remove` keeps the branch). Move to Trash rather than `rm` where possible (Agent Deck does this for session data).
9. **Session registry sources** (Agent Deck): `~/.claude/sessions/<pid>.json` watched for changes + `claude agents --json`; async hooks for activity; approvals over an owner-only Unix socket with peer-uid check; a "Repair hooks" health action. Also its local-build-with-CLT installer as a fallback distribution path while notarization is set up.
10. **Operator ergonomics** (cc-safety-net): `explain --json "<cmd>"` dry-run classifier, `doctor`, presets, team-shared config dir, audit log with rule IDs, `--force-with-lease` allowed; its `residual-risk.md` discipline for not chasing parser fidelity in the default mode.
11. **Local-model second opinion** (laya-guard, ~90 ms CPU) is a possible v2 "ask" tier for commands the regex layer cannot classify; not for v1.
12. **Trust UX for hooks** (Codex `/hooks` hash-pinned trust; laya-guard's install that "shows the diff first, backs up your settings, then sends two test calls through the hook") — Airbag's one-click hook install should show the diff, back up settings, and self-test.

## 6. Pitfalls observed in issue trackers and posts

| Pitfall | Evidence | Implication |
|---|---|---|
| Text-based blocking is unbounded | cc-safety-net: 5 parser PRs on 2026-10-16; #236 disk-erase commands allowed at all levels until Oct 11; `residual-risk.md` ("standard's blocklist is not" finite); r/ClaudeCode 2026-10-14: `Bash(git push *)` deny rule misses `git -C . push`, `bash -c 'rm -rf build/'`; r/ClaudeCode 2026-10-11: agent bind-mounted the project into Docker and ran `rm -rf` inside it | Snapshot before every command; keep the breaker to a short, high-confidence list; unwrap `bash -c`/`sh -c`/`git -C`/`xargs`/`find -exec`; document "safety net, not security boundary" |
| False positives in broad rules | cc-safety-net #238 (`$_.key`, the word `credentials` in a print string) | Do not ship secret-path heuristics in v1; keep rule IDs explainable; provide `airbag explain` |
| Tool-name drift across agents | cc-safety-net #242 (`ops_bash` unknown → rules never match); Claude Code has `Bash` and `PowerShell`; Cursor `beforeShellExecution`; Grok `run_terminal_cmd` | Per-agent adapter table with explicit tool names; treat unknown tools as "snapshot cwd" not "ignore" |
| Fail-open defaults | cc-safety-net "A broken config file never blocks anything"; Cursor non-zero exit "fail open unless `failClosed: true`"; Claude Code timed-out PreToolUse hook does not block unless `onFailure: block` (2.1.295+); exit 1 is non-blocking | Breaker evaluation must be in-binary with no IPC dependency and finish in milliseconds; set `onFailure: block`/`failClosed` only for the breaker hook, never for the snapshot hook |
| Hook UX friction | Codex hooks skipped until trusted in `/hooks`; takeback FAQ "Why does takeback say there are no checkpoints?" lists this; Codex PreToolUse has no `ask` | Onboarding must verify the hook fired (self-test) and explain the Codex trust step; on Codex a "would ask" rule degrades to allow+snapshot or deny |
| Restore bugs in vendors | Claude Code 2.1.260 "`/rewind` reporting success when checkpoint backup files were missing"; 2.1.275 "restoring a zero-filled or truncated file"; 2.1.216 symlinks/hard links skipped; Codex un-shipped `/undo` after staging corruption (#8214, PR #8424); Copilot CLI restore ran `git clean -fd` (market report) | Verify restored content hashes; never touch the user's `.git`; handle symlinks/hard links explicitly; refuse partial restores or report them (claude-time-machine reports "incomplete" with a diff) |
| Secrets in snapshots | takeback cannot restore `.gitignore`d files; claude-time-machine excludes `.env`/keys and cannot undo edits to them; agentckpt stores metadata only | Decide explicitly (see §9): Airbag's plan to snapshot `.env` locally with 0600 is defensible but must be a visible setting |
| Snapshot cost on large repos | claude-time-machine: "two full snapshots per Bash call"; takeback first checkpoint 3.6 s/850 files; doover 5 s timeout; agentckpt skips >10 MiB | Budget: dirty-set tracking via FSEvents between hook calls; size caps per file; background packing |
| Memory/CPU in menu bar pollers | PortKiller #75 (~2 GB idle), PRs #125/#127 (UI rebuilt on every scan); HN "I wouldn't want that running every 5 seconds" about `lsof` polling (market report) | libproc diff-based polling, no SwiftUI re-render unless state changed; measure RSS over 24 h |
| Kill side effects | PortKiller #87 ESTABLISHED peers remain; LeftOpen identity re-check | Show process tree + peers; re-verify PID/start time before signalling |
| Attribution gaps | Port Menu #3 (monorepo: all processes named by repo); LeftOpen project-only; launchd reparenting (#43944) | Session/worktree attribution requires the live registry; fall back to cwd walk-up like LeftOpen |
| Worktree cleanup footguns | Claude Code 2.1.246 (sweep removed user worktrees under `.claude/worktrees/`), 2.1.301 (removed worktree with unpushed commits without asking); Lopper "no trash" | Never preselect dirty/unpushed worktrees; keep branches; move to Trash; show plan first |
| macOS version churn | Adrafinil macOS 26.4+; PortKiller 4 targets macOS 27/Swift 6.4; r/ClaudeCode reports of macOS 27 | macOS 14 floor is still shared by LeftOpen, Port Menu, Mole app, AgentPeek, Agent Deck; keep it |
| Agent writes outside the project | Cursor 600 GB wipe from `C:\`; home-directory wipes; takeback/time-machine cover nothing outside the folder | Only the breaker protects outside-project paths; make the "outside project" rule the strongest one |

## 7. Direct new competitors since 2026-10-09 and how Airbag differs

Strictly in the Oct 9–16 window: agentckpt (Oct 9), laya-guard (Oct 11), Nexus mod (Oct 11), h-guard (Oct 12, empty), rowbit (Oct 12), keelyard (Oct 12), ShedKeeper (Oct 13). Slightly earlier but in the same wave: claude-time-machine (Oct 2), snap-back (Oct 3), Agent Deck (Oct 3), takeback (Oct 8), AI Undo (Oct 8). [verified]

| Competitor | Overlap with Airbag | Where Airbag differs |
|---|---|---|
| takeback | project snapshots per turn via hooks; `watch` mode; 30-day retention; Codex + Claude Code | Airbag snapshots per command (not per turn) and on FSEvents simultaneously, exposes a GUI timeline with file/folder/project rollback, adds the breaker and the radar, is native (no Node runtime per hook call), and works on `.env` by policy |
| claude-time-machine | per-tool-call snapshots, step undo, sensitive flags, conflict detection | Airbag is outside the agent process (works with Codex, Cursor, Gemini CLI and when the agent is gone), GUI not TUI band, no dependency on Claude Code mods |
| snap-back / agentckpt / AI Undo | shadow store, CLI undo | Same as above; these have no automatic trigger beyond hooks/manual |
| laya-guard / Nexus / Skillkeel / cc-safety-net | pre-execution blocking | Airbag blocks a short list and snapshots the rest; blocking without recovery is the segment leader's gap |
| Agent Deck | session registry from `~/.claude/sessions/<pid>.json` + hooks; cleanup of Claude Code session data | Airbag's registry feeds snapshot signatures and port attribution; Agent Deck is a control/usage panel (usage rings are an Airbag non-goal) |
| SpaceGuard / Lopper | agent worktree discovery and cleanup | Airbag v1.1 adds "belongs to a finished session" from the registry; SpaceGuard is a good reference implementation and is MIT |
| rowbit | DB write preview/undo | Out of scope; Airbag only blocks `DROP DATABASE`/`prisma migrate reset --force` |

No new entrant is a native GUI, none combines two of Airbag's four pillars, and none is above 30 stars. The combination remains open; the risk is that one of the hook-based snapshot CLIs grows a menu bar front end (takeback already publishes to npm and Homebrew would be trivial).

## 8. Name collision report: "Airbag"

| Registry | Result (2026-10-17) | Tag |
|---|---|---|
| Homebrew | No formula or cask `airbag`/`air-bag` (`formulae.brew.sh` 404; `brew search airbag` returns only `ariang`) | [verified] |
| Mac App Store | No macOS app with "airbag" in the name (iTunes Search API, 50 results) | [verified] |
| iOS App Store | "Airbag" by Airbag Technologies SAPI de CV (bundle `io.airbagtech.AirbagAppDriver`, Mexico, driving-habits rewards app, Productivity, released 2025-02-19) — different category | [verified] |
| npm | `airbag` taken (0.1.0, 2026-02-10, MIT, "Execution Orchestration Layer for JavaScript/TypeScript — … retries, timeouts, and circuit breaking", no repo); `airbag-cli`, `@airbag/cli`, `airbag-app`, `air-bag` free; related: `dsh-airbag` (DeepSeek Harness "safety belt", 0.4.2, 2026-08-15), `@hussainu6/npmsafe` ("seatbelt & airbag for safe npm publishing") | [verified] |
| PyPI | `airbag` 0.0.0 "WIP" placeholder (internetimagery) | [verified] |
| crates.io | `airbag` 4.1.0 (2024-11-03), "Library for handling errors and panics using 3rd party services" | [verified] |
| GitHub user/org | `airbag` exists (User, created 2011-05-29, 1 public repo); `airbag-app`, `airbaghq`, `airbagdev`, `getairbag`, `airbag-sh` free | [verified] |
| GitHub repos (399 with "airbag" in name) | Dev-tool neighbours: `n-bharath-chowdary/airbag` (2026-08-19, MIT, 2 stars, Python) "The airbag for your git push. Blocks leaked API keys, repo waste… Works with Claude Code, Cursor, Codex, Windsurf, git hooks and CI" — closest semantic collision, same audience, pre-commit scope; `venkateshamatam/airbag` (2026-05-03, 1 star) "runtime safety layer for browser agents" with a desktop confirmation modal; `airbag-cli/airbag` (Java ANTLR grammar testing, GPL-3.0, 2 stars); `Soluto/airbag` (24 stars, OAuth2 sidecar, 2022); `martensi1/airbag` (POSIX crash handler); `vmalloc/airbag` (Rust error reporting). No repo named airbag with >30 stars in developer tooling | [verified] |
| HN (45 days) | No story about a dev tool named Airbag | [verified] |
| Domains | `airbag.dev`, `airbag.app`, `airbag.sh`, `airbag.tools`, `getairbag.com` returned no HTTP response (no server or NXDOMAIN) — registration status unknown | [unverified] |
| Trademark | Not searched | [unverified] |

Assessment: the name is free in every distribution channel Airbag plans to use (Homebrew cask, GitHub repo under a new org, Mac notarized app), but `airbag` on npm and the GitHub user `airbag` are taken, and the metaphor is already used by a same-audience git-push guard (2 stars, dormant since 2026-08-19). Use an org such as `airbag-app`/`airbaghq`, a cask named `airbag`, and avoid shipping anything on npm under the bare name.

## 9. What this means for Airbag — concrete design implications

1. **Snapshot engine = hidden git store with the project as work tree, before+after per command, plus FSEvents.** The hypothesis is validated by two independent implementations (claude-time-machine, takeback) and their numbers (0.2–0.4 s per snapshot on 67k files; ~0.1 s per hook on small projects; 284→44 MB after packing). Add what they lack: (a) FSEvents dirty-set tracking between hook calls so the "after" snapshot does not rescan, (b) a read-only command allowlist to skip snapshots, (c) size caps per file (agentckpt 10 MiB) and a non-git-folder guard (takeback 5,000 files/500 MB), (d) one ref per snapshot so retention is `update-ref -d` + `gc`, as planned.
2. **Hook binary contract.** PreToolUse hook: parse → classify → snapshot → emit `{"hookSpecificOutput":{"permissionDecision":"allow"}}` or `deny` with a reason; exit 2 only for deny; never exit 1. SessionEnd must write the registry in <1.5 s (Claude Code budget) and <1 s (Codex default). Use `"onFailure": "block"` (Claude Code ≥2.1.295) and `failClosed: true` (Cursor) only on the breaker; keep the snapshot hook fail-open so a slow disk never stalls the agent. Register `WorktreeCreate/WorktreeRemove` only if Airbag is willing to perform the `git worktree add` itself (configuring the hook replaces the default); otherwise learn worktrees from `SessionStart.cwd` and `.claude/worktrees`, `~/.codex/worktrees`, `~/.cursor/worktrees` scans (SpaceGuard's list).
3. **Breaker philosophy: recoverable-first.** Mirror Demo_CLI/doover: snapshot and allow anything whose target is inside a protected project; block only rules whose effect cannot be snapshotted (outside-project or `~` recursive deletes, `git push --force` without `--force-with-lease`, `git push --delete/--mirror`, `DROP DATABASE`, `prisma migrate reset --force`, `terraform destroy`, disk-device writes). Ship ≤20 rule IDs, named like cc-safety-net's (`rm.recursive-force-outside-project`), with `airbag explain "<cmd>"` and a shadow mode for the first week. Unwrap `bash -c`, `sh -c`, `zsh -c`, `git -C`, `xargs`, `find -exec`, `&&`/`;`/`|` chains; treat anything the tokenizer cannot parse as "snapshot cwd, allow". State explicitly in the UI and README that a determined agent can bypass a hook (Docker bind-mount case).
4. **Per-agent adapter table** (tool names, decision vocabulary, trust step): Claude Code `Bash|PowerShell` with allow/deny/ask/defer; Codex `Bash` with allow/deny only and a mandatory `/hooks` trust step; Cursor `beforeShellExecution` with allow/deny/ask and `failClosed`; Gemini/Antigravity `BeforeTool` with `{"decision":"deny"}`. Detect Cursor loading Claude Code hooks to avoid double snapshots. Snapshots via FSEvents do not depend on any of this.
5. **Secrets policy must be an explicit setting.** Competitors split three ways (takeback: never restore ignored files; time-machine: exclude secrets, flag edits; agentckpt: metadata only). The documented loss case "agent edited/deleted `.env`" argues for snapshotting inside the project with 0700/0600 permissions and no sync, with a visible toggle and `.airbagignore`.
6. **Radar attribution needs the live registry.** Nobody outside hosting terminals attributes ports to session or worktree. Combine: libproc process tree while the session is alive (Claude Code chain is `Claude.app → disclaimer → claude → sh → node` on this machine), `~/.claude/sessions/<pid>.json` (used by Agent Deck), Codex `~/.codex/sessions/…/rollout-*.jsonl`, hook `SessionStart/End` cwd, and LeftOpen's cwd walk-up as the fallback for reparented processes. Kill protocol per LeftOpen. Memory discipline per SpaceGuard (20–40 MB) and PortKiller's regressions (no UI rebuild per scan).
7. **Disk cleaner v1.1 is a merge of SpaceGuard + Mole rules plus the registry:** list worktrees from the known agent containers, run `git status`, never preselect dirty or unpushed, exclude sessions active in the last 24 h, show size via `getattrlistbulk`, move to Trash, keep branches; also offer Claude Code's own `file-history`, scratchpads under `/private/tmp/claude-<uid>/`, and `~/.codex/sessions` with the same retention logic. SpaceGuard is MIT and Swift — reuse with attribution rather than rewrite.
8. **Vendor-trend corrections to the market report:** the 30-minute background limit no longer applies to interactive Claude Code sessions (2.1.288), so orphaned dev servers remain a live problem; Claude Code now force-kills background commands 1.5 s after exit (2.1.300), which reduces but does not eliminate orphans (detached/`setsid` processes, processes started by processes). Codex is building managed background servers (`/daemon`) and managed worktrees — watch 0.164+ for a dev-server panel (issue #42244). Vibe Backup's Pro price is $14.99 lifetime, not $4.99.
9. **Distribution and UX bar set by neighbours:** LeftOpen ships a signed, notarized universal binary via its own tap within a month of creation; Agent Deck compiles locally with CLT to dodge Gatekeeper; cmux got 58k cask installs in a year. Airbag's plan (notarized cask, macOS 14+, MIT, no telemetry) matches the best practice; a self-test after hook install (laya-guard) and a "Repair hooks" button (Agent Deck) should be in v1.
10. **Positioning sentence that survives this scan:** "Airbag is the only free native macOS app that snapshots before every agent command and on every file change, independent of the agent, with one-click rollback, a recoverable-first circuit breaker, and a radar that names which session and worktree left a port open." Every clause has a single-feature competitor; none has the combination.

## 10. Open questions

1. Codex: does `PreToolUse` fire in the Codex desktop app and in `codex exec` (non-interactive), and does the `/hooks` trust persist across Airbag updates if the command path is stable but the binary changes? (Trust is recorded "against each hook's current hash" — of the config entry or of the binary?) [unverified]
2. Cursor: does `beforeShellExecution` fire for background agents and for terminals the user opens, and does the Cursor Agent CLI load `~/.claude/settings.json` hooks automatically? If so, Airbag needs de-duplication by `tool_use_id`/`generation_id`.
3. Claude Code: the exact `tool_response` schema for `Bash` in PostToolUse (needed to detect `run_in_background` and PIDs); whether `FileChanged` can take a directory; whether `WorktreeCreate` can be observed without replacing the default behaviour (an `async` observer is not offered for that event).
4. Measured cost of Airbag's planned before+after snapshot on 50k–100k-file repos with SwiftPM-built git invocation vs libgit2, and FSEvents latency under `npm install`; claude-time-machine's numbers are Linux/SSD.
5. Nested repositories/submodules inside a project (takeback stores only the commit) — Airbag's single hidden store must decide between recursing and recording pointers.
6. Secrets-in-snapshots default (see §9.5) and whether to encrypt the store at rest (Vibe Backup does AES-256; doover does not).
7. Whether to vendor doover's CC0 rule registry (confirm licence headers) and how to reconcile its 152 classifications with Airbag's ≤20 blocking rules.
8. Homebrew: own tap first vs homebrew-cask acceptance thresholds (stars/forks/notability) for a new project. [unverified]
9. Trademark clearance for "Airbag" in software (Airbag Technologies SAPI de CV, io.airbagtech) and domain availability (no HTTP response is not proof of availability).
10. Reddit coverage is partial (Arctic Shift 422/429 on several queries; reddit.com 403); a manual pass over r/ClaudeCode, r/codex, r/cursor "new" for Oct 9–16 is advisable before launch.
11. Codex "worktree by default since 2026-09-22" (market report) could not be confirmed in the changelog; verify in the Codex app release notes.

## Sources (accessed 2026-10-16/17)

Vendors: https://code.claude.com/docs/en/checkpointing · https://code.claude.com/docs/en/hooks · https://code.claude.com/docs/en/claude-directory · https://code.claude.com/docs/en/desktop · https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md · https://github.com/anthropics/claude-code/issues/43944 · https://github.com/anthropics/claude-code/issues/93794 · https://github.com/openai/codex/issues/9203 · https://github.com/openai/codex/issues/11626 · https://github.com/openai/codex/issues/8214 · https://github.com/openai/codex/pull/8424 · https://github.com/openai/codex/issues/42244 · https://github.com/openai/codex/issues/25772 · https://github.com/openai/codex/issues/12491 · https://learn.chatgpt.com/docs/hooks · https://learn.chatgpt.com/docs/changelog · https://cursor.com/docs/agent/chat/checkpoints · https://cursor.com/docs/agent/hooks · https://cursor.com/changelog · https://geminicli.com/docs/hooks/

New tools: https://github.com/hichipli/takeback · https://github.com/xzwache/claude-time-machine · https://github.com/Abelo9996/snap-back · https://github.com/Blackman99/agentckpt · https://github.com/MrSkelee/vscode-ai-undo · https://github.com/ainullm/agent-checkpoint · https://github.com/DmitriyBush/ShedKeeper · https://github.com/philm123/claude-code-receipts · https://github.com/darkomarijaan/nexus-mod · https://github.com/scs0209/laya-guard · https://github.com/skillkeel/skillkeel-starter · https://github.com/yybd/repo-guards · https://github.com/delta-box/deltabox-lite · https://github.com/Ermag/rowbit · https://github.com/mkrn/spaceguard · https://github.com/shinokamix/lopper · https://github.com/Obedience-Corp/fresh · https://github.com/aadilkadiwal/agent-deck · https://github.com/sebastiansandqvist/local-bar · https://github.com/trueno950/dev-mission-control · https://github.com/midhunweb/miseguard · https://github.com/extracurricular-ai/codex-rewind

Known neighbours: https://docs.rs/bashward · https://crates.io/api/v1/crates/bashward · https://github.com/CaydenChik/doover · https://crates.io/api/v1/crates/doover · https://github.com/WePwn/demo_cli · https://aiindigo.com/tool/democli · https://github.com/kenryu42/cc-safety-net · https://ccsafetynet.com/ · https://api.npmjs.org/downloads/point/last-month/cc-safety-net · https://github.com/SonghaiFan/leftopen · https://github.com/productdevbook/port-killer · https://github.com/productdevbook/port-killer/issues/75 · https://github.com/productdevbook/port-killer/issues/87 · https://github.com/treadiehq/port-kill · https://github.com/wieandteduard/port-menu · https://github.com/manaflow-ai/cmux · https://github.com/superset-sh/superset · https://docs.superset.sh/ports · https://agentpeek.app/docs/servers/ · https://www.producthunt.com/products/agentpeek · https://feedbagel.com/post/agent-bar-menu-bar-interface-for-claude-code-ai-projects · https://github.com/jreed91/agentbar · https://github.com/XiaoLuoLYG/agent-beacon · https://github.com/kageroumado/adrafinil · https://github.com/CharlonTank/agents-sleep-preventer · https://github.com/tw93/Mole · https://mole.fit/ · https://pypi.org/pypi/ossnap/json · https://github.com/nvt1904/ossnap · https://github.com/cboone/snappy · https://apps.apple.com/us/app/vibe-backup-dev-code-backup/id6752509487 · https://www.vibebackup.com/ · https://apps.apple.com/us/app/checkpoints-for-claude-code/id6751541546 · https://formulae.brew.sh/api/cask/{adrafinil,cmux,superset}.json · https://formulae.brew.sh/api/formula/mole.json

Channels: https://hn.algolia.com/api/v1/search_by_date (Show HN since 2026-09-30) · https://news.ycombinator.com/item?id=49556858 · https://www.producthunt.com/leaderboard/weekly/2026/41 · https://www.producthunt.com/leaderboard/weekly/2026/42 · https://arctic-shift.photon-reddit.com/api/posts/search · https://reddit.com/r/cursor/comments/1x3az20/ · https://reddit.com/r/ClaudeCode/comments/1x3b1qq/ · https://reddit.com/r/ClaudeCode/comments/1x5tbps/ · https://reddit.com/r/ClaudeCode/comments/1x10ck6/ · https://reddit.com/r/codex/comments/1x03278/

Name check: https://api.github.com/search/repositories?q=airbag+in:name · https://registry.npmjs.org/airbag · https://registry.npmjs.org/-/v1/search?text=airbag · https://pypi.org/pypi/airbag/json · https://crates.io/api/v1/crates/airbag · https://api.github.com/users/airbag · https://itunes.apple.com/search?term=airbag&entity=macSoftware · https://itunes.apple.com/search?term=airbag&entity=software · https://github.com/n-bharath-chowdary/airbag · https://github.com/venkateshamatam/airbag
