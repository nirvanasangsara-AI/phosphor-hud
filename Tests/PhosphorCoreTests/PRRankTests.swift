import Testing
import Foundation
@testable import PhosphorCore

@Suite struct PRRankTests {
    @Test func bundledSnapshotMatchesTheStatedAnalysis() {
        let table = PRRankTable.bundled
        #expect(table.builtAt == "2026-11-28")
        #expect(table.bundled)
        let hit = table.lookup(publicCount: 11)
        #expect(hit?.topPercentLow == 10)
        #expect(hit?.topPercentHigh == 20)
        #expect(hit?.next?.topPercent == 5)
        #expect(hit?.next?.perWeekLow == 22)
        #expect(hit?.next?.perWeekHigh == 41)
        #expect(table.lookup(publicCount: 10) == nil)
        #expect(table.lookup(publicCount: 12) == nil)
    }

    @Test func fileSnapshotMatchesTheEmbeddedTable() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("workers/pr-rank/snapshot/rank.json")
        let data = try Data(contentsOf: url)
        let file = try #require(PRRankTable.decode(data))
        #expect(file == .bundled)
    }
}
