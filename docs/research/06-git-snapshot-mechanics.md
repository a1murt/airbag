# Git snapshot mechanics for an external store — research note for Airbag

Date: 2026-10-17. Scope: how to keep project snapshots in a git object store that lives outside the project (`~/Library/Application Support/Airbag/...`) and never touches the project's own `.git`: enumeration, nested repos, orphan commits, diffs, restore, retention, performance knobs, large files, locking, store layout. Every command below was run on this Mac (macOS 15.7.9, Apple M4, APFS, `git version 2.39.5 (Apple Git-154)` from Command Line Tools, no Homebrew git) against a synthetic project under `/tmp/airbag-gitprobe`. Primary sources are the git manual pages and git source on 2026-10-17 (links in "Sources").

Tags: [verified] = read in the primary source or measured locally today; [likely] = strong inference or secondary source; [unverified] = not confirmed.

## TL;DR

1. `git --git-dir=STORE --work-tree=PROJECT` with a bare store works for every command we need (update-index, write-tree, commit-tree, diff, restore, read-tree -m -u); the project's `.git` is never opened. Run git with `GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null` and a `STORE/info/attributes` of `* -text -eol -filter -ident` so the user's config and the project's `.gitattributes` (CRLF normalisation, LFS filters) cannot alter stored bytes [verified].
2. Enumerate files with Airbag's own walker and feed `git update-index --add --remove --replace -z --stdin`; git keeps a stat cache, so a no-change snapshot of 20,070 files costs ~45 ms in git (~140 ms end-to-end incl. walker and commit), 10 changed files ~150 ms, 2,000 changed ~830 ms; the first snapshot of 20k files / 80 MB is 6.5–7.5 s regardless of fsync/compression/sha settings [verified, measured].
3. `git add -A` cannot be used: `.gitignore` is always honoured (`.env` lost) unless `-f`, `-f` disables our own excludes too, nested repositories become gitlinks (`160000`) and `git add -f nested/file` is refused ("is in submodule"). `update-index --add` with explicit paths stores nested-repo files as ordinary blobs [verified].
4. Snapshots are orphan commits: `write-tree` -> `commit-tree` (no `-p`) -> `update-ref refs/airbag/snapshots/<ulid>`; metadata as trailers; ~10 ms each. Retention = delete refs + `git gc --prune=now --quiet` [verified].
5. Restore: file/folder via `git restore --source=<sha> --worktree -- <path>`; whole project via "snapshot now, then `git restore --source=<sha> --staged --worktree -- .`" (no-overlay default removes paths tracked in the index but absent in the source; files never snapshotted — excluded dirs, >50 MB, empty dirs — survive). Verified: symlinks, exec bits, nested repo content, project `.git` untouched [verified].
6. Hazard: checkout/restore run with `force=1`; a snapshot file whose path is now a directory makes git `remove_subtree()` that directory, including untracked content and a nested `.git` [verified]. Airbag must pre-scan for type conflicts (`read-tree -m -u` refuses them, `restore`/`checkout` do not).
7. Loose objects dominate disk: one 20k-file snapshot = 84 MB of 4 KiB-block loose objects; 40 churn snapshots = 39k loose objects / 158 MB; `git repack -dq` (0.6 s per few thousand loose) and `gc --prune=now` after ref deletion (7 s for 39k objects -> one 6 MB pack on this compressible corpus) fix it. Plumbing never triggers `gc --auto`; set `gc.auto=0` anyway [verified].
8. Knobs: `index.version=4` (-22 % index size, slightly faster) yes; `core.untrackedCache` and builtin `core.fsmonitor` give nothing on the update-index path (fsmonitor works with `--work-tree` but spawns a 5 MB daemon per project that outlives Airbag) — leave both off; never leave the index with stale stat data (`diff` then costs 1.8–3.6 s instead of 22 ms) [verified].
9. Concurrency: a second `update-index` fails instantly on `index.lock` ("File exists", no retry); serialise all store writers with `flock(STORE/airbag.lock)` and clear a stale `index.lock` while holding it [verified].
10. Project id = SHA-256 of the `F_GETPATH` canonical path (resolves symlinks, `/tmp` -> `/private/tmp`, firmlinks, on-disk letter case); Python/`realpath(3)`-style results keep typed case on the default case-insensitive APFS [verified].

## 1. Test bed and method

Synthetic project built by `/tmp/airbag-gitprobe/setup.py` [verified]:

| Component | Content |
|---|---|
| `src/module000..199/file000..099.ts` | 20,000 files, 50–450 B each, 80,000 KiB on disk |
| `node_modules/pkg00..49/` | 5,050 files (ignored by `.gitignore`, excluded by Airbag) |
| `packages/nested/` | an unregistered nested git repo (51 files + its own `.git`) |
| `vendor/sub/` | a real submodule (`.gitmodules`, gitlink in the project's index) |
| `assets/video.bin` 60 MiB random, `assets/logo.png` 3 MiB random | big binaries (the 60 MiB one is `.gitignore`d) |
| `.env` (0600), `debug.log`, `dist/bundle.js` | ignored-but-valuable / ignored junk |
| `scripts/build.sh` 0755, `empty-dir/`, `file with spaces.txt`, `docs/файл-юникод.md`, `docs/emoji 🚀 rocket.txt`, `docs/café-nfc.txt`, `docs/café-nfd.txt` (decomposed), `docs/windows.bat` (CRLF) | edge cases |
| `link-to-file -> README.md`, `link-to-dir -> src/module001`, `abs-link -> /etc/hosts` | symlinks |
| `.gitattributes`: `* text=auto`, `*.bin filter=lfs diff=lfs merge=lfs -text` | realistic attribute traps |

Totals: 25,119 files outside `.git` dirs, 245 MB; the project is itself a git repo (20,018 tracked paths). Airbag's walker (`find` pruning `.git`, `node_modules`, `dist`, files >= 50 MiB) lists 20,071 paths -> 20,070 index entries (the submodule's `.git` file is rejected by git, see 3.4). Timings are wall-clock from zsh `$EPOCHREALTIME`, single runs unless stated; all scripts are `s1.zsh`…`s7.zsh` in `/tmp/airbag-gitprobe`.

## 2. Store layout and environment

```sh
STORE="$HOME/Library/Application Support/Airbag/stores/<project-id>"
umask 077
git init -q --bare --template= --shared=0600 "$STORE"     # empty template: no sample hooks, no default exclude
mkdir -p "$STORE/info"
printf 'node_modules/\ndist/\n.next/\n.DS_Store\n' > "$STORE/info/exclude"      # Airbag's own rules (walker reads this)
printf '* -text -eol -filter -ident -working-tree-encoding\n' > "$STORE/info/attributes"
git --git-dir="$STORE" config index.version 4
git --git-dir="$STORE" config gc.auto 0
git --git-dir="$STORE" config core.logAllRefUpdates false
git --git-dir="$STORE" config core.precomposeUnicode true   # git init already sets it on macOS
```

Every git invocation: `env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=airbag GIT_AUTHOR_EMAIL=airbag@localhost GIT_COMMITTER_NAME=… GIT_COMMITTER_EMAIL=… LC_ALL=en_US.UTF-8 git --git-dir="$STORE" --work-tree="$PROJECT" …`.

Facts:

