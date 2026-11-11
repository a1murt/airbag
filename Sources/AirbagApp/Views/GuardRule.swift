import Foundation

/// Guard rule ids as people read them: what a rule's command does in the user's language, what kind of harm it is
/// about, and whether it can be turned off (also for the list of rules that are turned off).
enum GuardRule {
    /// Rules that can block (RuleEngine: wiping home, a disk or system folders, the system itself, Airbag's own data
    /// and hooks, emptying the Trash, deleting a GitHub repository). RuleEngine drops every finding of a disabled rule,
    /// so the app never offers to turn these off.
    static func canTurnOff(_ ruleID: String) -> Bool {
        let parts = ruleID.split(separator: ".").map(String.init)
        if ["sys", "disk", "self"].contains(parts.first ?? "") { return false }
        if parts.contains("catastrophic") || parts.contains("device") || ruleID.hasPrefix("fs.rm.home") { return false }
        return !["fs.trash.empty", "gh.repo.delete"].contains(ruleID)
    }

    /// What kind of harm the rule is about, from its id ("git.push.force" → Git history, "fs.rm.project" → project files).
    static func category(_ ruleID: String) -> String? {
        let parts = ruleID.split(separator: ".").map(String.init)
        if parts.contains("project") || parts.contains("project-root") || parts.contains("worktree") {
            return String(localized: "Project files")
        }
        switch parts.first ?? "" {
        case "fs": return String(localized: "Files outside the project")
        case "interp": return ruleID == "interp.delete" ? String(localized: "Unclear command") : String(localized: "Files outside the project")
        case "git": return String(localized: "Git history")
        case "gh": return "GitHub"
        case "cloud": return String(localized: "Cloud resources")
        case "docker": return String(localized: "Containers")
        case "pkg": return String(localized: "Packages")
        case "remote": return String(localized: "Remote machines")
        case "snapshot": return String(localized: "Snapshots")
        case "sys", "disk": return String(localized: "System")
        case "net": return String(localized: "Downloaded script")
        case "shell": return String(localized: "Unclear command")
        case "self": return String(localized: "Airbag's protection")
        case "db": return String(localized: "Databases")
        default: return nil
        }
    }

    /// What the command does, for the user. The reason the rule gives the agent is English and names paths ("it deletes
    /// ~/.ssh, which no snapshot covers"); in another language the user reads this rule's summary instead (the reason
    /// stays in the tooltip). GuardRuleCatalogTests keeps the ids here and the ids the engine reports the same.
    static func explanation(_ ruleID: String, reason: String) -> String {
        if Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true { return readable(reason) }
        return summaries[ruleID] ?? readable(reason)
    }

