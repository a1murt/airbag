# Security

## Reporting

Please report vulnerabilities privately through GitHub's "Report a vulnerability" (Security tab) rather than in
public issues. Expect an answer within a week.

## Threat model (summary)

Airbag protects a developer's files from **mistakes made by AI coding agents**. It is not a sandbox and not a
security boundary against a hostile agent, a malicious plugin, or malware running as the same user.

- **Trust boundary.** Everything runs as the logged-in user: no root helper, no Full Disk Access, no network.
- **Hooks.** The hook runs inside the agent's process tree before each shell command. Rules are evaluated before
  any I/O, so database or store failures never weaken a block. By default hooks fail open (an agent keeps working
  if Airbag is broken); strict mode makes Claude Code and Cursor block instead.
- **Bypass.** An agent can always find a command the text analysis does not understand. That is why destructive
  commands inside the project are allowed only after a snapshot, and why the breaker reserves blocks for damage
  outside every snapshot.
- **Self-protection.** Commands that delete or edit Airbag's data or the agents' hook configuration files are
  blocked or need approval. A determined same-user process can still remove them.
- **Data at rest.** Snapshots are copies of project files, including `.env` and other secrets. They live in
  `~/Library/Application Support/Airbag` with 0700/0600 permissions and are excluded from Time Machine and
  Spotlight. Anyone who can read your home folder can read them.
- **Data in the registry.** Command lines are stored after masking token-like secrets; command output is never
  stored. Environment variables of other processes are read only for a fixed allowlist of agent markers.
- **Signals.** The radar only signals processes of the same user after re-validating `(pid, start time)`, never
  agents, terminals, editors, Airbag itself or system processes, and SIGKILL only on an explicit second click.
- **Hook path.** The hook command is an absolute path inside the signed app bundle (or the Homebrew symlink).
  `airbag hooks status` reports entries that point at another binary.
