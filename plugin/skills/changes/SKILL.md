---
name: changes
description: Show what agents' shell commands changed in this project lately, each with the snapshot Airbag took before it, and what Airbag blocked or asked about. Use when the user asks what an agent changed, deleted or ran here.
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/airbag undo --list*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/airbag log*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/airbag guard*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/airbag changes *)
---

# What changed here

Run these from the project folder and sum them up for the user. Keep the ids, so that a change can be undone.

- `${CLAUDE_PLUGIN_ROOT}/scripts/airbag undo --list`: the commands that changed files in this project, newest first,
  each with an id and the number of files it changed.
- `${CLAUDE_PLUGIN_ROOT}/scripts/airbag guard`: commands Airbag blocked, asked about, or let through as risky.
- `${CLAUDE_PLUGIN_ROOT}/scripts/airbag log`: recent agent commands in all projects, with Airbag's decision on each.
- `${CLAUDE_PLUGIN_ROOT}/scripts/airbag changes <id>`: the files one change touched, when the user wants the detail.

Lead with what matters most: anything deleted, reset or blocked. End by saying that `/airbag:undo <id>` puts a change
back. If the output says Airbag is not installed, pass that on and stop.