    /// The rule's reason is written for the agent ("it deletes …"); people read it as a sentence.
    static func readable(_ reason: String) -> String {
        var s = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("it ") { s = String(s.dropFirst(3)) }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static let summaries: [String: String] = {
        let projectDelete = String(localized: "Deletes project files; a snapshot is taken first.")
        let projectChange = String(localized: "Changes project files; a snapshot is taken first.")
        let worktrees = String(localized: "Deletes or moves a folder that holds agent worktrees; each gets a snapshot first.")
        let writeOutside = String(localized: "Overwrites files outside the protected project, where no snapshot can restore them.")
        let opaquePath = String(localized: "Acts on a path built from an unresolved variable; an empty value could make it much wider.")
        let catastrophic = String(localized: "Would destroy your home folder, a system folder or other files no snapshot covers.")
        let writeInto = String(localized: "Writes into your home folder or a similar place, where it can replace files no snapshot covers.")
        let gitInternals = String(localized: "Changes git's internal files (.git), which are not in snapshots.")
        let github = String(localized: "Deletes data on GitHub.")
        let cloud = String(localized: "Deletes cloud resources, which no local snapshot can bring back.")
        let database = String(localized: "Wipes database data, which file snapshots can't restore.")
        return [
            "fs.rm.project": projectDelete, "fs.find.delete.project": projectDelete, "git.rm": projectDelete,
            "interp.delete.project": projectDelete, "docker.mount.delete.project": projectDelete,
            "fs.truncate.project": projectChange, "fs.write.project": projectChange, "fs.mv.project": projectChange,
            "git.checkout.discard": String(localized: "Overwrites files in the working tree; a snapshot is taken first."),
            "fs.rm.project-root": String(localized: "Deletes the whole project folder; a snapshot is taken first, but git history is not in it."),
            "fs.rm.worktree": worktrees, "fs.mv.worktree": worktrees,
            "fs.rm.outside": String(localized: "Deletes files outside the protected project, where no snapshot can restore them."),
            "fs.mv.outside": String(localized: "Moves files outside the protected project."),
            "fs.truncate.outside": writeOutside, "fs.write.outside": writeOutside,
            "fs.perm.outside": String(localized: "Changes permissions of many files outside the protected project."),
            "fs.rm.opaque": opaquePath, "fs.mv.opaque": opaquePath, "fs.truncate.opaque": opaquePath, "fs.perm.opaque": opaquePath,
            "shell.opaque-command": String(localized: "Runs a program whose name is only known at run time on your home folder, a system folder or Airbag's data."),
            "fs.rm.unset-variable": String(localized: "Deletes from a path that starts with a variable; if it is empty, the path starts at the root of the disk."),
            "fs.rm.unknown-folder": String(localized: "Deletes everything in a folder Airbag cannot determine, which may be your home folder."),
            "fs.rm.catastrophic": catastrophic, "fs.mv.catastrophic": catastrophic, "fs.overwrite.catastrophic": catastrophic,
            "fs.redirect.catastrophic": catastrophic, "interp.delete.catastrophic": catastrophic,
            "fs.write.into.catastrophic": writeInto, "fs.extract.overwrite": writeInto,
            "fs.find.delete.broad": String(localized: "Deletes matching files all over a folder that snapshots don't cover."),
            "fs.rsync.delete.remote": String(localized: "Deletes files on a remote machine that are missing locally."),
            "fs.trash.empty": String(localized: "Empties the Trash for good."),
            "fs.device.write": String(localized: "Writes straight to a device, which can destroy a disk."),
            "git.checkout": String(localized: "Switches the files in the working tree."),
            "git.clean": String(localized: "Deletes untracked files; a snapshot is taken first, except for dependency and build folders."),
            "git.gc.prune": String(localized: "Permanently removes unreachable commits that could otherwise be recovered."),
            "git.history.rewrite": String(localized: "Rewrites the repository's history."),
            "git.internals.delete": gitInternals, "git.internals.write": gitInternals,
            "git.outside-root": String(localized: "Runs a destructive git command outside the protected project, so no snapshot covers it."),
            "git.push.delete": String(localized: "Deletes a branch or tag on the remote."),
            "git.push.force": String(localized: "Rewrites history on the remote, which can't be undone from this Mac."),
            "git.push.mirror": String(localized: "Can delete remote branches that don't exist locally."),
            "git.reflog.expire": String(localized: "Deletes the reflog, git's own safety net for lost commits."),
            "git.reset.hard": String(localized: "Discards uncommitted changes; a snapshot is taken first."),
            "git.stash": String(localized: "Moves local changes into a stash; the snapshot taken first covers them too."),
            "git.stash.drop": String(localized: "Permanently drops stashed changes, which are not in snapshots."),
            "git.submodule.deinit": String(localized: "Force-removes submodule working trees."),
            "git.update-ref.delete": String(localized: "Deletes a git ref directly."),
            "git.worktree.remove": String(localized: "Force-removes a worktree, uncommitted changes included."),
            "git.branch.force-delete": String(localized: "Force-deletes a branch that may hold unmerged commits."),
            "gh.api.delete": github, "gh.delete": github,
            "gh.repo.delete": String(localized: "Deletes a GitHub repository with all its issues and history."),
            "cloud.delete": cloud, "cloud.iac.destroy": cloud, "cloud.paas.destroy": cloud,
            "cloud.k8s.delete": String(localized: "Deletes resources on a Kubernetes cluster."),
            "db.destructive": database, "db.reset": database, "db.reset.local": database, "db.reset.script": database,
            "db.local.destructive": String(localized: "Deletes data in a database file in the project; a snapshot is taken first."),
            "docker.destructive": String(localized: "Deletes container volumes or images, which can hold databases that snapshots don't cover."),
            "docker.mount.delete": String(localized: "Deletes files in a folder mounted into a container, where Airbag can't check them."),
            "self.airbag": String(localized: "Changes or switches off Airbag itself; only you should do that."),
            "self.allow": String(localized: "Tries to approve a command Airbag stopped; only you can do that."),
            "self.hooks": String(localized: "Changes an agent's hook settings, which can switch Airbag's protection off."),
            "shell.opaque": String(localized: "Runs shell code Airbag can't read: built from variables, decoded or generated by another command."),
            "shell.too-deep": String(localized: "Nests shells too deeply to analyze."),
            "shell.unparsed": String(localized: "Has a quote or substitution that is never closed, so Airbag can't tell what it runs."),
            "net.pipe.shell": String(localized: "Pipes a downloaded script straight into a shell."),
            "interp.delete": String(localized: "Deletes files from inline code that Airbag can't fully analyze."),
            "pkg.unpublish": String(localized: "Removes a published package from the registry, which no local snapshot can bring back."),
            "remote.destructive": String(localized: "Runs a destructive command on a remote machine, beyond anything Airbag can snapshot."),
            "snapshot.unavailable": String(localized: "Destructive, and Airbag couldn't take a complete snapshot first."),
            "sys.crontab.remove": String(localized: "Deletes all your cron jobs without confirmation."),
            "sys.defaults.delete": String(localized: "Deletes an app's preferences."),
            "sys.disk.erase": String(localized: "Erases or repartitions a disk."),
            "sys.keychain.delete": String(localized: "Deletes a keychain with every password, key and certificate in it."),
            "sys.keychain.item.delete": String(localized: "Deletes saved passwords, keys or certificates from the keychain."),
            "sys.kill.all": String(localized: "Kills all your processes, the agent and every open app included."),
            "sys.kill.broad": String(localized: "Kills every process with a common name, possibly the agent, editors or other projects' servers."),
            "sys.launchctl.run": String(localized: "Starts a program through launchd, outside the agent's view."),
            "sys.launchctl.session": String(localized: "Ends your login session: every app and agent quits, unsaved work is lost."),
            "sys.launchctl.system": String(localized: "Stops or removes system services."),
            "sys.osascript": String(localized: "Runs an AppleScript that can delete files or run commands outside the project."),
            "sys.power": String(localized: "Shuts down or restarts the Mac and every running session."),
            "sys.security": String(localized: "Changes low-level system security or boot settings."),
            "sys.sudo": String(localized: "Runs with administrator rights, beyond what Airbag can snapshot or undo."),
            "sys.tmutil": String(localized: "Deletes Time Machine backups or turns them off."),
        ]
    }()
}
