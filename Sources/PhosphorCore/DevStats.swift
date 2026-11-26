import Foundation

/// GitHub and local git activity for the signed-in developer, counted by GitHub's own search.
public struct DevCounts: Codable, Sendable, Equatable {
    public var login: String
    public var mergedToday = 0, merged7 = 0, merged30 = 0
    public var openedToday = 0, opened7 = 0, opened30 = 0
    public var commitsToday = 0, commits7 = 0, commits30 = 0
    /// Merged PRs and commits per week, newest first: [last 7 days, 8–14 days ago, 15–21, 22–28].
    public var mergedWeeks: [Int] = []
    public var commitWeeks: [Int] = []
    /// Commits in local repositories (by your git email), counted separately from GitHub.
    public var localCommits7: Int?
    public var localCommits30: Int?
    public var localRepos: Int?
    public var fetchedAt: Date

    public init(login: String, fetchedAt: Date = Date()) { self.login = login; self.fetchedAt = fetchedAt }

    /// Merged PRs per week over the last 30 days.
    public var prsPerWeek: Double { Double(merged30) / (30.0 / 7.0) }
    public var commitsPerWeek: Double { Double(commits30) / (30.0 / 7.0) }

    /// This week against the average of the three weeks before (nil until there's history).
    public static func trend(_ weeks: [Int]) -> (current: Int, previousAverage: Double, change: Double?)? {
        guard let cur = weeks.first, weeks.count >= 2 else { return nil }
        let prev = weeks.dropFirst()
        let avg = Double(prev.reduce(0, +)) / Double(prev.count)
        return (cur, avg, avg > 0 ? (Double(cur) - avg) / avg : nil)
    }
}

/// Search queries for GitHub's REST search API (dates in UTC, as GitHub interprets them).
public enum GitHubQueries {
    public struct Query: Sendable, Hashable {
        public var key: String
        public var endpoint: String     // "search/issues" or "search/commits"
        public var q: String
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    public static func all(login: String, now: Date = Date(), tz: TimeZone = .current) -> [Query] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let today = cal.startOfDay(for: now)
        func ago(_ n: Int) -> Date { now.addingTimeInterval(-Double(n) * 86_400) }
        let iso = ISO8601DateFormatter()
        let t = iso.string(from: today)          // local midnight, as a UTC timestamp
        func range(_ a: Int, _ b: Int) -> String { "\(day(ago(a)))..\(day(ago(b)))" }
        let pr = "author:\(login) type:pr", cm = "author:\(login)"
        var q: [Query] = [
            .init(key: "mergedToday", endpoint: "search/issues", q: "\(pr) is:merged merged:>=\(t)"),
            .init(key: "merged7", endpoint: "search/issues", q: "\(pr) is:merged merged:>=\(day(ago(7)))"),
            .init(key: "merged30", endpoint: "search/issues", q: "\(pr) is:merged merged:>=\(day(ago(30)))"),
            .init(key: "openedToday", endpoint: "search/issues", q: "\(pr) created:>=\(t)"),
            .init(key: "opened7", endpoint: "search/issues", q: "\(pr) created:>=\(day(ago(7)))"),
            .init(key: "opened30", endpoint: "search/issues", q: "\(pr) created:>=\(day(ago(30)))"),
            .init(key: "commitsToday", endpoint: "search/commits", q: "\(cm) author-date:>=\(t)"),
            .init(key: "commits7", endpoint: "search/commits", q: "\(cm) author-date:>=\(day(ago(7)))"),
            .init(key: "commits30", endpoint: "search/commits", q: "\(cm) author-date:>=\(day(ago(30)))"),
        ]
        for w in 1...3 {
            q.append(.init(key: "mergedW\(w)", endpoint: "search/issues", q: "\(pr) is:merged merged:\(range(7 * w + 7, 7 * w + 1))"))
            q.append(.init(key: "commitsW\(w)", endpoint: "search/commits", q: "\(cm) author-date:\(range(7 * w + 7, 7 * w + 1))"))
        }
        return q
    }

    public static func counts(login: String, results: [String: Int], at: Date = Date()) -> DevCounts {
        var c = DevCounts(login: login, fetchedAt: at)
        c.mergedToday = results["mergedToday"] ?? 0; c.merged7 = results["merged7"] ?? 0; c.merged30 = results["merged30"] ?? 0
        c.openedToday = results["openedToday"] ?? 0; c.opened7 = results["opened7"] ?? 0; c.opened30 = results["opened30"] ?? 0
        c.commitsToday = results["commitsToday"] ?? 0; c.commits7 = results["commits7"] ?? 0; c.commits30 = results["commits30"] ?? 0
        c.mergedWeeks = [c.merged7] + (1...3).map { results["mergedW\($0)"] ?? 0 }
        c.commitWeeks = [c.commits7] + (1...3).map { results["commitsW\($0)"] ?? 0 }
        return c
    }
}

/// Where merged-PRs-per-week sits against a published benchmark. No live leaderboard exists, and
/// none is invented: this places you within LinearB's published tiers, nothing finer.
public enum PRBenchmark {
    public static let source = "LinearB 2026 Software Engineering Benchmarks Report (8.1M PRs, 4,800+ teams, 42 countries): "
        + "Merge Frequency per dev/week — Elite > 2.0 (top 10%), Good 1.2–2.0 (top 30%), Fair 0.66–1.2 (top 60%), "
        + "Needs focus < 0.66 (bottom 40%). Team-level rate; an individual estimate is approximate."
    public static let url = "https://linearb.io/resources/engineering-benchmarks"

    public struct Placement: Sendable, Equatable {
        public var tier: String
        /// Estimated "top X %" (interpolated inside a band); nil above Elite, where the report gives no finer split.
        public var topPercent: Int?
        public var label: String
    }

    /// Band edges from the report: (PRs/week, top %).
    static let anchors: [(Double, Double)] = [(0, 100), (0.66, 60), (1.2, 30), (2.0, 10)]

    public static func place(prsPerWeek r: Double) -> Placement {
        if r > 2.0 { return Placement(tier: "Elite", topPercent: nil, label: "Elite · Top 10%") }
        var top = 100.0
        for (a, b) in zip(anchors, anchors.dropFirst()) where r >= a.0 && r <= b.0 {
            top = a.1 + (b.1 - a.1) * (r - a.0) / (b.0 - a.0)
        }
        let tier = r >= 1.2 ? "Good" : (r >= 0.66 ? "Fair" : "Needs focus")
        let pct = Int(top.rounded())
        return Placement(tier: tier, topPercent: pct, label: "\(tier) · est. Top \(pct)%")
    }
}

/// Subscription return: what your logged use would cost on the API, against what the plans cost.
public enum ROI {
    /// Converts {"KRW": 290000, "USD": 20} to USD with rates given as units per 1 USD; nil if a rate is missing.
    public static func usd(_ amounts: [String: Double], unitsPerUSD: [String: Double]) -> Double? {
        var total = 0.0
        for (cur, v) in amounts {
            if cur.uppercased() == "USD" { total += v; continue }
            guard let r = unitsPerUSD[cur.uppercased()], r > 0 else { return nil }
            total += v / r
        }
        return total
    }

    public static func ratio(apiValueUSD: Double, spendUSD: Double) -> Double? {
        spendUSD > 0 && apiValueUSD > 0 ? apiValueUSD / spendUSD : nil
    }

    public static func perPR(_ value: Double, merged: Int) -> Double? { merged > 0 ? value / Double(merged) : nil }
}
