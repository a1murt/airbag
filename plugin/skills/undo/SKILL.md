---
name: undo
description: Put back what an agent's shell command changed in this project, from the snapshot Airbag took right before it. Use when the user asks to undo, revert or restore what a command did (a deleted folder, a git reset --hard, an overwritten file).
argument-hint: "[change-id]"
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/airbag undo)
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/airbag undo *)
---

# Undo with Airbag

Airbag snapshots this project before each shell command an agent runs that can change files. `airbag undo` puts the
files back as they were before the newest such command, or before the change whose id it is given. It never deletes
files, and an undo can itself be undone.

1. See what the undo would do. Run this from the project folder:

   `${CLAUDE_PLUGIN_ROOT}/scripts/airbag undo --dry-run $ARGUMENTS`

   If the user means an earlier change, list the recent ones with `${CLAUDE_PLUGIN_ROOT}/scripts/airbag undo --list`,
   take its id (the first column) and run the dry run with that id instead.
2. Tell the user in two or three lines which command it undoes, when it ran, and which files come back. If the output
   says there is nothing to undo, or that Airbag is not installed, say so and stop.
3. Ask whether to go ahead. Only after a clear yes, run the same command without `--dry-run` and report its output,
   including the line that says how to undo the undo.

Never run `airbag allow`, `airbag prune`, `airbag cleanup` or `airbag hooks uninstall`: those are for the user to run.
