import Foundation

/// Local git repositories under the folders Phosphor is allowed to scan.
public enum LocalRepoScan {
    public static let defaultFolderNames = ["Projects", "Developer", "code", "src", "workspace"]
    /// Directory names that are never walked into. Matched case-insensitively.
    public static let skippedDirectoryNames: Set<String> = [
        "node_modules", ".build", "dist", "build", "deriveddata", "pods", "carthage",
        ".swiftpm", "vendor", "target", "out", "coverage", ".next", ".turbo",
    ]
    public static let maxRepos = 30

    public static func roots(home: URL, custom: [String]) -> [URL] {
        let paths = custom.isEmpty ? defaultFolderNames.map { home.appendingPathComponent($0).path } : custom
        return paths.map { URL(fileURLWithPath: expand($0, home: home)) }
    }

    public static func expand(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + path.dropFirst(1) }
        return path
    }

    public static func displayPath(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let root = home.standardizedFileURL.path
        if path == root { return "~" }
        if path.hasPrefix(root + "/") { return "~" + path.dropFirst(root.count) }
        return path
    }

    /// Repositories whose `.git` is at most two levels below a root (`root`, `root/repo`, `root/group/repo`).
    /// The 30 most recently modified win when there are more.
    public static func discover(roots: [URL], fileManager: FileManager = .default, limit: Int = maxRepos) -> [URL] {
        var hits: [(url: URL, modified: Date)] = []
        var seen = Set<String>()
        for root in roots {
            var isDir = ObjCBool(false)
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { continue }
            collect(root, depth: 0, into: &hits, seen: &seen, fm: fileManager)
        }
        hits.sort { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.url.path < rhs.url.path
        }
        return Array(hits.prefix(max(0, limit)).map(\.url))
    }

    private static func collect(_ dir: URL, depth: Int, into hits: inout [(url: URL, modified: Date)],
                                seen: inout Set<String>, fm: FileManager) {
        let git = dir.appendingPathComponent(".git")
        var gitDir = ObjCBool(false)
        if fm.fileExists(atPath: git.path, isDirectory: &gitDir) {
            let key = dir.standardizedFileURL.path
            if seen.insert(key).inserted {
                let modified = (try? fm.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date ?? .distantPast
                hits.append((dir, modified))
            }
            return
        }
        guard depth < 2 else { return }
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where !skippedDirectoryNames.contains(name.lowercased()) && !name.hasPrefix(".") {
            let child = dir.appendingPathComponent(name)
            var isDir = ObjCBool(false)
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
            collect(child, depth: depth + 1, into: &hits, seen: &seen, fm: fm)
        }
    }
}
