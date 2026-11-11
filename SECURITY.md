# Security

## Reporting

Please report vulnerabilities privately through GitHub's "Report a vulnerability" (Security tab) rather than in
public issues. Expect an answer within a week.

## Threat model (summary)

Airbag protects a developer's files from **mistakes made by AI coding agents**. It is not a sandbox and not a
security boundary against a hostile agent, a malicious plugin, or malware running as the same user.

- **Trust boundary.** Everything runs as the logged-in user: no root helper, no Full Disk Access, no network.
- **Distribution.** There is no Apple Developer ID yet, so releases are ad-hoc signed and not notarized. Each one is
  built from its tag by the public release workflow (`.github/workflows/release.yml`), which attaches the SHA-256 of
  the zip and the DMG (`Airbag-<version>.sha256`). The Homebrew cask checks that SHA-256 and removes the quarantine
  flag, so Gatekeeper does not prompt; the DMG asks once. `make app` builds it from source.
- **Hooks.** The hook runs inside the agent's process tree before each shell command. A failure of the database or
  the snapshot store turns no rule off: if the registry can't be read, every rule applies and nothing counts as
  paused. What happens when the hook itself fails (crash, timeout, missing binary) is up to the agent. Claude Code,
  Codex and Cursor run the command anyway by default; strict mode (Settings → Agents → "If Airbag doesn't respond in
  time" → "Block the Command", or `airbag hooks install --all --strict`) makes Claude Code and Cursor block instead
  (Codex has no such switch). Because a crash lets the command through in those three, CI feeds 2,000 generated
  hostile commands to the parser on every push (`Scripts/guard-fuzz.py`): a command must not be able to crash the
  hook on purpose. The hook also stops itself after 4 s and prints the answer decided so far; until Guard has
  decided, that answer refuses the command, and so does a shell command whose hook payload is over 1 MiB. Cursor also
  blocks on a reply that is not valid JSON. GitHub Copilot CLI denies the shell command when the hook errors and runs it when the hook
  times out. Gemini CLI turns a non-zero exit other than 1 that prints text into a deny. So that deleting Airbag.app
  without disconnecting these two does not leave them refusing every command, their entries check that the binary
  exists first and answer "no objection" when it is gone (ADR-039). The Claude Code plugin runs the same binary and
  answers "no objection" when Airbag is not installed; while Airbag's own entries are in Claude Code's settings file,
  the plugin's hooks step aside and those entries decide (ADR-041). Through the plugin alone, a failing hook lets
  the command run; strict mode writes Airbag's own entries.
- **Bypass.** An agent can always find a command the text analysis does not understand. That is why destructive
  commands inside the project are allowed only after a snapshot, and why the breaker reserves blocks for damage
  outside every snapshot. Known blind spots of the text analysis: scripts run by an interpreter (`python3 x.py`,
  `python3 - <<EOF`), paths built from loop variables or command output, and `cp`/`mv` destinations given by an
  unresolved variable. Inside a project the snapshot covers them. A program whose name is only known at run time
  (`"$X" -rf …`, `$(echo rm) …`) is judged by what it is handed: given the home folder, a system folder, Airbag's
  data or a hook file, it waits for the user; lookups such as `"$(which rm)"` count as the program they name.
- **Self-protection.** Shell commands that delete, move, overwrite or edit Airbag's own data files (`rm`, `mv`, `cp`,
  redirects, `sed -i`, `chmod`) are blocked, and so is `airbag allow` run by an agent; `airbag allow` itself also
  refuses to run with an agent among its parent processes, whatever the binary is called. Only the user approves a
  stopped command. The following stop the agent until you approve, whatever the agent and the setting below
  (the agent's own prompt where it has one, otherwise a deny with "Allow Once" in Airbag): editing, emptying, moving
  or removing the user-level hook files of Claude Code (`~/.claude/settings.json`, `settings.local.json`), Codex
  (`~/.codex/hooks.json`, `config.toml`), Cursor (`~/.cursor/hooks.json`), Gemini CLI (`~/.gemini/settings.json`)
  and Copilot CLI (any `~/.copilot/hooks/*.json`, `~/.copilot/settings.json`, `settings.local.json`); removing or
  moving a folder that holds one (such as `~/.copilot/hooks`); `airbag hooks uninstall`; `airbag hooks install
  --command` or `--home`, which point the hooks somewhere else; `airbag prune` and `airbag cleanup`, which delete
  snapshots; and `brew uninstall` (`remove`, `rm`) of the Airbag cask. Not covered: edits made with an agent's own file-edit tools (Airbag's hooks check shell commands
  only; Codex's `apply_patch` gets a snapshot first, no check), project-level settings such as a project's
  `.claude/settings.json` with `disableAllHooks`, interpreter one-liners that write the file (`python3 -c`,
  `node -e`), and anything while you have paused Airbag. SQL that writes to Airbag's database through `sqlite3` is
  blocked like editing its files. All of this reads the command text, so a hostile process running as you can get
  around it or remove Airbag.
- **Risky commands without a prompt.** Where the agent cannot show its own approval prompt (bypass permissions,
  Codex, Gemini), risky commands run after a snapshot and are recorded in Guard by default; Settings → Agents →
  "When a snapshot can't undo a command" → "Stop Until I Approve" makes them wait for approval instead. Blocks never
  depend on this setting. Except while Airbag is paused (then nothing waits; blocks still apply), these always wait
  for approval: switching Airbag off (above); a command that needs a snapshot (`rm` or `mv` in the project,
  `git reset --hard`, `git clean`, …) when Airbag could not take a usable one; a delete that starts at the root of the
  disk if a variable is empty (`rm -rf "$DIR/"*`) or that empties a folder Airbag cannot determine
  (`cd "$DIR" && rm -rf *`); and a program whose name is only known at run time handed the home folder, a system
  folder, Airbag's data or a hook file. A command for which a
  snapshot is only recommended (`sed -i`, a script, `cp` onto a project file) still runs if its snapshot fails. Each
  protected folder such a command deletes or resets in needs its own snapshot: the folder the agent was started in,
  a worktree's main checkout, or an agent worktree in `.claude/worktrees` or `.codex/worktrees` (which the project's
  own snapshots skip), is snapshotted when a command targets it. A folder with no files, or one you stopped
  protecting (Stop Protecting…), needs none.
- **Data at rest.** Snapshots are copies of project files, including `.env` and other secrets. They live in
  `~/Library/Application Support/Airbag` with 0700/0600 permissions and are excluded from Time Machine and
  Spotlight. Anyone who can read your home folder can read them, and so can any process running as you, agents
  included. A secret you remove or rotate stays in the snapshots taken before that until they are deleted: after 7
  days by default, but each project's newest 20 and pinned snapshots are kept. Stop Protecting… deletes all of a
  project's snapshots. The Time Machine exclusion is a flag that other backup tools may ignore. The snapshots of a
  folder that no longer exists are
  deleted 30 days after it was last seen (3 days for temporary folders and agent worktrees), unless one is pinned;
  `airbag cleanup` deletes them on request.
- **Data in the registry.** Command lines are stored after masking token-like secrets; command output is never
  stored. Environment variables of other processes are read only for a fixed allowlist of agent markers.
- **Signals.** The radar only signals processes of the same user after re-validating `(pid, start time)`, never
  agents, terminals, editors, Airbag itself or system processes, and SIGKILL only on an explicit second click.
- **Hook path.** The hook command is an absolute path inside the ad-hoc signed app bundle (or the Homebrew symlink).
  `airbag hooks status` reports entries that point at another binary.
