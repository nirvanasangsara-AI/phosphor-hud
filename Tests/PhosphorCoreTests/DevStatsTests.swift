import Testing
import Foundation
@testable import PhosphorCore

@Suite struct DevStatsTests {
    @Test func benchmarkBandsMatchPublishedEdges() {
        #expect(PRBenchmark.place(prsPerWeek: 17).label == "Elite · Top 10%")
        #expect(PRBenchmark.place(prsPerWeek: 17).topPercent == nil)      // never extrapolated past the report
        #expect(PRBenchmark.place(prsPerWeek: 2.0).topPercent == 10)
        #expect(PRBenchmark.place(prsPerWeek: 1.2) == .init(tier: "Good", topPercent: 30, label: "Good · est. Top 30%"))
        #expect(PRBenchmark.place(prsPerWeek: 0.93).tier == "Fair")
        #expect(PRBenchmark.place(prsPerWeek: 0.93).topPercent == 45)
        #expect(PRBenchmark.place(prsPerWeek: 0).topPercent == 100)
    }

    @Test func roiAndCurrency() throws {
        let usd = try #require(ROI.usd(["KRW": 1_344_500, "USD": 200], unitsPerUSD: ["KRW": 1344.5]))
        #expect(abs(usd - 1200) < 1e-6)
        #expect(ROI.usd(["EUR": 10], unitsPerUSD: [:]) == nil)
        #expect(ROI.ratio(apiValueUSD: 6000, spendUSD: 1200) == 5)
        #expect(ROI.ratio(apiValueUSD: 10, spendUSD: 0) == nil)
        #expect(ROI.perPR(730, merged: 73) == 10)
        #expect(ROI.perPR(5, merged: 0) == nil)
    }

    @Test func queriesAndCounts() {
        let now = ISO8601DateFormatter().date(from: "2026-11-27T02:00:00+09:00")!
        let q = GitHubQueries.all(login: "octo", now: now, tz: TimeZone(identifier: "Asia/Seoul")!)
        #expect(q.count == 15)
        #expect(q.first { $0.key == "merged30" }?.q == "author:octo type:pr is:merged merged:>=2026-10-27")
        #expect(q.first { $0.key == "mergedToday" }?.q.hasSuffix("merged:>=2026-11-26T15:00:00Z") == true)
        #expect(q.first { $0.key == "commitsW1" }?.endpoint == "search/commits")
        let c = GitHubQueries.counts(login: "octo", results: ["merged7": 10, "merged30": 73, "mergedW1": 20, "mergedW2": 25, "mergedW3": 15])
        #expect(c.mergedWeeks == [10, 20, 25, 15])
        let t = DevCounts.trend(c.mergedWeeks)
        #expect(t?.previousAverage == 20 && t?.change == -0.5)
        #expect(abs(c.prsPerWeek - 73 / (30.0 / 7)) < 1e-9)
    }
}
