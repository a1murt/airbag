# 09. Dogfooding on a real Mac (2026-10-18)

First run of Airbag with a real agent: the owner installed the app, went through the welcome window and connected
Claude Code, Codex, Gemini CLI and Copilot CLI. From that moment the agent session that was developing Airbag ran
under Airbag's own hooks. Everything below happened in that session, on the owner's machine and configuration.

## What worked on the first try

| Check | Result |
|---|---|
| Hook latency (PreToolUse, real Claude Code, 60+ calls) | 3–11 ms |
| `rm -rf` of a folder with an untracked `.env` in a protected repo | allowed, snapshot taken first; `airbag restore --path` brought back all 3 files |
| Secrets in the command log | `API_KEY=…` redacted to `API_KEY=***` |
| `git push --force` | ask (deny with one-shot allowance under bypass permissions), snapshot taken first |
| Dev server started by the agent | radar attributes it to the session, with the session title; `airbag stop` frees the port |
| Overwriting `/Applications` | blocked before anything ran |

## Findings and fixes

| # | Finding | Severity | Fix |
|---|---|---|---|
| F1 | `2>&1` was lexed as operator `2>&` plus file `1`: every command with it counted as a write; inside the project a needless snapshot, outside it "it overwrites 1" and an ask. None of the 386 fixture cases used `2>&1`. | high | `Analyzer.opensFileForWriting`: `N>&M`, `>&N`, `N>&-` duplicate or close descriptors; `>&file` (bash for `&>file`) is a write and was previously missed. |
| F2 | `cp`/`mv`/`rsync` into an existing folder were judged as overwriting the folder: `cp -R x.app /Applications/` said "it would overwrite /Applications" (block), `mv notes.txt ~/Documents` was blocked. | high | `destinationCheck`: judge `dest/<name>`; ask when the names are unknown (`src/`, globs, ditto); with the real file system a move that replaces an existing file outside the project asks (`mv .zshrc ~`). |
| F3 | The owner's home folder is a git repository. Walking up to the nearest `.git` made the whole home folder the project of every non-git folder below it; Airbag refused to snapshot it (correct), so those sessions had no snapshots at all, and the home folder was registered as a protected project. | high | `RootResolver` ignores a `.git` at a system or home folder; the hook registers only roots that pass `validateRoot`. |
| F4 | The welcome window suggested `/System/Volumes/Data/home`: remote SSH sessions of Claude Code (`~/.claude/projects/ssh-*`) record a remote cwd such as `/home`, which exists on macOS as an autofs mount. It was preselected and became a project. | medium | Suggestions skip `ssh-*`; `validateRoot` refuses `/home` (`/System/Volumes/Data/home`) and system paths. |
| F5 | Idle CPU 4.75 % with one live session (release checklist item 10 asks < 1 %): the radar re-published its results every 2 s because memory and CPU-time numbers of unrelated listeners (Spotify, ControlCenter) always differ, and SwiftUI re-laid out every view. | medium | Usage numbers are re-published only while the popover or main window is visible. |
| F6 | The app's windows were unreachable with ⌘-Tab and hidden from tools that list regular apps (menu bar apps run as accessory). | low | The app becomes a regular app while one of its titled windows is open. |
| F7 | No fixture used `2>&1`, `$(cat <<'EOF' …)` or `D=…; … "$D"`, although agents write them all the time: the fixtures described the commands we imagined, not the ones agents run. | process | `Scripts/breaker-corpus.py` (ADR-025). |

## Independent review of the fixes

Four reviewers (breaker red team, bash/zsh redirect semantics, root resolution, app behaviour) probed the uncommitted
fixes with about 300 `airbag check` runs against a build of the previous commit; a skeptic per lens tried to refute
each finding. Confirmed and fixed:

| Finding | Origin | Fix |
|---|---|---|
| `1<>file` and `exec 3<>file` stopped counting as writes (hook configs, Airbag data, devices) | F1 fix | `N<>` with an output descriptor is a write |
| `rsync --del` (alias of `--delete-during`) into `~` or `/Applications` became an ask described as a copy | F2 fix | `--del` deletes like `--delete` |
| `rsync -R` / `cp --parents` were judged at `dest/<name>`, losing self-protection | F2 fix | the source path is recreated below the destination |
| `git reset --hard` from a non-git folder below a home-folder repository was allowed | F3 fix | git commands whose repository reaches beyond the protected root ask |
| A launch folder of `~` still made the home folder the project | F3 fix | system and home folders are ignored as launch roots |
| `/System/` rule would disable network home folders mounted under `/home` | F4 fix | only `/System/Volumes/Data/home` itself and non-data `/System` paths |
| The home-folder project row stayed in the registry and fed the radar | F3 | archived by retention; ignored by the radar |
| A minimised window counted as closed; Window menu reopened Welcome and Restore | F6 fix | minimised windows count; those scenes have no menu command |
| `git commit -m "$(cat <<'EOF' … don't … EOF)" && rm -rf ~/Documents` was allowed: the apostrophe hid the rest | pre-existing | here-documents inside `$( )` are copied verbatim; an unterminated quote at the top level asks |
| `bash <<'EOF'` bodies were never analysed | pre-existing | shell bodies get the full analysis |
| Deleting, moving or truncating `~/.claude/settings.json` was not seen as switching Airbag off | pre-existing | `self.hooks` for rm, mv and truncate |
| `rsync --delete src/ ~/ --exclude x` took `x` as the destination; `gcp -t DIR` ignored | pre-existing | options with values anywhere on the line, `-t DIR` |
| zsh `>!`, `>>!`, `&>!`, `>&!`, `>>&` were not redirects | pre-existing | lexed as writes |

## Real agent history (ADR-025)

`Scripts/breaker-corpus.py` replayed the 1585 distinct shell commands of this Mac's Claude Code sessions through the
first public build and the fixed one (analysis only):

| | ask | block |
|---|---|---|
| first public build | 270 (17.0 %) | 3 |
| after the fixes | 59 (3.7 %) | 0 |

Beyond `2>&1`, the corpus exposed three sources of needless questions, fixed in the same pass: variables set earlier
on the same line (`D=…; mv "$D/x" …`, now resolved as the shell does, including `$(mktemp -d)` and `~` after `=`),
`eval "$(brew shellenv)"` and similar environment setup, and writes that create new files outside the project
(ADR-026). Projects the command `cd`s into are now protected and snapshotted (ADR-027). Every remaining ask was
checked by hand: force pushes, history rewrites, `git worktree remove --force`, overwriting or deleting files on the
Desktop, editing `~/.ssh/config`, `rm -rf` on a remote server. The three former blocks were copies into
`/Applications` and are now asks naming the app bundle.

## Open

- There is no "stop protecting this folder" in the app; a wrong project from the welcome window cannot be removed.
- Scripts run by interpreters and paths from loop variables or command output are not analysed (SECURITY.md).
- The real `claude -p` end-to-end script still needs `claude /login` for the bundled CLI.