- `git init --bare` on macOS writes `core.filemode=true, core.bare=true, core.ignorecase=true, core.precomposeunicode=true` [verified]. With `--work-tree` given, commands that need a work tree (`add`, `diff`, `restore`, `checkout`, `read-tree -u`) all ran against a `core.bare=true` store without complaint [verified].
- `--shared=0600` sets `core.sharedRepository=0600`: index `-rw-------`, object dirs `drwx------`, objects `-r--------` even if a parent directory is later loosened; without it objects are `0444` in `0755` dirs inside the `0700` store [verified]. Documented permission semantics in git-init(1) [verified].
- Attribute precedence: `$GIT_DIR/info/attributes` "has the highest precedence", then `.gitattributes` in the work tree, then `core.attributesFile`, then system (gitattributes(5)) [verified]. The project's `* text=auto` turned `docs/windows.bat` CRLF into LF in the blob under plain `git add`/`update-index`; with the `info/attributes` line above the blob keeps `\r\n` and `git check-attr` reports `text: unset, filter: unset` [verified]. "A missing filter driver definition in the config … makes the filter a no-op passthru" [verified], so dropping the user's global config also disables `filter=lfs` — but unsetting `filter` in `info/attributes` is the robust fix.
- `attr.tree` (read attributes from a tree; an invalid value means an empty tree) exists upstream but is ignored by 2.39: `-c attr.tree=<empty tree> check-attr` still reported `text: auto`; `GIT_ATTR_SOURCE=<tree>` is ignored too and `--attr-source` is an `unknown option` on 2.39, so on this git the only way to neutralise the project's `.gitattributes` is `info/attributes` [verified]. `index.skipHash` is likewise ignored by 2.39 (index trailer is still a real hash) [verified].
- Ignore precedence (gitignore(5)): command line > `.gitignore` files > `$GIT_COMMON_DIR/info/exclude` > `core.excludesFile`; plumbing (`ls-files`, `read-tree`) only reads patterns given on the command line, porcelain (`add`, `status`) reads all sources [verified]. There is no switch that makes porcelain ignore `.gitignore` while honouring `info/exclude`.
- `GIT_CONFIG_GLOBAL=/dev/null` + `GIT_CONFIG_NOSYSTEM=1` keep the user's `core.autocrlf`, `core.fsmonitor`, `core.hooksPath`, `filter.lfs.*`, `gpg.*`, `commit.gpgsign`, `init.templateDir`, `safe.directory` from leaking into the store [verified: config read order; the behavioural effect of each key is [likely]].
- `commit-tree` needs an identity; env vars avoid "please tell me who you are" and keep the user's name out of the store [verified by use].

## 3. Enumeration: which files enter a snapshot

### 3.1 Approaches measured (fresh store per approach; cold = first snapshot, warm = immediate repeat with no change)

| # | Approach | Cold | Warm | `.env` kept | nested repo files | `video.bin` (60 MiB, ignored) | CRLF kept | Notes |
|---|---|---|---|---|---|---|---|---|
| A | `git add -A -f -- . ':(exclude)node_modules' ':(exclude)dist'` | 7,357 ms | 47 ms | yes | **no (gitlink 160000)** | **yes, 60 MiB stored** | no (unless info/attributes) | `-f` defeats *all* ignore rules incl. ours; no size cap |
| B | `git -c core.excludesFile=STORE/info/exclude add -A` | 6,211 ms | — | **no** | no (gitlink) | no | no | `.gitignore` still applies: `.env`, `debug.log` lost |
| C | `git ls-files -o -z --exclude-from=STORE/info/exclude` (no `--exclude-standard`) + `update-index --add --stdin` | 20 ms list + 7,157 ms | 20 ms list | yes | **no** (`packages/nested/` listed as a directory; `update-index` says "Ignoring path packages/nested/") | no | no | the only porcelain-free way to ignore `.gitignore`; cannot see inside nested repos |
| **D** | **own walker -> `update-index --add --remove --replace -z --stdin`** | **6,362 ms** | **49 ms** | **yes** | **yes (51 blobs)** | **no (walker cap)** | **yes with info/attributes** | git hashes only stat-changed files |
| E | own walker -> `hash-object -w --no-filters --stdin-paths` + `read-tree --empty` + `update-index -z --index-info` | 7,513 ms | **1,595–1,757 ms** | yes | yes | no | yes (no filters) | re-hashes all 20k files every time (1.15–1.3 s); symlinks must be added separately (`hash-object` follows them and dies on `link-to-dir`: "Unable to add (null) to database") |

All [verified, measured]. `write-tree` after the index change: 156–208 ms the first time (no cache-tree), ~10 ms afterwards (TREE extension valid) [verified].

Pick D. It is the only approach that (a) ignores `.gitignore` but honours Airbag's rules, (b) captures nested repository content, (c) enforces a per-file cap, (d) gets git's stat-cache fast path. The walker also owns readability checks, so one unreadable file cannot abort the snapshot (3.4).

### 3.2 Why `update-index` is fast when nothing changed

