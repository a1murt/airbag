import Foundation

/// Finds the snapshot root for a working directory: the nearest ancestor containing `.git` (a directory for a
/// main checkout, a file for a worktree) below the home folder and system locations, else one of the registered
/// roots containing the path, else the directory itself.
public enum RootResolver {
    public static func resolve(cwd: String, registeredRoots: [String] = [], home: String = NSHomeDirectory()) -> String {
        let start = FileSystem.canonicalPath(cwd) ?? FileSystem.resolvedPath(cwd)
        var dir = start
        while dir != "/" && !dir.isEmpty {
            var st = stat()
            if lstat(dir + "/.git", &st) == 0 {
                // A dotfiles repository in the home folder is not the project of every folder below it.
                if SnapshotStore.isSystemOrHomeFolder(dir, home: home) { break }
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        // A launch folder such as ~ or ~/Downloads is not a project either.
        let usable = registeredRoots.filter { !SnapshotStore.isSystemOrHomeFolder($0, home: home) }
        if let registered = usable.filter({ start == $0 || start.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            return registered
        }
        return start
    }
}
