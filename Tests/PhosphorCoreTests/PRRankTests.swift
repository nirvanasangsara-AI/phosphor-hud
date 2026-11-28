import Testing
import Foundation
@testable import PhosphorCore

@Suite struct PRRankTests {
    @Test func elevenAndTwentyMatchTheFittedCurves() {
        let table = PRRankTable.bundled
        #expect(table.builtAt == "2026-11-28")
        let eleven = table.lookup(publicCount: 11)!
        #expect(abs(eleven.topPercentLow - 9.25) < 0.05)
        #expect(abs(eleven.topPercentHigh - 21.66) < 0.05)
        #expect(PRRankTable.percentText(eleven.topPercentLow) == "9")
        #expect(PRRankTable.percentText(eleven.topPercentHigh) == "22")

        let twenty = table.lookup(publicCount: 20)!
        #expect(abs(twenty.topPercentLow - 5.27) < 0.05)
        #expect(abs(twenty.topPercentHigh - 12.44) < 0.05)
        #expect(PRRankTable.percentText(twenty.topPercentLow) == "5")
        #expect(PRRankTable.percentText(twenty.topPercentHigh) == "12")

        let twentyFive = table.lookup(publicCount: 25)!
        #expect(PRRankTable.percentText(twentyFive.topPercentLow) == "4")
        #expect(PRRankTable.percentText(twentyFive.topPercentHigh) == "10")
    }

    @Test func zeroHidesAndAThousandIsTheCeiling() {
        let table = PRRankTable.bundled
        #expect(table.lookup(publicCount: 0) == nil)
        #expect(table.lookup(publicCount: 1000) == table.lookup(publicCount: 5000))
        #expect(table.lookup(publicCount: 1) != nil)
        #expect(table.nextTier?.perWeekLow == 22)
        #expect(table.nextTier?.perWeekHigh == 47)
    }

    @Test func subOnePercentKeepsOneDecimal() {
        #expect(PRRankTable.percentText(0.04) == "0.0")
        #expect(PRRankTable.percentText(0.926) == "0.9")
        #expect(PRRankTable.percentText(1.84) == "2")
    }

    @Test func workerSnapshotMatchesTheBundledTable() throws {
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
