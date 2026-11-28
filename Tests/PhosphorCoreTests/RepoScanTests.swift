import Foundation
import Testing
@testable import PhosphorCore

@Suite struct RepoScanTests {
    @Test func defaultsIncludeWorkspaceAndDiscoveryRespectsDepthSkipAndCap() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("phosphor-home-\(UUID().uuidString)")
        let names = LocalRepoScan.defaultFolderNames
        #expect(names == ["Projects", "Developer", "code", "src", "workspace"])
        let roots = LocalRepoScan.roots(home: home, custom: [])
        #expect(roots.map(\.lastPathComponent) == names)

        let root = home.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func repo(_ path: String, modified: Date) throws {
            let dir = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: dir.path)
        }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try repo("self", modified: base)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/hidden/.git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".build/hidden/.git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dist/hidden/.git"), withIntermediateDirectories: true)
        try repo("group/child", modified: base.addingTimeInterval(10))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("group/child/nested/.git"), withIntermediateDirectories: true)
        try repo("group/too/deep", modified: base.addingTimeInterval(50))

        var found = LocalRepoScan.discover(roots: [root]).map { $0.lastPathComponent }
        #expect(found.contains("self"))
        #expect(found.contains("child"))
        #expect(!found.contains("hidden"))
        #expect(!found.contains("deep"))
        #expect(!found.contains("nested"))

        for i in 0..<35 {
            try repo("many/repo-\(i)", modified: base.addingTimeInterval(Double(i + 1) * 100))
        }
        found = LocalRepoScan.discover(roots: [root]).map(\.lastPathComponent)
        #expect(found.count == 30)
        #expect(found.first == "repo-34")
        #expect(!found.contains("repo-0"))
        #expect(LocalRepoScan.displayPath(root, home: home) == "~/workspace")
        try? FileManager.default.removeItem(at: home)
    }
}
