# 12 — Circuit breaker (rules engine)

Status: implemented in `Sources/AirbagCore/Rules/` (M3). Fixture: `Tests/AirbagCoreTests/Fixtures/rules.json`
(307 cases, all green).

## Principle

Snapshot first, block only the unrecoverable (ADR-011). Text analysis of shell commands can never be complete —
the leading blocker ships bypass fixes weekly — so the breaker is a second line of defence. The first line is the
snapshot taken before every mutating command.

## Decision model

`GuardVerdict { decision: allow | ask | block, snapshot: none | recommended | required, findings[] }`

- `block`: the damage is outside every snapshot and catastrophic (home, system folders, user data folders, a
  parent of a protected project, Airbag's own data, disks, power, Time Machine, `gh repo delete`).
- `ask`: the damage is outside the project or remote (other folders, git remote history, databases, cloud,
  containers' volumes, piping downloads into a shell, `sudo`, broad `killall`, editing agent hook configs).
- `allow` + `required`: destructive but recoverable inside a protected root (`rm` in the project, `git reset
  --hard`, `git clean -fdx`, `git checkout -- .`, overwrite by redirect). The hook allows these only when the
  snapshot succeeded; if it was skipped (busy, low disk, deadline) the hook escalates to `ask`.
- `allow` + `recommended`: any other mutating or unknown command — a snapshot is taken when possible.
- `allow` + `none`: known read-only commands (`ls`, `cat`, `grep`, `git status/log/diff/add/commit/push`, …).

The verdict is the maximum over all findings; snapshot need is the maximum over findings, raised to
`recommended` when any command in the line is not known read-only.

## Analysis

1. `ShellLexer` tokenizes with POSIX quoting (`'…'`, `"…"`, `$'…'`, backslash, line continuation), operators
   (`; && || | |& & ( )`), redirections (incl. `2>`, `&>`, heredocs whose bodies are skipped), comments,
   tilde expansion, known variables (`HOME`, `PWD`, `TMPDIR`, …; `$(pwd)` resolves to the working directory) and
   marks every other expansion, command substitution or arithmetic as **opaque**. Substitution bodies are analysed
   as commands too.
2. Each simple command is unwrapped: env assignments, `sudo/doas` (also raises `sys.sudo`), `env`, `nohup`,
   `time`, `nice`, `exec`, `command`, `timeout`, `caffeinate`, `watch`, …; `sh/bash/zsh -c "…"` and `eval` are
   parsed recursively (depth ≤ 6); `npx/pnpm/yarn/bun` run the inner binary; `xargs` takes its targets from a
   preceding `find` or is treated as opaque.
3. `cd`/`pushd`/`env -C` update the working directory for the rest of the line.
4. Paths resolve against the working directory, normalise `..`, resolve symlinked parents (a trailing slash
   follows the link), and globs classify their directory (`dir/*` = contents of `dir`, which never includes `.git`).
5. Classification: `catastrophic`, `airbag`, `gitInternals`, `projectRoot`, `insideProject`, `regenerable`
   (excluded build/dependency folders, user caches), `temporary`, `device`, `outside`, `unknown`.

## Rule catalog

| Rule | Decision | Snapshot | Reason given to the agent (abridged) |
|---|---|---|---|
| `cloud.delete` | ask | none | it deletes cloud resources or data, which no local snapshot can bring back. |
| `cloud.iac.destroy` | ask | none | it destroys cloud infrastructure, which no local snapshot can bring back. |
| `cloud.k8s.delete` | ask | none | it deletes Kubernetes resources on a cluster. |
| `cloud.paas.destroy` | ask | none | it deletes a deployed app, database or data on (name), which no local snapshot can bring back. |
| `db.destructive` | ask | none | it drops or wipes database data, which file snapshots cannot restore. |
| `db.local.destructive` | allow | required | it deletes data in a local database file inside the project (snapshot taken first). |
| `db.reset` | ask | none | it wipes or drops database data, which file snapshots cannot restore. |
| `db.reset.local` | ask | none | it wipes and re-creates the local Supabase database (its data is not in file snapshots). |
| `db.reset.script` | ask | none | the package script `(scriptName!)` looks like it wipes a database, which file snapshots cannot restore. |
| `docker.destructive` | ask | none | it deletes container volumes or images, which can hold local databases that file snapshots do not cover. |
| `docker.mount.delete` | ask | recommended | it mounts host folders into a container and deletes files there, bypassing host-side checks. |
| `fs.device.write` | block | none | it targets a device. |
| `fs.find.delete.broad` | ask | none | it deletes matching files anywhere under (describe(p)), outside what snapshots cover. |
| `fs.find.delete.project` | allow | required | it deletes matching project files (restorable from the snapshot taken first). |
| `fs.mv.catastrophic` | block | none | it would move (describe(p)) away, breaking the system or your files. |
| `fs.mv.opaque` | ask | recommended | it moves a path built from an unresolved variable. |
| `fs.mv.outside` | ask | none | it moves (s.text), which is outside the protected project. |
| `fs.mv.project` | allow | required | it moves project files (restorable from the snapshot taken first). |
| `fs.overwrite.catastrophic` | block | none | it would (verb) (describe(p)). |
| `fs.perm.opaque` | ask | recommended | it recursively changes permissions of a path built from an unresolved variable. |
| `fs.perm.outside` | ask | none | it recursively changes permissions outside the protected project. |
| `fs.redirect.catastrophic` | block | none | it empties (describe(p)). |
| `fs.rm.catastrophic` | block | none | it would (verb) (describe(p)), which no snapshot covers. |
| `fs.rm.opaque` | ask | recommended | it deletes or changes files whose names come from another command's output, which Airbag cannot check. |
| `fs.rm.outside` | ask | none | it would (verb) (t.text) outside the protected project, where no snapshot can restore it. |
| `fs.rm.project` | allow | required | it deletes project files (restorable from the snapshot taken first). |
| `fs.rm.project-root` | allow, ask | required | it deletes the whole project folder (restorable from the snapshot taken first). |
| `fs.rsync.delete.remote` | ask | none | it deletes files on a remote machine that are missing locally. |
| `fs.trash.empty` | block | none | it empties the Trash permanently. |
| `fs.truncate.opaque` | ask | recommended | it empties a file whose path depends on an unresolved variable. |
| `fs.truncate.outside` | ask | recommended | it empties (t.text) outside the protected project. |
| `fs.truncate.project` | allow | required | it empties a project file (a snapshot is taken first). |
| `fs.write.outside` | ask | recommended | it overwrites (target.text) outside the protected project, where no snapshot can restore it. |
| `fs.write.project` | allow | recommended | it edits project files (a snapshot is taken first). |
| `gh.api.delete` | ask | none | it sends a DELETE request to the GitHub API. |
| `gh.delete` | ask | none | it deletes data on GitHub. |
| `gh.repo.delete` | block | none | it deletes a GitHub repository with all its issues and history. |
| `git.branch.force-delete` | ask | recommended | it force-deletes a branch that may hold unmerged commits. |
| `git.checkout` | allow | recommended | it switches files in the working tree. |
| `git.checkout.discard` | allow | required | it discards local changes (restorable from the snapshot taken first). |
| `git.clean` | allow | required | it deletes untracked(rest.contains { $0.contains( |
| `git.gc.prune` | ask | recommended | it permanently removes unreachable commits that could otherwise be recovered. |
| `git.history.rewrite` | ask | recommended | it rewrites the entire repository history. |
| `git.internals.delete` | ask | recommended | it moves git internals (.git), which snapshots do not cover. |
| `git.internals.write` | ask | recommended | it overwrites a file inside .git, which snapshots do not cover. |
| `git.push.delete` | ask | none | it deletes a branch or tag on the remote. |
| `git.push.force` | ask | none | it rewrites history on the remote, which cannot be undone from this machine. |
| `git.push.mirror` | ask | none | it can delete remote branches that do not exist locally. |
| `git.reflog.expire` | ask | recommended | it deletes the reflog, git's own safety net for lost commits. |
| `git.reset.hard` | allow | required | it discards uncommitted changes (restorable from the snapshot taken first). |
| `git.rm` | allow | required | it deletes tracked files (restorable from the snapshot taken first). |
| `git.stash` | allow | required | it removes local changes from the working tree into a stash (also covered by the snapshot taken first). |
| `git.stash.drop` | ask | recommended | it permanently drops stashed changes, which are not in the working tree and not in snapshots. |
| `git.submodule.deinit` | ask | recommended | it force-removes submodule working trees. |
| `git.update-ref.delete` | ask | recommended | it deletes a git ref directly. |
| `git.worktree.remove` | ask | recommended | it force-removes a worktree including uncommitted changes. |
| `interp.delete` | ask | recommended | it deletes files or runs commands from inline (name) code that Airbag cannot analyze. |
| `interp.delete.catastrophic` | block | none | its inline (name) code deletes or runs commands against (describe(p)). |
| `interp.delete.project` | allow | required | it deletes files from inline (name) code inside the project (snapshot taken first). |
| `net.pipe.shell` | ask | recommended | it pipes a downloaded script straight into (name). |
| `remote.destructive` | ask | none | it runs a destructive command on a remote machine, outside anything Airbag can snapshot. |
| `self.airbag` | ask, block | none | it removes Airbag's protection; only the user should do that. |
| `self.hooks` | ask | none | it edits an agent's hook configuration, which can switch Airbag's protection off. |
| `shell.opaque` | ask | recommended | it evaluates text built from unresolved variables. |
| `shell.too-deep` | ask | recommended | it nests shells too deeply to analyze. |
| `sys.crontab.remove` | block | none | it deletes every cron job of the user without confirmation. |
| `sys.defaults.delete` | ask | recommended | it deletes application preferences. |
| `sys.disk.erase` | block | none | it can erase or repartition a disk. |
| `sys.kill.all` | block | none | it kills every process of the user, including the agent and all open apps. |
| `sys.kill.broad` | ask | none | it kills every process matching a broad name, possibly including the agent itself, editors or other projects' servers. |
| `sys.launchctl.system` | block | none | it stops or removes system services. |
| `sys.osascript` | ask | recommended | it runs an AppleScript that can delete or run commands outside the project. |
| `sys.power` | block | none | it shuts down or restarts the Mac and every running session. |
| `sys.security` | block | none | it changes low-level system security or boot settings. |
| `sys.sudo` | ask | recommended | it runs with root privileges, outside what Airbag can snapshot or undo. |
| `sys.tmutil` | block | none | it deletes Time Machine backups or disables them. |

## Messages

Agent-facing text is English and ends with the way forward: blocked commands say "Do not retry this command or
work around it with another tool; choose a safer, narrower command or ask the user"; asks name the risk. When the
agent cannot ask the user natively, the hook turns `ask` into a deny that tells the model the user can approve the
command in Airbag (doc 11 §4.6).

## Known limits (honest)

Inline interpreter code, scripts run by path, Makefiles and package scripts are opaque unless they match the
heuristics above; containers with host mounts and remote shells are flagged only by pattern. The snapshot covers
these cases inside the project; outside it, nothing text-based can be complete.
