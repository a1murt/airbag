---
name: status
description: Check whether Airbag is protecting this project, whether Claude Code is connected to it, and the latest snapshots here. Use when the user asks if Airbag is installed, on, or working.
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/airbag version*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/airbag hooks status*)
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/airbag snapshots*)
---

# Airbag status

Run these and report in a few lines:

1. `${CLAUDE_PLUGIN_ROOT}/scripts/airbag version`: the installed version, or that Airbag is not installed and how to
   install it.
2. `${CLAUDE_PLUGIN_ROOT}/scripts/airbag hooks status`: which agents are connected. For Claude Code, "connected through
   the Claude Code plugin" means this plugin does the work and "installed" means the app connected it itself; both
   protect.
3. `${CLAUDE_PLUGIN_ROOT}/scripts/airbag snapshots --limit 5`, from the project folder: the latest snapshots of this
   project. None yet is normal until a command here changes files.

If something is off, such as a hook that points at a moved copy of the app, say how to fix it: open Airbag from the
menu bar, then Settings → Agents.
