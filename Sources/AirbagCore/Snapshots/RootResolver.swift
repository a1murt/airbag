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

/// Folders the user stopped protecting ("Stop Protecting…"). Hooks take no snapshots there; the folder still counts as
/// a project for Guard rules, so commands in it are judged the same way. Adding the folder again removes it from the list.
public enum IgnoredRoots {
    public static func load(paths: AirbagPaths) -> Set<String> {
        guard let data = try? Data(contentsOf: paths.ignoredRoots), let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    public static func contains(_ root: String, paths: AirbagPaths) -> Bool {
        FileManager.default.fileExists(atPath: paths.ignoredRoots.path) && load(paths: paths).contains(FileSystem.canonicalPath(root) ?? root)
    }

    public static func set(_ root: String, ignored: Bool, paths: AirbagPaths) throws {
        var list = load(paths: paths)
        let canonical = FileSystem.canonicalPath(root) ?? root
        if ignored { list.insert(canonical) } else { list.remove(canonical) }
        let data = try JSONEncoder().encode(list.sorted())
        try FileSystem.ensureDirectory(paths.home.path, mode: 0o700)
        try data.write(to: paths.ignoredRoots, options: .atomic)
    }
}
