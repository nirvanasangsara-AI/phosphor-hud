import Testing
import Foundation
@testable import PhosphorCore

@Suite struct DevStatsTests {
    @Test func benchmarkBandsMatchPublishedEdges() {
        let elite3 = PRBenchmark.place(prsPerWeek: 3)
        let elite18 = PRBenchmark.place(prsPerWeek: 18)
        #expect(elite3.label != elite18.label)
        #expect(elite3.label == "Elite band · 3.0 PR/wk (benchmark >2.0)")
        #expect(elite18.label == "Elite band · 18.0 PR/wk (benchmark >2.0)")
        #expect(elite18.topPercent == nil)      // never extrapolated past the report
        #expect(!elite18.label.contains("Top 10%"))
        #expect(!elite18.label.contains("Elite · Top"))
        #expect(PRBenchmark.place(prsPerWeek: 2.0).tier == "Good")
        #expect(PRBenchmark.place(prsPerWeek: 2.0).topPercent == 10)
        #expect(PRBenchmark.place(prsPerWeek: 2.0).label == "Good band · 2.0 PR/wk (benchmark 1.2-2.0)")
        #expect(PRBenchmark.place(prsPerWeek: 1.2) == .init(tier: "Good", topPercent: 30, label: "Good band · 1.2 PR/wk (benchmark 1.2-2.0)"))
        #expect(PRBenchmark.place(prsPerWeek: 0.66).tier == "Fair")
        #expect(PRBenchmark.place(prsPerWeek: 0.66).label.contains("benchmark 0.66-1.2"))
        #expect(PRBenchmark.place(prsPerWeek: 0.65).tier == "Needs focus")
        #expect(PRBenchmark.place(prsPerWeek: 0.93).tier == "Fair")
        #expect(PRBenchmark.place(prsPerWeek: 0.93).topPercent == 45)
        #expect(PRBenchmark.place(prsPerWeek: 0).topPercent == 100)
        #expect(PRBenchmark.source.contains("team average"))
        #expect(PRBenchmark.source.contains("not a personal rank"))
        #expect(!PRBenchmark.source.contains("Top 10%"))
    }

    @Test func automaticRefreshRespectsTheStripAndAnInFlightAccountChange() {
        let now = Date()
        #expect(!DevStatsSchedule.shouldStart(enabled: false, busy: false, force: false, fetchedAt: nil, now: now))
        #expect(DevStatsSchedule.shouldStart(enabled: false, busy: true, force: true, fetchedAt: now, now: now))
        #expect(DevStatsSchedule.shouldStart(enabled: true, busy: false, force: false, fetchedAt: nil, now: now))
        #expect(!DevStatsSchedule.shouldStart(enabled: true, busy: true, force: false, fetchedAt: nil, now: now))
        #expect(!DevStatsSchedule.shouldStart(enabled: true, busy: false, force: false, fetchedAt: now, now: now))
        #expect(DevStatsSchedule.shouldStart(enabled: true, busy: false, force: false, fetchedAt: now.addingTimeInterval(-300), now: now))

        var generation = RefreshGeneration()
        let first = generation.issue()
        let second = generation.issue()
        #expect(generation.isCurrent(second))
        #expect(!generation.isCurrent(first))
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
        #expect(q.count == 16)
        #expect(q.first { $0.key == "merged30" }?.q == "author:octo type:pr is:merged merged:>=2026-10-27")
        #expect(q.first { $0.key == "merged30Prev" }?.q == "author:octo type:pr is:merged merged:\(GitHubQueries.day(now.addingTimeInterval(-60 * 86_400)))..\(GitHubQueries.day(now.addingTimeInterval(-31 * 86_400)))")
        #expect(q.first { $0.key == "mergedToday" }?.q.hasSuffix("merged:>=2026-11-26T15:00:00Z") == true)
        #expect(q.first { $0.key == "commitsW1" }?.endpoint == "search/commits")
        let c = GitHubQueries.counts(login: "octo", results: ["merged7": 10, "merged30": 73, "mergedW1": 20, "mergedW2": 25, "mergedW3": 15, "merged30Prev": 40])
        #expect(c.mergedWeeks == [10, 20, 25, 15])
        #expect(c.merged30Prev == 40)
        #expect(c.previous30Change()?.delta == 33)
        let wow = c.weekOverWeek()
        #expect(wow?.current == 10 && wow?.previous == 20 && wow?.delta == -10 && wow?.percent == -0.5)
        #expect(DevCounts.changeText(delta: -10, percent: -0.5) == "▼ 10 · 50%")
        #expect(DevCounts.changeText(delta: 4, percent: nil) == "▲ 4")
        let t = DevCounts.trend(c.mergedWeeks)
        #expect(t?.previousAverage == 20 && t?.change == -0.5)
        #expect(abs(c.prsPerWeek - 73 / (30.0 / 7)) < 1e-9)
        #expect(c.prSparkline() == [15, 25, 20, 10])
    }

    @Test func oldDevStatsFileDecodesWithoutNewFields() throws {
        let json = """
        {"login":"octo","mergedToday":1,"merged7":4,"merged30":10,"openedToday":0,"opened7":0,"opened30":0,"commitsToday":0,"commits7":0,"commits30":0,"mergedWeeks":[4,3],"commitWeeks":[],"fetchedAt":"2026-11-01T00:00:00Z"}
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let c = try dec.decode(DevCounts.self, from: Data(json.utf8))
        #expect(c.merged30Prev == nil && c.mergedDaily == nil && c.localRoots == nil)
        #expect(c.weekOverWeek()?.delta == 1)
        #expect(c.prSparkline() == [3, 4])
    }

    @Test func dailySparklinePrefersCompleteGraphQLSample() throws {
        let json = """
        {"data":{"search":{"issueCount":2,"nodes":[{"mergedAt":"2026-11-27T01:00:00Z"},{"mergedAt":"2026-11-26T03:00:00Z"},null]}}}
        """
        let parsed = try #require(MergedSeries.parse(graphqlJSON: Data(json.utf8)))
        #expect(parsed.total == 2 && parsed.dates.count == 2)
        let now = ISO8601DateFormatter().date(from: "2026-11-27T12:00:00Z")!
        let tz = TimeZone(identifier: "UTC")!
        let days = try #require(MergedSeries.dailyCounts(dates: parsed.dates, total: parsed.total, now: now, timeZone: tz))
        #expect(days.count == 14)
        #expect(days[13] == 1 && days[12] == 1)
        #expect(MergedSeries.dailyCounts(dates: parsed.dates, total: 5, now: now, timeZone: tz) == nil)
    }

    @Test func authStatusListsLoginsAndIgnoresTokens() {
        let sample = """
        github.com
          ✓ Logged in to github.com account octocat (keyring)
          - Active account: true
          - Token: gho_secretvalue
          ✓ Logged in to github.com account Other-User (keyring)
        """
        #expect(GHAuthAccounts.logins(from: sample) == ["octocat", "Other-User"])
        #expect(!GHAuthAccounts.logins(from: sample).joined().contains("gho_"))
        #expect(GHLogin.normalize("  @Octo ") == "Octo")
        #expect(GHLogin.normalize("") == nil)
        #expect(GHLogin.normalize("bad login") == nil)
        #expect(GHLogin.normalize("a") == "a")
    }
}
