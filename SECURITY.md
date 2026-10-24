# Security

## Reporting

Please report vulnerabilities privately through GitHub's "Report a vulnerability" (Security tab) rather than in
public issues. Expect an answer within a week.

## Threat model (summary)

Airbag protects a developer's files from **mistakes made by AI coding agents**. It is not a sandbox and not a
security boundary against a hostile agent, a malicious plugin, or malware running as the same user.

- **Trust boundary.** Everything runs as the logged-in user: no root helper, no Full Disk Access, no network.
- **Hooks.** The hook runs inside the agent's process tree before each shell command. Rules are evaluated before
  any I/O, so database or store failures never weaken a block. What happens when the hook itself fails (crash,
  timeout, missing binary) is up to the agent. Claude Code, Codex and Cursor run the command anyway by default;
  strict mode makes Claude Code and Cursor block instead (Codex has no such switch). Cursor also blocks on a reply
  that is not valid JSON. GitHub Copilot CLI denies the shell command when the hook errors and runs it when the hook
  times out. Gemini CLI turns a non-zero exit other than 1 that prints text into a deny.
- **Bypass.** An agent can always find a command the text analysis does not understand. That is why destructive
  commands inside the project are allowed only after a snapshot, and why the breaker reserves blocks for damage
  outside every snapshot. Known blind spots of the text analysis: scripts run by an interpreter (`python3 x.py`,
  `python3 - <<EOF`), paths built from loop variables or command output, and `cp`/`mv` destinations given by an
  unresolved variable. Inside a project the snapshot covers them.
- **Self-protection.** Shell commands that delete, move, overwrite or edit Airbag's own data files (`rm`, `mv`, `cp`,
  redirects, `sed -i`, `chmod`) are blocked, and so is `airbag allow` run by an agent: only the user approves a
  stopped command. The following stop the agent until you approve, whatever the agent and the setting below
  (the agent's own prompt where it has one, otherwise a deny with "Allow Once" in Airbag): editing, emptying, moving
  or removing the user-level hook files of Claude Code (`~/.claude/settings.json`, `settings.local.json`), Codex
  (`~/.codex/hooks.json`, `config.toml`), Cursor (`~/.cursor/hooks.json`), Gemini CLI (`~/.gemini/settings.json`)
  and Copilot CLI (any `~/.copilot/hooks/*.json`, `~/.copilot/settings.json`, `settings.local.json`); removing or
  moving a folder that holds one (such as `~/.copilot/hooks`); `airbag hooks uninstall`; `airbag hooks install
  --command` or `--home`, which point the hooks somewhere else; and `brew uninstall` (`remove`, `rm`) of the
  Airbag cask. Not covered: edits made with an agent's own file-edit tools (Airbag's hooks check shell commands
  only; Codex's `apply_patch` gets a snapshot first, no check), project-level settings such as a project's
  `.claude/settings.json` with `disableAllHooks`, interpreter one-liners that write the file (`python3 -c`,
  `node -e`), and anything while you have paused Airbag. SQL that writes to Airbag's database through `sqlite3` is
  blocked like editing its files. All of this reads the command text, so a hostile process running as you can get
  around it or remove Airbag.
- **Risky commands without a prompt.** Where the agent cannot show its own approval prompt (bypass permissions,
  Codex, Gemini), risky commands run after a snapshot and are recorded in Guard by default; Settings → Agents →
  "When a snapshot can't undo a command" → "Stop Until I Approve" makes them wait for approval instead. Blocks never
  depend on this setting. Except while Airbag is paused (then nothing waits; blocks still apply), two kinds always
  wait for approval: switching Airbag off (above), and a command that needs a snapshot (`rm` or `mv` in the
  project, `git reset --hard`, `git clean`, …) when Airbag could not take a usable one. A command for which a
  snapshot is only recommended (`sed -i`, a script, `cp` onto a project file) still runs if its snapshot fails. A
  folder with no files, or one you stopped protecting (Stop Protecting…), needs no snapshot, as long as it is the
  only folder protected for that command.
- **Data at rest.** Snapshots are copies of project files, including `.env` and other secrets. They live in
  `~/Library/Application Support/Airbag` with 0700/0600 permissions and are excluded from Time Machine and
  Spotlight. Anyone who can read your home folder can read them.
- **Data in the registry.** Command lines are stored after masking token-like secrets; command output is never
  stored. Environment variables of other processes are read only for a fixed allowlist of agent markers.
- **Signals.** The radar only signals processes of the same user after re-validating `(pid, start time)`, never
  agents, terminals, editors, Airbag itself or system processes, and SIGKILL only on an explicit second click.
- **Hook path.** The hook command is an absolute path inside the signed app bundle (or the Homebrew symlink).
  `airbag hooks status` reports entries that point at another binary.
