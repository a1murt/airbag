import Foundation

/// Finds the snapshot root for a working directory: the nearest ancestor containing `.git` (a directory for a
/// main checkout, a file for a worktree), else one of the registered roots containing the path, else the
/// directory itself.
public enum RootResolver {
    public static func resolve(cwd: String, registeredRoots: [String] = []) -> String {
        let start = FileSystem.canonicalPath(cwd) ?? FileSystem.resolvedPath(cwd)
        var dir = start
        while dir != "/" && !dir.isEmpty {
            var st = stat()
            if lstat(dir + "/.git", &st) == 0 { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        if let registered = registeredRoots.filter({ start == $0 || start.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            return registered
        }
        return start
    }
}