`add_to_index()` compares the cached stat data via `ie_match_stat()` with `CE_MATCH_RACY_IS_DIRTY`; when it matches, "Nothing changed, really" and `index_path()` (hashing) is skipped [verified, read-cache.c]. Racily-clean entries (mtime not older than the index file's own mtime) are re-read and their cached size is "truncated to zero before writing a new version of the index file" so the next run hashes them again (racy-git.adoc) [verified]. This matters for Airbag: a hook snapshot taken within the same second as the agent's write re-hashes just those files; `core.useNanosec` is off by default and documented as unsafe on some platforms [verified].

### 3.3 Walker rules (what Swift's walker must do)

- Do not follow symlinks; record symlinks as entries (git stores `120000` with the link text; `abs-link -> /etc/hosts` stored as a link, not its content) [verified]. Never emit a path *through* a symlinked directory: `link-to-dir/file000.ts` -> `error: 'link-to-dir/file000.ts' is beyond a symbolic link` + `fatal` [verified].
- Prune: `.git` (any depth), Airbag exclude patterns from `STORE/info/exclude` (gitignore syntax; the walker can reuse `git check-ignore --stdin -z` semantics or implement the subset `dir/`, `*.ext`, `**/`), files >= cap (50 MiB default), non-regular files (FIFO -> `error: zz-fifo: unsupported file type` + `fatal`), unreadable files (`open(): Permission denied` + `fatal: Unable to process path`) [verified].
- Emit NUL-separated paths relative to the project root without `./` prefix: update-index(1) "files beginning with . are discarded. This includes ./file" [verified].
- Keep the file-name bytes as found. `core.precomposeUnicode` only touches argv/readdir paths: an NFD name fed via `--stdin` is stored NFD, an NFC name NFC (`docs/cafe\xcc\x81-nfd.txt` vs `docs/caf\xc3\xa9-nfc.txt` in the index) [verified]. APFS is "normalization-insensitive … normalization-preserving" since High Sierra, so either spelling resolves on restore (`ls docs/café-nfd.txt` with NFC spelling found the NFD file) [verified].
- Deletions: `--remove` only drops paths that are *fed* and missing on disk. Paths that vanished or became excluded must be removed explicitly: `git ls-files -z` (9 ms for 20k) minus the walker set -> `update-index --force-remove -z --stdin`. (`git ls-files -z --deleted` takes 38 ms and misses "still exists but now excluded".) [verified]
- `--replace` handles file<->directory swaps ("existing entries that conflict with the entry being added are automatically removed with warning messages") [verified, man page].

### 3.4 Failure semantics of `update-index --stdin`

From builtin/update-index.c [verified]: `verify_path()` failures only print `Ignoring path %s` and continue (this is what rejects `.git` components: `packages/nested/.git/HEAD`, `vendor/sub/.git`); every other per-path error (unreadable, FIFO, beyond symlink, lstat error) makes `update_one()` `die("Unable to process path %s")`. The index is written once at the end; a `die()` leaves the on-disk index untouched, so one bad path discards the whole batch — observed: `zz-new-first.txt` was not added when the next path was unreadable [verified]. Hence the walker's `access(R_OK)` and file-type filter, plus a retry path that drops the offending file. A fed path that no longer exists is fatal as well (`error: X: does not exist and --remove not passed` + `fatal`) unless `--remove` is given, so `--remove` is mandatory, not optional [verified]. After any of these `die()`s git removed its own `index.lock` (no lock file was left behind), so a stale `index.lock` can only come from a hard kill (SIGKILL / hook timeout) [verified by observation].

`.git` components can be stored only under a renamed component: `update-index --add --cacheinfo 100644,<sha>,packages/nested/.git~airbag/HEAD` succeeds [verified]. Whether Airbag should protect nested `.git` directories this way is an open question (15).

## 4. Nested repositories and submodules

- Project index: `160000 … packages/nested` and `160000 … vendor/sub` (gitlinks) — this is how the *project's own* git sees them, which is irrelevant to the store but shows what porcelain does [verified].
- Store with approach A/B/C: the same gitlinks; the files inside are not stored. `git add -f packages/nested/lib/n00.py` -> `fatal: Pathspec 'packages/nested/lib/n00.py' is in submodule 'packages/nested'` [verified]. This fatal needs the gitlink to be in the index already; on an empty index the same command exits 0 and silently adds nothing (the nested repo is skipped as an untracked directory) — either way `git add` cannot capture nested-repo files [verified].
- `git update-index --add --replace packages/nested/lib/n00.py` on top of a gitlink replaces the gitlink with the blob entry; afterwards even `git add -A -f` keeps the nested files as blobs (it no longer sees the directory as "untracked other") [verified]. `-c submodule.recurse=true` changes nothing for `add` [verified].
- With approach D the store holds 51 blobs under `packages/nested/` and 1 under `vendor/sub/`; restore wrote `packages/nested/lib/n00.py` back and left `packages/nested/.git` intact [verified].
- Not stored: the nested repo's `.git` directory (history, stashes, hooks). The builtin fsmonitor "does not currently know about submodules" (fsmonitor--daemon(1)) — irrelevant since D does not use it [verified].

## 5. Writing a snapshot: orphan commits, trailers, refs

```sh
tree=$(git write-tree)                                   # 10 ms warm, ~160–200 ms when cache-tree is invalid
# dedupe: skip when $tree == tree of the newest snapshot (keep "last seen" time in SQLite)
commit=$(printf '%s\n\n%s' "$subject" "$trailers" | git commit-tree "$tree")   # no -p => root commit, 9 ms
git update-ref "refs/airbag/snapshots/$ULID" "$commit" 0000000000000000000000000000000000000000   # 8 ms; old-oid zero = "must not exist"
```

- commit-tree(1): "Initial (root) commits have no parents" [verified]; the commit object as stored:

```
tree e183f2875124eb407e22393b12070756b502b015
author airbag <airbag@localhost> 1792274557 -0400
committer airbag <airbag@localhost> 1792274557 -0400

Before `rm -rf src/legacy`

Airbag-Schema: 1
Airbag-Trigger: pre-command
Airbag-Agent: claude-code
Airbag-Session: 0c6a8f7e-1d2b-4c3a-9e8f-7a6b5c4d3e2f
Airbag-Project: /tmp/airbag-gitprobe/project
Airbag-Command: rm -rf src/legacy
Airbag-Files: 20070
```

Suggested trailer schema (all optional except Schema/Trigger): `Airbag-Schema` (int), `Airbag-Trigger` (`pre-command|post-command|fsevents|manual|pre-restore|startup`), `Airbag-Agent` (`claude-code|codex|cursor|gemini-cli|unknown`), `Airbag-Session` (agent session id), `Airbag-Worktree` (path, when inside a worktree), `Airbag-Command` (first 1,000 bytes, newlines folded — trailers must be single logical lines; `interpret-trailers --unfold` handles continuation lines), `Airbag-Tool-Use` (hook `tool_use_id`), `Airbag-Files` (entry count). `GIT_COMMITTER_DATE='@<unix> +0000'` pins the timestamp if needed [verified].

- No reflog is created for `refs/airbag/*` (not under heads/remotes/notes; `core.logAllRefUpdates` default false in a bare repo; no `logs/` dir appeared) [verified], so `reflog expire` is a no-op (11 ms) and never blocks pruning.
- Refs are loose files until `git pack-refs --all` (22 ms for 40 refs); gc packs them too. Deleting a packed ref rewrites `packed-refs` [verified, measured 24 ms for 20 deletions via `update-ref --stdin`].
- Listing (8 ms for the test refs):

```sh
git for-each-ref --sort=-creatordate \
  --format='%(refname:lstrip=3)%00%(objectname)%00%(creatordate:unix)%00%(subject)%00%(trailers:unfold)%00%00' \
  refs/airbag/snapshots/
```

Caveat on 2.39: `%(trailers:key=K,valueonly)` works for a single atom, but two such atoms in one format both print the union of both keys' values (observed) — parse the `%(trailers:unfold)` block in Swift instead, or use `git log --no-walk=unsorted --format='%H %ct %(trailers:key=Airbag-Trigger,valueonly)' <shas…>` which behaves correctly [verified]. `git interpret-trailers --parse` on `%B` returns clean `Key: value` lines [verified]. Trailer options (`key=`, `only`, `separator=%x2C`, `unfold`, `keyonly`, `valueonly`, `key_value_separator`) are documented in git-log(1) PRETTY FORMATS [verified].

## 6. Listing changes and diffs

| Need | Command | Measured |
|---|---|---|
| snapshot A vs B | `git diff-tree -r -z --name-status -M --no-commit-id A B` | 10 ms |
| with modes/blob ids (for the UI and for the restore planner) | `git diff-tree -r -z --raw -M --no-commit-id A B` | 10 ms |
| summary line | `git diff-tree -r --stat --no-commit-id A B` (`4 files changed, 2 insertions(+), 9 deletions(-)`) | ~10 ms |
| live tree vs snapshot | `git diff -z --name-status <sha>` (work tree) | 21–35 ms with fresh stat data; **3,024–3,598 ms when the index has stale stat data** (e.g. right after `read-tree`), 22 ms again after `update-index --refresh` (23 ms) |
| per-file text diff | `git diff A B -- path`, `git diff <sha> -- path` (live), content: `git cat-file -p <sha>:path` | ms |

All [verified, measured]. Status letters: A C D M R T U X (diff-tree(1)); `-z` is mandatory for the machine form, otherwise "unusual" names are quoted per `core.quotePath` [verified]. `git diff <commit>` covers only paths in the index or the commit: a file created after the last snapshot is invisible to it until the next `update-index`; `ls-files -o --exclude-from=STORE/info/exclude` sees it but cannot look inside nested repos [verified]. Consequence: "what changed since the last snapshot" in the UI is cheapest as *take a snapshot, then diff-tree*.

## 7. Restore semantics

Test clone `project-r`, store-R; snapshots s0 (baseline), s1 (after: modify file000, delete file005, create new-after.txt and newdir/a.txt, chmod -x build.sh, repoint `link-to-file`, `rm -rf src/module002` (100 files), append to `.env`, edit nested file), then further uncaptured changes (untracked-after.txt, node_modules/pkgX/i.js, empty `newempty/`), then sNow = snapshot taken immediately before the project-level restore. Results [verified]:

| Operation | Command | Time | Observed |
|---|---|---|---|
| single file | `git restore --source=s0 --worktree -- src/module000/file000.ts` | 10 ms | content back; index entry untouched (`-W` only) |
| deleted file | `git checkout s0 -- src/module001/file005.ts` | 12 ms | recreated; checkout also updates the index entry |
| folder | `git restore --source=s0 --worktree -- src/module002` | 18 ms | 100 files back |
| project (variant 1) | snapshot-now (149 ms) then `git restore --source=s0 --staged --worktree -- .` | 72 ms | `new-after.txt` and `untracked-after.txt` removed (both tracked in sNow, absent in s0); `node_modules/pkgX`, 60 MiB `video.bin`, `newempty/` survive; symlink back to `README.md`; exec bit back; `.env` restored; nested file restored; nested `.git` and project `.git` untouched; index tree == s0; `git diff s0` empty |
| project (variant 2) | `git read-tree -m -u sNow s0` (index must equal sNow) | 102 ms | same end state; roll-forward `read-tree -m -u s0 sNow` 103 ms |
| no-op whole project | `git restore --source=s0 -S -W -- .` | 71 ms | nothing rewritten (checkout skips entries whose stat matches) |

Semantics confirmed in the sources: git-restore(1) "If a path is tracked but does not exist in the restore source, it will be removed to match the source" and "--no-overlay … remove tracked files that do not appear in the <tree> … The default is no-overlay mode" [verified]; `git checkout <tree-ish> -- <pathspec>` "Replace the specified files … and add them to the index", default overlay mode "never removes files" [verified]; `read-tree -m -u` two-tree rules: case 10 "clean, I==H, exists in H, nothing in M -> remove path", case 1 "nothing/nothing/exists -> use M", dirty entries that differ between H and M fail (cases 11–13, 16–17, 21), and "there is no need to worry about what exists only in the working tree" [verified].

Edge cases [verified]:

- Empty directories: git never tracks them; `newempty/` (never tracked) survived; `newdir/` disappeared once its last tracked file was removed by restore. A directory that was empty in the snapshot is not recreated.
- Dirty file protection: `read-tree -m -u s0 sNow` with `.env` modified on disk (and different between s0 and sNow) -> `error: Entry '.env' not uptodate. Cannot merge.`, exit 128, nothing changed. `git restore --source … -S -W -- .` overwrites such a file silently (checkout state `force = 1`, `refresh_cache = 1` in builtin/checkout.c) [verified].
- Type change file -> symlink: `restore` replaced the symlink with the regular file [verified].
- **File in snapshot, directory on disk**: `git restore --source=s0 --worktree -- package.json` where `package.json/` is now a directory with untracked `sub/inner.txt` — exit 0, directory and its contents deleted. Same when the directory contained a freshly `git init`ed `.git`: the "If it is a gitlink, leave it alone!" guard in entry.c applies to the *index entry's* mode, not to what is on disk [verified]. This is the one data-loss path in the restore design. `read-tree -m -u sNow s0` in the same situation refuses: `error: Updating 'src/b.ts' would lose untracked files in it`, exit 128, nothing changed; `restore -S -W -- .` and `checkout <tree> -- <path>` both delete the directory (exit 0) [verified]. So the conservative two-tree variant is also the safe one against this hazard.

## 8. Retention and disk accounting

Store-g, index v4, `gc.auto=0`: 40 snapshots, each modifying 300 source files and adding 50 new files, 30.7 s total (~0.77 s per snapshot incl. mutation) [verified, measured]:

| Step | Command | Time | Result |
|---|---|---|---|
| after 40 snapshots | `git count-objects -v` | 222 ms | `count: 38858, size: 158664 KiB, packs: 0`; `du` 160,320 KiB; 40 refs |
| pack refs | `git pack-refs --all` | 22 ms | 0 loose ref files, 41 lines in `packed-refs` |
| delete 20 oldest | `git for-each-ref --sort=creatordate --count=20 --format='delete %(refname)' refs/airbag/snapshots/ \| git update-ref --stdin` | 24 ms | 20 refs left |
| reflogs | `git reflog expire --expire=now --all` | 11 ms | nothing to do |
| **collect** | `git gc --prune=now --quiet` | **7,157 ms** | `count: 0, in-pack: 30378, packs: 1, size-pack: 6242 KiB`; `du` 7,756 KiB |
| repeat | `git gc --prune=now --quiet` | 95 ms | no-op |
| comparison, no deletions | `git repack -adq` + `git prune --expire=now` | 5,706 + 15 ms | `in-pack: 38858, size-pack: 6898 KiB`; `du` 8,564 KiB |
| 10 more snapshots -> 4,233 loose | `git repack -dq` (incremental, keeps existing packs) | 621 ms | `count: 1, packs: 2, size-pack: 7090 KiB` |
| same, two-step safe variant | `git maintenance run --task=loose-objects` | 1,800 ms | writes `loose-<id>.pack` (63 MB, no cross-pack deltas); loose objects are deleted only on the *next* run ("First, it deletes any loose objects that already exist in a pack-file") |
| cruft variant after deleting refs | `git repack -d --cruft -q` then `git repack -d --cruft --cruft-expiration=now -q` | 1,163 ms + 64 ms | unreachable objects parked in a cruft pack with `.mtimes`, then dropped |
| large single object | `git hash-object -w assets/video.bin` (60 MiB random) | 1,481 ms | loose object 62,933,710 B |

Observations:

- Loose objects cost one 4 KiB APFS block minimum: a single 20k-file snapshot is 84,196 KiB loose for 80,000 KiB of sources, and the `size:` field of `count-objects -v` reports exactly that disk usage (KiB) [verified]. After packing, the same data is ~6 MB — the synthetic files are padding-heavy, so real-world ratios will be worse; the loose-vs-packed gap, however, is structural.
- `gc --prune=now` "increases the risk of corruption if another process is writing to the repository concurrently" (git-gc(1) NOTES); objects newer than the prune date are kept otherwise [verified]. Airbag holds the store flock during gc, so this is safe.
- Plumbing does not run `gc --auto`: with `gc.auto=1`, `update-index`/`write-tree`/`commit-tree` left loose objects in place and no `gc.log`/`gc.pid` appeared [verified]. The stronger evidence is the source: `run_auto_maintenance()` is called from `builtin/commit.c`, `fetch.c`, `merge.c`, `am.c`, `rebase.c` and does not appear in `builtin/update-index.c`, `write-tree.c`, `commit-tree.c` or `update-ref.c` [verified, source grep 2026-10-17]; the local negative test alone is weak because the `--auto` heuristic samples `objects/17/` and rarely fires on a handful of objects [likely]. `gc.auto=0` "disables not only automatic packing … but also any other heuristic" [verified]; `gc --auto --quiet` with it set returns in 11 ms.
- `gc.cruftPacks` defaults to true upstream; 2.39 needed `--cruft` explicitly — the default `gc` run above produced one pack and no cruft pack [verified locally; upstream default from gc.adoc].
- `git maintenance run --task=incremental-repack` is a no-op here (28 ms; it only works through the multi-pack-index) [verified].
- `count-objects -v` fields: `count`/`size` (loose, KiB), `in-pack`, `packs`, `size-pack` (KiB), `prune-packable`, `garbage`/`size-garbage`; `-H` humanises [verified]. 222–403 ms with ~20–39k loose objects, 62 ms once packed — cheap enough for a settings screen, not for every snapshot.

## 9. Performance knobs

Approach D on clone `project-h`, fresh store per row; "stale" = `ls-files` + set difference in Python (interpreter start dominates; in Swift this is a few ms) [verified, measured]:

| Config | cold | no change (3 runs) | 10 changed | 2,000 changed | index size |
|---|---|---|---|---|---|
| defaults (index v2) | 7,609 ms | 147–167 ms total (update-index 47–53) | 156 ms | 852 ms (update-index 727) | 1,773,989 B |
| `index.version=4` | 7,506 ms | 137–139 ms (update-index 43–44) | 147 ms | 827 ms (712) | 1,375,923 B |
| v4 + `core.untrackedCache=true` | 7,819 ms | 141–144 ms | 150 ms | 884 ms | 1,376,123 B |
| v4 + `core.fsmonitor=true` + untrackedCache | 8,127 ms | 172–191 ms | 174 ms | 943 ms | FSMN + TREE extensions |

Component costs at no-change: walker 22–26 ms, `update-index` 43–47 ms, `write-tree` 10–11 ms, `commit-tree`+`update-ref` 19–22 ms, process spawn ~8 ms each (`git --version`).

For comparison, approach A (`git add -A -f` + exclude pathspecs) on the same stores: no change 40–47 ms, 10 changed 44–49 ms, 2,000 changed 687–816 ms; with fsmonitor 35–43 ms. The first A run on a store populated by D took 1.3–1.8 s because A also hashed the 60 MiB ignored binary [verified].

Knob verdicts:

- `index.version=4`: yes (22 % smaller index, marginally faster; "path-prefix compression", enabled by `feature.manyFiles`) [verified].
- `feature.manyFiles` = `index.skipHash=true` + `index.version=4` + `core.untrackedCache=true` upstream; on 2.39 `skipHash` is unknown, so set `index.version=4` explicitly instead [verified].
- `core.untrackedCache`: only helps directory traversal for `status`/`add`/`ls-files -o`; no effect on the update-index path, none measurable on A at 25k files on APFS [verified].
- `core.fsmonitor=true` (builtin daemon, "currently available only on Windows and macOS"): works with `--git-dir/--work-tree`; `git fsmonitor--daemon status` -> "watching '/private/tmp/airbag-gitprobe/project-h'"; spawns `git fsmonitor--daemon run --detach --ipc-threads=8` (RSS 5,040 KiB) and creates `STORE/fsmonitor--daemon.ipc` (socket in the git dir, as documented); no gain for update-index; the daemon keeps running until `fsmonitor--daemon stop` (no idle shutdown is documented) [verified]. Verdict: off — Airbag already has FSEvents in-process, and one orphan daemon per project contradicts the product's own "radar of orphans".
- `core.preloadIndex` (default true): irrelevant when stat data is fresh (22 ms diff); with stale stat data `diff` took 3,598 ms with preload on and 1,804 ms off (single runs). Lesson: never leave the index stale — every Airbag path that touches the index (`read-tree`, `restore -S`) is followed by stat refresh, and the normal snapshot path refreshes implicitly [verified].
- `pack.threads`/`index.threads`: defaults auto-detect; nothing to tune on 10 cores [unverified for this workload].
- Cold snapshot drivers (same 20k files): default 6,549 ms; `core.fsync=none` 7,065; `core.fsyncMethod=batch` 7,113; `core.looseCompression=0` 6,680; `--object-format=sha256` 6,973 — all within noise, so the cost is 20k loose-object creations (zlib + 20k file creations), not fsync (macOS default `fsyncMethod=writeout-only` and default `core.fsync=committed,-loose-object` already skip loose-object hardening) nor SHA-1 [verified]. Only a different storage strategy (e.g. `pack-objects` from a list, or APFS clones) would shrink the first snapshot; `git fast-import` was not tested.

## 10. Large and binary files

- git has no per-file size limit; `core.bigFileThreshold` (default 512 MiB) only disables delta compression/diff for bigger blobs [verified]. The cap must be the walker's (`st_size >= 50 MiB` skipped; `assets/video.bin` never entered any snapshot and survived every restore) [verified].
- Hashing is cheap (60 MiB in 67 ms when the object already exists), writing is not (1.48 s, 62.9 MB loose, random data does not compress) [verified]. A 3 MiB PNG went in without issue. Binary detection is not needed for storage; `diff-tree --name-status` works for binaries, `git diff` prints "Binary files differ".
- UI should mark skipped-by-cap files per snapshot (walker emits a side list) so a user restoring a project knows what was not covered.

## 11. Concurrency

- Two `update-index --stdin` on one store: the loser gets `fatal: Unable to create '…/index.lock': File exists.` immediately, exit 128; there is no retry/timeout for the index lock (only refs have `core.filesRefLockTimeout` 100 ms / `core.packedRefsTimeout` 1,000 ms) [verified].
- `flock(2)` on `STORE/airbag.lock` (LOCK_EX, with a deadline in production) serialises writers: process B took the lock first and ran 995 ms (2,000 changed files), A waited 995 ms and then ran 59 ms because B had already indexed the same state [verified]. No `index.lock` was left behind.
- Object writes are atomic (temp file + rename) and ref updates are locked per ref, so two processes writing *different* indexes (`GIT_INDEX_FILE`) and different refs would not corrupt the store [likely]; it is still pointless — the second snapshot of the same state is a duplicate. One flock, one index.
- Stale `index.lock` (hook killed by a timeout): while holding the flock, Airbag knows no other Airbag git runs on this store and may remove `index.lock` older than a few seconds before retrying [likely].

## 12. Store location, permissions, project identity

- Location: `~/Library/Application Support/Airbag/stores/<id>/` (git dir), `~/Library/Application Support/Airbag/airbag.sqlite` (registry). `~/Library` is not behind the Desktop/Documents/Downloads consent prompts; the *project* directories may be (Apple: "Some apps … can access files and folders in your Desktop, Downloads, and Documents folders", granted per app under Privacy & Security > Files & Folders) — Airbag, its CLI and the agent's shell are different apps for TCC purposes [verified doc; per-process attribution is [likely]].
- Permissions: `umask 077` + `--shared=0600` -> store `drwx------`, index `-rw-------`, objects `-r--------` (see 2). Snapshots contain `.env`; the sqlite registry must be 0600 as well.
- Project id: `SHA-256` of the canonical path from `fcntl(F_GETPATH)` on an opened directory fd. Measured [verified]:

| input | `realpath()` (Python, lstat-based) | `F_GETPATH` |
|---|---|---|
| `/tmp/airbag-gitprobe/project` | `/private/tmp/airbag-gitprobe/project` | same |
| `/TMP/AIRBAG-GITPROBE/PROJECT` | `/private/tmp/AIRBAG-GITPROBE/PROJECT` (case kept) | `/private/tmp/airbag-gitprobe/project` |
| symlink `proj-link` | resolved | resolved |
| `/System/Volumes/Data/private/tmp/…` (firmlink) | `/System/Volumes/Data/private/tmp/…` | `/private/tmp/airbag-gitprobe/project` |

APFS is case-insensitive by default on macOS [verified], so hashing a user-typed path would split one project into several stores. In Swift: `open(path, O_RDONLY)` + `fcntl(fd, F_GETPATH, &buf)` (or `URL.resourceValues(forKeys: [.canonicalPathKey])`, [unverified] that it matches F_GETPATH in all cases). Git worktrees are separate projects (different canonical paths); the registry links them to the main repo via `git rev-parse --git-common-dir` [likely].

## 13. Recommended command sequences

Environment prefix `G` = `env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=airbag GIT_AUTHOR_EMAIL=airbag@localhost GIT_COMMITTER_NAME=airbag GIT_COMMITTER_EMAIL=airbag@localhost git --git-dir="$STORE" --work-tree="$PROJECT"`. All steps under `flock "$STORE/airbag.lock"`.

Snapshot:

```sh
walker > paths.nul            # files+symlinks, NUL-separated, Airbag excludes, size cap, readable, no .git, no symlinked dirs
$G update-index --add --remove --replace -z --stdin < paths.nul
$G ls-files -z | set_difference paths.nul | $G update-index --force-remove -z --stdin    # stale entries
tree=$($G write-tree)
[ "$tree" = "$last_tree" ] && exit 0                              # dedupe, record "seen" timestamp in SQLite
commit=$(printf 'Before `%s`\n\nAirbag-Schema: 1\nAirbag-Trigger: %s\nAirbag-Agent: %s\nAirbag-Session: %s\nAirbag-Command: %s\nAirbag-Files: %d\n' … | $G commit-tree "$tree")
$G update-ref "refs/airbag/snapshots/$ulid" "$commit" 0000000000000000000000000000000000000000
```

List: `$G for-each-ref --sort=-creatordate --format='%(refname:lstrip=3)%00%(objectname)%00%(creatordate:unix)%00%(subject)%00%(trailers:unfold)%00%00' refs/airbag/snapshots/` (parse trailers in Swift).

Diff: `$G diff-tree -r -z --raw -M --no-commit-id A B`; per file `$G diff A B -- path`; live vs snapshot: take a snapshot, then diff-tree (fallback `$G diff -z --name-status <sha>` only when stat data is fresh).

Restore file/folder: `$G restore --source=<sha> --worktree -- <path>…` (`--pathspec-from-file=- --pathspec-file-nul` for many paths). Pre-check each target: if the snapshot entry is a blob/symlink and the on-disk path is a directory, stop and ask (git would delete the directory).

Restore project:

```sh
pre=$(snapshot --trigger pre-restore)                               # always; also makes index == live tree
$G diff-tree -r -z --raw --no-commit-id "$pre" "$target" > plan     # show the user what will be written/removed
# refuse/ask if any D->blob type conflict exists on disk (see 7)
$G restore --source="$target" --staged --worktree -- .               # removes paths tracked in $pre but absent in $target; never touches excluded/untracked
snapshot --trigger post-restore                                      # the undo of the undo
```

Prune:

```sh
$G for-each-ref --sort=creatordate --format='%(creatordate:unix) %(refname) %(objectname)' refs/airbag/snapshots/ | select_by_age_or_budget | sed 's/^[0-9]* /delete /' | $G update-ref --stdin
$G gc --prune=now --quiet                 # off-peak, under flock; 7 s per ~40k objects
# between gcs, after every N snapshots or when count-objects loose > ~2,000:
$G repack -dq                             # 0.6 s per few thousand loose objects
```

Accounting: `$G count-objects -v` (`size` + `size-pack` in KiB) at most once per minute or after prune; `git for-each-ref --format='%(objectsize:disk)'` is per commit object only, not per snapshot.

## 14. What this means for Airbag

1. Architecture holds: the `airbag` CLI needs only system git (`/usr/bin/git` is a shim; `xcode-select -p` / `xcrun --find git` must succeed first, otherwise macOS pops the "install Command Line Tools" dialog from inside a hook) plus a walker, SQLite and `flock`. Minimum git 2.39 (Apple Git-154 on macOS 15 CLT; newer Xcode/CLT builds report Apple Git-155 = 2.50.1 per community reports [likely]). Feature-detect, do not require, `attr.tree`, `index.skipHash`, cruft packs.
2. Hook budget: steady-state snapshot ~100–150 ms for a 20k-file project, 2,000 changed files ~0.8 s, far below hook timeouts; but the first snapshot (6.5–7.5 s per 20k files, linear in files/bytes) must run when a project is added in the GUI, never inside a `PreToolUse` hook. The hook must fail open when no store exists, when the flock is not obtained within ~2 s, or when git is missing.
3. One flock per store, one index. The GUI's FSEvents snapshotter and the CLI hook share the lock; a hook that finds the lock busy can wait and then skip (the in-flight snapshot already captured the state, as the concurrency test shows).
4. Snapshot content policy: walker excludes from `STORE/info/exclude` (defaults `node_modules/`, `dist/`, `.next/`, `.DS_Store`, `.git`), never the project's `.gitignore`; size cap 50 MiB with a per-snapshot "skipped" list; nested repos captured as plain files; nested `.git` directories not captured (decide in 15). Trailers carry session/command attribution from the hook JSON (`session_id`, `tool_input.command`, `tool_use_id`, `cwd`).
5. Byte fidelity: `info/attributes` unsetting `text/eol/filter/ident` plus `GIT_CONFIG_GLOBAL=/dev/null` are mandatory, otherwise restores can silently change line endings or store LFS pointers.
6. Restore UX: file/folder restores are instant and index-neutral; project restore is "snapshot, plan, apply, snapshot". The planner must (a) show additions/removals from `diff-tree --raw`, (b) hard-stop on blob-over-directory conflicts, (c) explain that files outside snapshots (excluded dirs, >50 MiB, empty dirs) are untouched — this is the opposite of the `git clean -fd` failure mode the market report cites. Use `restore -S -W` (fast, forced) after the pre-restore snapshot; `read-tree -m -u` is the conservative alternative if Airbag ever restores without snapshotting first, and it is the only one of the three that refuses the blob-over-directory conflict (7).
7. Disk policy (replaces "7 days / 5 GiB" with mechanics): `repack -dq` when loose objects exceed ~2,000 or after the initial snapshot (84 MB loose -> ~6 MB packed here); retention deletes refs by age (default 7 d) and by packed size budget, then `gc --prune=now` off-peak under the flock; show `count-objects` sizes in Settings; keep `gc.auto=0` so git never forks a background gc from a hook.
8. Knob set: `index.version=4`, `gc.auto=0`, `core.logAllRefUpdates=false`, `--shared=0600`, no fsmonitor, no untrackedCache, no fsync changes (they do not help), SHA-1 (sha256 gives nothing and complicates tooling).
9. Memory/CPU: all git work is short-lived child processes (~8 ms spawn each, 5 per snapshot); the only resident cost would be the fsmonitor daemon, which we do not use. FSEvents debounce (≥1–2 s) keeps idle CPU near zero since a no-change pass is ~45 ms of git time.
10. Registry: per-project id from `F_GETPATH`; SQLite rows mirror ref name, commit, tree, trigger, session, agent, file count, skipped-by-cap list, `size_delta_loose` (from `count-objects` deltas) so the timeline never has to shell out for listing.

## 15. Open questions

1. Should nested `.git` directories (and the project's own `.git`) be protected? Storing them needs the `.git~airbag` component rename via `--cacheinfo`/`--index-info` (verified possible) or a tar side-store; cost and restore semantics untested.
2. First-snapshot time on real repos (100k files, binaries, monorepos): is `pack-objects --stdout` from a walker list or APFS `clonefile` faster than 20k loose-object writes? Not measured.
3. Walker implementation choice in Swift (`fts(3)` vs `FileManager.enumerator`) and its cost at 100k+ files; the `find` baseline is 22 ms for 25k entries.
4. Hook timeout interplay: Claude Code kills a hook on timeout — confirm that a killed `update-index` leaves only `index.lock` (and no partial index) and that the stale-lock recovery in 11 is safe.
5. Real-world pack ratios: the synthetic corpus packs 25:1; measure on a few real vibe-coded projects (Next.js, Prisma, Python) to set the default size budget.
6. `git fast-import`/`fast-export` for store migration or export of a snapshot as `.zip` (`git archive <sha>` should work with `--git-dir`, untested).
7. Behaviour on case-sensitive APFS volumes and external/network volumes (fsmonitor is excluded anyway; `core.ignorecase` is probed from the *store* location, not the project — verify whether this matters for `--replace` and renames).
8. Whether newer Apple Git (2.50.x) changes defaults relevant here (`gc.cruftPacks=true`, `attr.tree`, reftable) and whether Airbag should bundle a pinned git instead of using the shim.

## Sources (accessed 2026-10-17)

- git-update-index(1): https://git-scm.com/docs/git-update-index
- git-restore(1): https://git-scm.com/docs/git-restore
- git-checkout(1): https://git-scm.com/docs/git-checkout
- git-read-tree(1): https://git-scm.com/docs/git-read-tree
- git-fsmonitor--daemon(1): https://git-scm.com/docs/git-fsmonitor--daemon
- git-ls-files(1): https://git-scm.com/docs/git-ls-files
- git-hash-object(1): https://git-scm.com/docs/git-hash-object
- git-commit-tree(1): https://git-scm.com/docs/git-commit-tree
- git-update-ref(1): https://git-scm.com/docs/git-update-ref
- git-for-each-ref(1): https://git-scm.com/docs/git-for-each-ref
- git-log(1) PRETTY FORMATS (trailers options): https://git-scm.com/docs/git-log
- git-diff-tree(1): https://git-scm.com/docs/git-diff-tree
- git-gc(1): https://git-scm.com/docs/git-gc
- git-repack(1): https://git-scm.com/docs/git-repack
- git-prune(1): https://git-scm.com/docs/git-prune
- git-pack-refs(1): https://git-scm.com/docs/git-pack-refs
- git-count-objects(1): https://git-scm.com/docs/git-count-objects
- git-maintenance(1): https://git-scm.com/docs/git-maintenance
- git-init(1): https://git-scm.com/docs/git-init
- gitattributes(5): https://git-scm.com/docs/gitattributes
- gitignore(5): https://git-scm.com/docs/gitignore
- gitglossary(7) pathspec magic: https://git-scm.com/docs/gitglossary
- git config core.*: https://raw.githubusercontent.com/git/git/master/Documentation/config/core.adoc
- git config index.*: https://raw.githubusercontent.com/git/git/master/Documentation/config/index.adoc
- git config feature.*: https://raw.githubusercontent.com/git/git/master/Documentation/config/feature.adoc
- git config gc.*: https://raw.githubusercontent.com/git/git/master/Documentation/config/gc.adoc
- git config attr.tree: https://raw.githubusercontent.com/git/git/master/Documentation/config/attr.adoc
- racy-git: https://raw.githubusercontent.com/git/git/master/Documentation/technical/racy-git.adoc
- builtin/update-index.c (die/ignore semantics): https://raw.githubusercontent.com/git/git/master/builtin/update-index.c
- read-cache.c (verify_path, add_to_index): https://raw.githubusercontent.com/git/git/master/read-cache.c
- entry.c (checkout_entry_ca, remove_subtree): https://raw.githubusercontent.com/git/git/master/entry.c
- builtin/checkout.c (state.force = 1): https://raw.githubusercontent.com/git/git/master/builtin/checkout.c
- Apple File System Guide FAQ (normalization, case): https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/FAQ/FAQ.html
- Apple: Control access to files and folders on Mac: https://support.apple.com/guide/mac-help/control-access-to-files-and-folders-on-mac-mchld5a35146/mac
- Apple Git versions (community reports): https://developer.apple.com/forums/thread/766184 , https://developer.apple.com/forums/thread/795617 , https://github.com/anthropics/claude-code/issues/35872
- Local measurements: `/tmp/airbag-gitprobe/{setup.py,env.zsh,s1.zsh..s7.zsh,walkE2.py,locked.py}` on macOS 15.7.9, git 2.39.5 (Apple Git-154).
- git-read-tree(1) two-tree merge table: https://git-scm.com/docs/git-read-tree (verification pass)

## Verification log (independent re-check, 2026-10-17)

Method: fresh synthetic project (project `.git`, nested repo, `.env`, `.gitignore`, CRLF file, `* text=auto` + `filter=lfs` attributes, symlink to file and to dir, FIFO, mode-000 file) under the session scratch dir; fresh bare stores via `git init --bare --template= --shared=0600`; `GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null`; git 2.39.5 (Apple Git-154), macOS 15.7.9. Sources fetched today. Each row: claim, evidence, verdict.

| # | Claim checked | Evidence | Verdict |
|---|---|---|---|
| 1 | `--git-dir=STORE --work-tree=PROJECT` on a bare store runs update-index/write-tree/diff/restore/checkout/read-tree -m -u; project `.git` untouched; init writes `filemode/ignorecase/precomposeunicode=true` | Probe: all six commands rc=0; md5 of every file under `project/.git` identical before/after; `git config --list` of the store shows the four `core.*` keys plus `sharedrepository=0600`. core.adoc: `core.ignoreCase` "default is false, except git-clone or git-init will probe the filesystem" | confirmed |
| 2 | `git add -A` without `-f` honours `.gitignore` (`.env`, `debug.log` lost); with `-f` it also bypasses `STORE/info/exclude`; nested repo -> `160000` gitlink; `add -f nested/file` -> "is in submodule"; `update-index --add --replace nested/file` stores a blob that later `add -A -f` keeps; `.git` components -> "Ignoring path", storable via `--cacheinfo` under a renamed component | Probe: `.env`/`debug.log` absent without `-f`, present with `-f` together with `node_modules/x/i.js` despite `info/exclude`; `160000 … nested`; fatal text reproduced; blob kept after `add -A -f`; `Ignoring path nested/.git/HEAD`, rc 0; `--cacheinfo 100644,<sha>,nested/.git~airbag/HEAD` rc 0. Nuance added: the "is in submodule" fatal requires the gitlink to exist; on an empty index `add -f nested/file` exits 0 and adds nothing. `-c core.excludesFile=STORE/info/exclude add -A` still drops `.env` | confirmed, nuance added (§4) |
| 3 | One unreadable file / FIFO / path through a symlinked dir makes `update-index --stdin` die and the whole batch is discarded (index written only at the end) | update-index.c (master): `update_one()` -> `die("Unable to process path %s")` when `process_path()` fails; `verify_path()` failure only `fprintf(stderr, "Ignoring path %s\n")` + `return`; index written once via `write_locked_index()` at the end of `cmd_update_index()`. Probe: batch `src/a.ts, unreadable.txt, src/b.ts` -> `fatal: Unable to process path unreadable.txt`, rc 128, no index file created; same for `zz-fifo` ("unsupported file type") and `link-to-dir/a.ts` ("is beyond a symbolic link"). Added: a vanished path without `--remove` is fatal too; `index.lock` is not left behind after `die()` | confirmed, two additions (§3.4) |
| 4 | Project `* text=auto` turns CRLF into LF in stored blobs; `STORE/info/attributes` `* -text -eol -filter -ident` has highest precedence and keeps bytes / neutralises `filter=lfs`; `attr.tree` ignored by 2.39 | gitattributes(5): "$GIT_DIR/info/attributes file (which has the highest precedence)"; "A missing filter driver definition … makes the filter a no-op passthru". attr.adoc: `attr.tree`, empty tree on invalid value, overridden by `GIT_ATTR_SOURCE`/`--attr-source`. Probe: blob of `docs/windows.bat` is `line1\nline2\n` without, `line1\r\nline2\r\n` with `info/attributes`; `check-attr` flips `text: auto`/`filter: lfs` to `unset`; `-c attr.tree=<empty tree>` and `GIT_ATTR_SOURCE` still report `text: auto`, `--attr-source` is "unknown option" | confirmed, `GIT_ATTR_SOURCE`/`--attr-source` note added (§2) |
| 5 | Orphan snapshots: `commit-tree` without `-p`, `update-ref refs/airbag/snapshots/<id> <sha> 0{40}`; no reflog for `refs/airbag/*`; trailers parse with `interpret-trailers --parse` and `git log %(trailers:key=…)`; `for-each-ref` with two trailer atoms prints the union on 2.39 | git-update-ref(1): reflog only for `refs/heads/`, `refs/remotes/`, `refs/notes/`, pseudorefs, or when `logs/<ref>` exists, under `core.logAllRefUpdates`; core.adoc: false by default in a bare repo; zero `<old-oid>` = "make sure that the ref you are creating does not exist". Probe: commit object has no `parent` line; second create with zero old-oid fails "reference already exists"; no `STORE/logs/` created; `for-each-ref … T=[%(trailers:key=Airbag-Trigger,valueonly)] A=[%(trailers:key=Airbag-Agent,valueonly)]` printed `pre-command\nclaude-code` for *both* atoms; `git log --no-walk=unsorted` with the same two atoms printed them separately; `interpret-trailers --parse` clean. git-log(1) documents `key=`, `only`, `separator`, `unfold`, `keyonly`, `valueonly`, `key_value_separator`; neither git-log(1) nor git-for-each-ref(1) documents the multi-atom behaviour | confirmed |
| 6 | Project restore = snapshot-now then `restore --source=<sha> --staged --worktree -- .` removes paths tracked in the index but absent in the source and leaves excluded dirs / empty dirs untouched, restores symlinks and exec bits, leaves nested and project `.git` intact; `read-tree -m -u A B` gives the same result and refuses dirty conflicting entries; blob-in-snapshot/directory-on-disk makes `restore`/`checkout` `remove_subtree()` the directory incl. untracked files and a nested `.git`, exit 0 | git-restore(1): "If a path is tracked but does not exist in the restore source, it will be removed to match the source"; "The default is no-overlay mode". git-read-tree(1) two-tree table: case 10 remove, 11–13/16/17/21 fail, "there is no need to worry about what exists only in the working tree". entry.c: `checkout_entry_ca()` -> `if (S_ISDIR(st.st_mode)) { if (S_ISGITLINK(ce->ce_mode)) return 0; … remove_subtree(&path); }` guarded by `state->force` (otherwise "%s already exists, no checkout"); builtin/checkout.c `checkout_worktree()`: `state.force = 1; state.refresh_cache = 1;`. Probe: `new-after.txt`, `untracked-after.txt`, `newdir/` removed; `node_modules/pkgX`, `newempty/`, both `.git` dirs survive; symlink target and mode 600 restored; index tree == s0, `git diff s0` empty; `read-tree -m -u` with dirty `.env` -> `Entry '.env' not uptodate. Cannot merge.`, rc 128, while `restore -S -W` overwrote it; `restore --worktree -- docs/windows.bat` over a directory containing `sub/inner.txt` and a fresh `.git` -> rc 0, directory gone; same with `checkout <tree> -- src/a.ts`. New: `read-tree -m -u` refuses the same case ("would lose untracked files in it", rc 128) | confirmed, read-tree safety note added (§7, §14.6, TL;DR 6) |
| 7 | Plumbing never triggers `gc --auto` even with `gc.auto=1`; `gc.auto=0` disables all auto-gc heuristics; `gc --prune=now` risky only with concurrent writers | git-gc(1): "Setting this to 0 disables not only automatic packing … but also any other heuristic"; `--prune=now … increases the risk of corruption if another process is writing to the repository concurrently"; NOTES mitigations 1–2. Source grep (master): `run_auto_maintenance` present in builtin/commit.c, fetch.c, merge.c, am.c, rebase.c; absent from update-index.c, write-tree.c, commit-tree.c, update-ref.c. Probe with `gc.auto=1`: 3 loose objects, no pack, no `gc.log`/`gc.pid` after the plumbing sequence. The doc's local negative test is weak on its own (heuristic samples `objects/17/`); the source grep is what supports "never" | confirmed via source; caveat added (§8) |
| 8 | A concurrent second `update-index` fails immediately with `Unable to create '…/index.lock': File exists` (no retry); only refs have lock timeouts (`core.filesRefLockTimeout` 100 ms, `core.packedRefsTimeout` 1000 ms) | core.adoc: `core.filesRefLockTimeout` "Default is 100", `core.packedRefsTimeout` "Default is 1000", `core.configLockTimeout` exists; no index-lock timeout option. Probe: with a pre-existing `index.lock`, `update-index` failed in 24 ms wall-clock (process spawn), rc 128, message reproduced; with a pre-existing `refs/airbag/snapshots/01A.lock`, `update-ref` failed after 177 ms (consistent with the 100 ms retry window) | confirmed |
| 9 | `F_GETPATH` canonicalises case, symlinks, `/tmp` -> `/private/tmp`, `/System/Volumes/Data` firmlink; lstat-based `realpath` keeps typed case | Probe (Python `fcntl(fd, F_GETPATH)`): `/TMP/AIRBAG-GITPROBE/PROJECT` -> `/private/tmp/airbag-gitprobe/project`, `realpath` -> `/private/tmp/AIRBAG-GITPROBE/PROJECT`; firmlink path -> `/private/tmp/…` via `F_GETPATH`, kept by `realpath`; symlink resolved by both | confirmed |
| 10 | `--shared=0600` -> index `-rw-------`, object dirs `drwx------`, objects `-r--------` | git-init(1): `<perm>` "3-digit octal number prefixed with 0 … will override users' umask(2) value"; core.adoc `core.sharedRepository`. Probe: `core.sharedrepository=0600`, `objects/xx` `drwx------`, loose objects `-r--------`, `index` `-rw-------` | confirmed |

Not re-verified here (left at the colleague's tags): all absolute timings (facts about ms/s on the 20k-file corpus), the loose-object/gc disk numbers, `index.version=4`/fsmonitor/untrackedCache/fsync knob results, the 60 MiB hash-object timing, APFS normalization behaviour, Desktop/Documents TCC consent, and the Apple Git-155 = 2.50.1 version claim ([likely], community reports only).

