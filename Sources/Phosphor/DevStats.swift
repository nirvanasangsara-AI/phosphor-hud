import Foundation
import PhosphorCore

/// GitHub PRs and commits for the account the GitHub CLI is signed in to, via `gh api` (gh's own
/// login: Phosphor never sees the token), plus commits in local repositories. Refreshed every 30 min.
@MainActor
final class DevStatsService: ObservableObject {
    @Published private(set) var counts: DevCounts?
    @Published private(set) var problem: String?
    @Published private(set) var busy = false
    /// Units of each currency per 1 USD, from open.er-api.com (ExchangeRate-API), cached for a day.
    @Published private(set) var fx: [String: Double] = [:]
    @Published private(set) var fxDate: String?

    static var cacheFile: URL { Paths.support.appendingPathComponent("dev-stats.json") }
    static var fxFile: URL { Paths.caches.appendingPathComponent("fx-usd.json") }
    static let fxURL = URL(string: "https://open.er-api.com/v6/latest/USD")!

    private let demo: Bool

    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            // Sample numbers for screenshots (`--demo`): a made-up account, never a real one.
            var c = DevCounts(login: "octocat")
            c.mergedToday = 2; c.merged7 = 18; c.merged30 = 71
            c.openedToday = 3; c.opened7 = 21; c.opened30 = 77
            c.commitsToday = 9; c.commits7 = 142; c.commits30 = 583
            c.mergedWeeks = [18, 15, 21, 14]; c.commitWeeks = [142, 131, 170, 119]
            c.localCommits7 = 96; c.localCommits30 = 402; c.localRepos = 6
            counts = c
            return
        }
        if let d = try? Data(contentsOf: Self.cacheFile) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            counts = try? dec.decode(DevCounts.self, from: d)
        }
        loadFX()
    }

    func refreshIfDue(force: Bool = false) {
        guard !demo, !busy, force || (counts.map { Date().timeIntervalSince($0.fetchedAt) > 1800 } ?? true) else { return }
        busy = true
        Task {
            defer { busy = false }
            await updateFXIfStale()
            guard let gh = Shell.which("gh") else { problem = "GitHub CLI (gh) not installed"; return }
            guard let login = try? await Shell.run(gh, ["api", "user", "--jq", ".login"], timeout: 15), !login.isEmpty else {
                problem = "gh isn't signed in (gh auth login)"; return
            }
            var results: [String: Int] = [:]
            for q in GitHubQueries.all(login: login) {
                // Search allows 30 requests a minute; 15 queries a refresh stays well inside it.
                if let out = try? await Shell.run(gh, ["api", "-X", "GET", q.endpoint, "-f", "q=\(q.q)", "--jq", ".total_count"], timeout: 20),
                   let n = Int(out) { results[q.key] = n }
            }
            guard results["merged30"] != nil else { problem = "GitHub search didn't answer"; return }
            var c = GitHubQueries.counts(login: login, results: results)
            let local = await Self.localCommits()
            c.localCommits7 = local.d7; c.localCommits30 = local.d30; c.localRepos = local.repos
            counts = c
            problem = nil
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            try? enc.encode(c).write(to: Self.cacheFile, options: .atomic)
        }
    }

    /// Commits by your git email in repositories directly under ~/Projects, ~/Developer, ~/code, ~/src (all branches, deduplicated).
    static func localCommits() async -> (d7: Int, d30: Int, repos: Int) {
        guard let git = Shell.which("git", extra: ["/usr/bin/git"]),
              let email = try? await Shell.run(git, ["config", "--global", "user.email"], timeout: 5), !email.isEmpty else { return (0, 0, 0) }
        let fm = FileManager.default
        var repos: [URL] = []
        for root in ["Projects", "Developer", "code", "src"] {
            let dir = Paths.home.appendingPathComponent(root)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let r = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: r.appendingPathComponent(".git").path) { repos.append(r) }
            }
        }
        var d7 = 0, d30 = 0
        for r in repos {
            for (days, isWeek) in [(30, false), (7, true)] {
                let out = (try? await Shell.run(git, ["-C", r.path, "log", "--all", "--since=\(days) days ago",
                                                     "--author=\(email)", "--format=%H"], timeout: 15)) ?? ""
                let n = Set(out.split(separator: "\n")).count
                if isWeek { d7 += n } else { d30 += n }
            }
        }
        return (d7, d30, repos.count)
    }

    // MARK: Exchange rates (public, no key)

    private func loadFX() {
        guard let d = try? Data(contentsOf: Self.fxFile),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let rates = o["rates"] as? [String: Any] else { return }
        fx = rates.compactMapValues { num($0) }
        fxDate = o["time_last_update_utc"] as? String
    }

    private func updateFXIfStale() async {
        let at = (try? FileManager.default.attributesOfItem(atPath: Self.fxFile.path))?[.modificationDate] as? Date
        if let at, Date().timeIntervalSince(at) < 86_400, !fx.isEmpty { return }
        guard let (data, resp) = try? await URLSession.shared.data(from: Self.fxURL),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        try? FileManager.default.createDirectory(at: Paths.caches, withIntermediateDirectories: true)
        try? data.write(to: Self.fxFile, options: .atomic)
        loadFX()
    }
}

/// What the efficiency strip shows, worked out from GitHub counts, log totals and subscription prices.
struct Efficiency {
    var counts: DevCounts
    var placement: PRBenchmark.Placement
    /// The period the log numbers cover: 30 days once the ledger reaches back that far, else 7.
    var days: Int
    var apiValue: Double              // USD, API-equivalent from local logs over `days`
    var tokens: Int
    var merged: Int                   // merged PRs over `days`
    var spendUSD: Double?             // monthly subscriptions read, in USD
    var spendText: String             // "₩290,000 + $20"
    var roi: Double?
    var costPerPR: Double?            // USD
    var tokensPerPR: Double?
    var valuePerPR: Double?           // USD
    var krwPerUSD: Double?

    @MainActor
    init?(store: UsageStore, dev: DevStatsService) {
        guard let c = dev.counts else { return nil }
        counts = c
        placement = PRBenchmark.place(prsPerWeek: c.prsPerWeek)
        let covered = store.logs.coverageStart.map { Date().timeIntervalSince($0) / 86_400 } ?? 0
        days = covered >= 29.5 ? 30 : 7
        let t = store.logs.total(days: days)
        apiValue = t.cost
        tokens = t.tokens
        merged = days == 30 ? c.merged30 : c.merged7
        let sums = store.monthlySums
        spendText = store.monthlyTotal?.text ?? "–"
        spendUSD = sums.isEmpty ? nil : ROI.usd(sums, unitsPerUSD: dev.fx)
        // Same period on both sides: the subscription prorated to the days the logs cover.
        roi = spendUSD.flatMap { ROI.ratio(apiValueUSD: apiValue, spendUSD: $0 * Double(days) / 30) }
        costPerPR = spendUSD.flatMap { ROI.perPR($0, merged: c.merged30) }
        tokensPerPR = ROI.perPR(Double(tokens), merged: merged)
        valuePerPR = ROI.perPR(apiValue, merged: merged)
        krwPerUSD = dev.fx["KRW"]
    }

    /// Money in won when the subscriptions are mostly billed in won, else dollars.
    @MainActor
    func money(_ usd: Double, store: UsageStore) -> String {
        if let k = krwPerUSD, (store.monthlySums["KRW"] ?? 0) > 0 { return Fmt.money((usd * k).rounded(), "KRW") }
        return Fmt.amount(usd, "usd")
    }
}
