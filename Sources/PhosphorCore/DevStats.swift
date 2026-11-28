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
    /// Folders actually searched for local repositories (display paths). Optional so older dev-stats.json still decodes.
    public var localRoots: [String]?
    /// Merged PRs in the previous 30 days (days 31–60). Nil until that query has answered.
    public var merged30Prev: Int?
    /// Merged PRs per day over the last 14 days, oldest first. Nil when the daily sample was incomplete.
    public var mergedDaily: [Int]?
    public var fetchedAt: Date

    public init(login: String, fetchedAt: Date = Date()) { self.login = login; self.fetchedAt = fetchedAt }

    /// Merged PRs per week over the last 30 days.
    public var prsPerWeek: Double { Double(merged30) / (30.0 / 7.0) }
    public var commitsPerWeek: Double { Double(commits30) / (30.0 / 7.0) }

    public struct WeekChange: Sendable, Equatable {
        public var current: Int
        public var previous: Int
        public var delta: Int
        public var percent: Double?
    }

    /// This week (`mergedWeeks[0]`) against the week before it (`mergedWeeks[1]`).
    public func weekOverWeek() -> WeekChange? {
        guard mergedWeeks.count >= 2 else { return nil }
        let current = mergedWeeks[0], previous = mergedWeeks[1]
        let percent = previous > 0 ? Double(current - previous) / Double(previous) : nil
        return WeekChange(current: current, previous: previous, delta: current - previous, percent: percent)
    }

    /// The last 30 days against the 30 days before that.
    public func previous30Change() -> WeekChange? {
        guard let previous = merged30Prev else { return nil }
        let percent = previous > 0 ? Double(merged30 - previous) / Double(previous) : nil
        return WeekChange(current: merged30, previous: previous, delta: merged30 - previous, percent: percent)
    }

    /// Daily points when the GraphQL sample was complete, otherwise the four weekly buckets (oldest first).
    public func prSparkline() -> [Int] {
        if let daily = mergedDaily, daily.count >= 2 { return daily }
        return Array(mergedWeeks.prefix(4).reversed())
    }

    /// "▲ 4 · 22%" or "▼ 3". Percent is omitted when the previous period was zero.
    public static func changeText(delta: Int, percent: Double?) -> String {
        let arrow = delta < 0 ? "▼" : "▲"
        if let percent {
            return "\(arrow) \(abs(delta)) · \(Int((abs(percent) * 100).rounded()))%"
        }
        return "\(arrow) \(abs(delta))"
    }

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
            .init(key: "merged30Prev", endpoint: "search/issues", q: "\(pr) is:merged merged:\(range(60, 31))"),
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
        if let n = results["merged30Prev"] { c.merged30Prev = n }
        return c
    }

    /// Search string for one GraphQL query of merged PRs over the last 14 days.
    public static func mergedDailySearch(login: String, now: Date = Date()) -> String {
        "author:\(login) type:pr is:merged merged:>=\(day(now.addingTimeInterval(-13 * 86_400)))"
    }

    public static let mergedDailyGraphQL = "query($search:String!){search(query:$search,type:ISSUE,first:100){issueCount nodes{... on PullRequest{mergedAt}}}}"
}

/// `gh auth status` logins. The token lines in that output are ignored; token files are never read.
public enum GHAuthAccounts {
    public static func logins(from status: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"account\s+(\S+)"#) else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        for line in status.split(whereSeparator: \.isNewline) {
            let s = String(line)
            let range = NSRange(s.startIndex..., in: s)
            guard let match = re.firstMatch(in: s, range: range), match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: s) else { continue }
            let login = String(s[r]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            guard GHLogin.normalize(login) != nil, seen.insert(login.lowercased()).inserted else { continue }
            out.append(login)
        }
        return out
    }
}

/// A GitHub login, or nil when the text is blank or not a login. Blank means "the current gh login".
public enum GHLogin {
    public static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("@") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 39 else { return nil }
        guard s.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$"#, options: .regularExpression) != nil else { return nil }
        return s
    }
}

/// Daily merged-PR counts from one `gh api graphql` payload. An incomplete page is nil so the UI can use weekly points.
public enum MergedSeries {
    public static func parse(graphqlJSON data: Data) -> (dates: [String], total: Int)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let search = dataObj["search"] as? [String: Any] else { return nil }
        let total = (search["issueCount"] as? NSNumber)?.intValue ?? 0
        let nodes = search["nodes"] as? [Any] ?? []
        var dates: [String] = []
        for node in nodes {
            guard let row = node as? [String: Any], let at = row["mergedAt"] as? String, !at.isEmpty else { continue }
            dates.append(at)
        }
        return (dates, total)
    }

    public static func dailyCounts(dates: [String], total: Int, now: Date, timeZone: TimeZone, days: Int = 14) -> [Int]? {
        guard dates.count >= total else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let end = cal.startOfDay(for: now)
        guard let start = cal.date(byAdding: .day, value: -(days - 1), to: end) else { return nil }
        var counts = Array(repeating: 0, count: days)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        for s in dates {
            guard let d = fractional.date(from: s) ?? plain.date(from: s) else { continue }
            let day = cal.startOfDay(for: d)
            let idx = cal.dateComponents([.day], from: start, to: day).day ?? -1
            if (0..<days).contains(idx) { counts[idx] += 1 }
        }
        return counts
    }
}

/// Where merged-PRs-per-week sits against a published benchmark. No live leaderboard exists, and
/// none is invented: the label always carries the real rate, and the tooltip cites LinearB's team averages.
public enum PRBenchmark {
    public static let source = "LinearB 2026 Software Engineering Benchmarks Report (8.1M PRs, 4,800+ teams, 42 countries). "
        + "Merge frequency is a team average per developer per week: Elite > 2.0, Good 1.2-2.0, Fair 0.66-1.2, "
        + "Needs focus < 0.66. This compares your rate with those published team averages. It is not a personal rank."
    public static let url = "https://linearb.io/resources/engineering-benchmarks"

    public struct Placement: Sendable, Equatable {
        public var tier: String
        /// Estimated "top X %" inside a published band (kept for tests). Nil above Elite, where the report gives no finer split.
        /// The on-screen label does not use this as a rank.
        public var topPercent: Int?
        public var label: String
    }

    /// Band edges from the report: (PRs/week, top %).
    static let anchors: [(Double, Double)] = [(0, 100), (0.66, 60), (1.2, 30), (2.0, 10)]

    public static func place(prsPerWeek r: Double) -> Placement {
        let rate = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), arguments: [r])
        if r > 2.0 {
            return Placement(tier: "Elite", topPercent: nil, label: "Elite band · \(rate) PR/wk (benchmark >2.0)")
        }
        var top = 100.0
        for (a, b) in zip(anchors, anchors.dropFirst()) where r >= a.0 && r <= b.0 {
            top = a.1 + (b.1 - a.1) * (r - a.0) / (b.0 - a.0)
        }
        let tier: String
        let band: String
        if r >= 1.2 { tier = "Good"; band = "1.2-2.0" }
        else if r >= 0.66 { tier = "Fair"; band = "0.66-1.2" }
        else { tier = "Needs focus"; band = "<0.66" }
        return Placement(tier: tier, topPercent: Int(top.rounded()),
                         label: "\(tier) band · \(rate) PR/wk (benchmark \(band))")
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
