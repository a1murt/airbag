import Foundation

/// What the walker skips. The project's .gitignore is deliberately NOT honoured (doc 10 §5, ADR-005).
public struct Exclusions: Sendable {
    public static let defaultDirectoryNames: Set<String> = [
        ".git", ".hg", ".svn", ".jj",
        "node_modules", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".vite", ".angular",
        "dist", "build", "out", "target", ".build", "DerivedData", "Pods", ".gradle",
        ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox",
        ".cache", "coverage", ".nyc_output", ".terraform", ".serverless", ".vercel", ".netlify",
        ".expo", ".dart_tool", ".wrangler", ".docusaurus",
    ]
    /// Root-relative directory paths (multi-component) that are skipped.
    public static let defaultRelativePaths: Set<String> = [".claude/worktrees", ".idea/caches", ".codex/worktrees"]
    public static let defaultFileNames: Set<String> = [".DS_Store"]

    public var directoryNames: Set<String>
    public var relativePaths: Set<String>
    public var fileNames: Set<String>
    public var maxFileBytes: Int64

    public init(directoryNames: Set<String> = Exclusions.defaultDirectoryNames,
                relativePaths: Set<String> = Exclusions.defaultRelativePaths,
                fileNames: Set<String> = Exclusions.defaultFileNames,
                maxFileBytes: Int64 = 100 << 20) {
        self.directoryNames = directoryNames
        self.relativePaths = relativePaths
        self.fileNames = fileNames
        self.maxFileBytes = maxFileBytes
    }

    public static var standard: Exclusions { Exclusions() }

    func skipsDirectory(name: String, relativePath: String) -> Bool {
        directoryNames.contains(name) || relativePaths.contains(relativePath)
    }

    /// True when the root-relative path lies inside an excluded directory.
    func isExcluded(relativePath: String) -> Bool {
        let comps = relativePath.split(separator: "/")
        guard !comps.isEmpty else { return false }
        if let last = comps.last, fileNames.contains(String(last)) { return true }
        var prefix = ""
        for c in comps.dropLast() {
            prefix = prefix.isEmpty ? String(c) : prefix + "/" + c
            if directoryNames.contains(String(c)) || relativePaths.contains(prefix) { return true }
        }
        return false
    }
}
