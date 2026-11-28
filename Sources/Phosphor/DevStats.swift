import Foundation
import PhosphorCore

/// GitHub PRs and commits via `gh api` (gh's own login: Phosphor never sees or reads a token file),
/// plus commits in local repositories. Refreshed every 5 minutes.
@MainActor
final class DevStatsService: ObservableObject {
    @Published private(set) var counts: DevCounts?
    @Published private(set) var problem: String?
    @Published private(set) var busy = false
    /// Units of each currency per 1 USD, from open.er-api.com (ExchangeRate-API), cached for a day.
    @Published private(set) var fx: [String: Double] = [:]
    @Published private(set) var fxDate: String?
    /// Logins from `gh auth status`. Tokens in that output are discarded.
    @Published private(set) var knownAccounts: [String] = []
    /// Public-PR percentile table. Nil hides the rank line (a configured URL failed, or the count is outside the table).
    @Published var rankTable: PRRankTable?

    static var cacheFile: URL { Paths.support.appendingPathComponent("dev-stats.json") }
    static var fxFile: URL { Paths.caches.appendingPathComponent("fx-usd.json") }
    static let fxURL = URL(string: "https://open.er-api.com/v6/latest/USD")!

    private let demo: Bool
    private var timer: Timer?
    /// Bumped when a newer refresh starts, so the older task cannot publish or save.
    private var generation = RefreshGeneration()

    init(demo: Bool = false) {
        self.demo = demo
        if demo {
            // Sample numbers for screenshots (`--demo`): a made-up account, never a real one.
            var c = DevCounts(login: "octocat")
            c.mergedToday = 2; c.merged7 = 18; c.merged30 = 71
            c.openedToday = 3; c.opened7 = 21; c.opened30 = 77
            c.commitsToday = 9; c.commits7 = 142; c.commits30 = 583
            c.mergedWeeks = [18, 15, 21, 14]; c.commitWeeks = [142, 131, 170, 119]
            c.merged30Prev = 60
            c.publicOpened7 = 11
            c.publicOpened30 = 40
            c.mergedDaily = [1, 0, 2, 1, 3, 2, 1, 0, 2, 1, 2, 1, 0, 2]
            c.localCommits7 = 96; c.localCommits30 = 402; c.localRepos = 6
            c.localRoots = ["~/Projects", "~/Developer", "~/code", "~/src", "~/workspace"]
            counts = c
            rankTable = .bundled
            return
        }
        if let d = try? Data(contentsOf: Self.cacheFile) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            counts = try? dec.decode(DevCounts.self, from: d)
        }
        loadFX()
        rankTable = Prefs.shared.prRankURL.isEmpty ? .bundled : nil
        timer = Timer.scheduledTimer(withTimeInterval: DevStatsSchedule.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfDue() }
        }
    }

    /// Empty text selects the account `gh` is signed in as. Anything else must be a GitHub login.
    func useAccount(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        // Drop any query already running for the previous login before it can save those counts back.
        _ = generation.issue()
        counts = nil
        busy = false
        try? FileManager.default.removeItem(at: Self.cacheFile)
        if trimmed.isEmpty {
            Prefs.shared.devAccount = ""
            problem = nil
            refreshIfDue(force: true)
            return
        }
        guard let login = GHLogin.normalize(trimmed) else {
            Prefs.shared.devAccount = trimmed
            problem = "unknown-account:\(trimmed)"
            return
        }
        Prefs.shared.devAccount = login
        problem = nil
        refreshIfDue(force: true)
    }

    func useRepoRoots(_ paths: [String]) {
        Prefs.shared.localRepoRoots = paths
        Task { await rescanLocal() }
    }

    func refreshIfDue(force: Bool = false) {
        guard !demo else { return }
        Task { await self.loadRank() }
        guard DevStatsSchedule.shouldStart(enabled: Prefs.shared.showDevStats, busy: busy, force: force,
                                           fetchedAt: counts?.fetchedAt) else { return }
        let ticket = generation.issue()
        busy = true
        Task {
            defer { if self.generation.isCurrent(ticket) { self.busy = false } }
            await updateFXIfStale()
            guard generation.isCurrent(ticket) else { return }
            guard let gh = Shell.which("gh") else {
                problem = "GitHub CLI (gh) not installed"
                return
            }
            if let status = try? await Shell.run(gh, ["auth", "status"], timeout: 15, tolerateFailure: true) {
                guard generation.isCurrent(ticket) else { return }
                knownAccounts = GHAuthAccounts.logins(from: status)
            }
            guard generation.isCurrent(ticket) else { return }
            let wanted = Prefs.shared.devAccount.trimmingCharacters(in: .whitespacesAndNewlines)
            let login: String
            if wanted.isEmpty {
                guard let current = try? await Shell.run(gh, ["api", "user", "--jq", ".login"], timeout: 15), !current.isEmpty else {
                    guard generation.isCurrent(ticket) else { return }
                    problem = "gh isn't signed in (gh auth login)"
                    return
                }
                login = current
            } else if let normalized = GHLogin.normalize(wanted),
                      let found = try? await Shell.run(gh, ["api", "users/\(normalized)", "--jq", ".login"], timeout: 15),
                      !found.isEmpty {
                login = found
            } else {
                guard generation.isCurrent(ticket) else { return }
                counts = nil
                problem = "unknown-account:\(wanted)"
                return
            }
            guard generation.isCurrent(ticket) else { return }
            var results: [String: Int] = [:]
            for q in GitHubQueries.all(login: login) {
                guard generation.isCurrent(ticket) else { return }
                // Search allows 30 requests a minute. These queries every 5 minutes stay inside that.
                if let out = try? await Shell.run(gh, ["api", "-X", "GET", q.endpoint, "-f", "q=\(q.q)", "--jq", ".total_count"], timeout: 20),
                   let n = Int(out) { results[q.key] = n }
            }
            guard generation.isCurrent(ticket) else { return }
            guard results["merged30"] != nil else {
                problem = "GitHub search didn't answer"
                return
            }
            var c = GitHubQueries.counts(login: login, results: results)
            if let raw = try? await Shell.run(gh, ["api", "graphql", "-f", "query=\(GitHubQueries.mergedDailyGraphQL)",
                                                   "-f", "search=\(GitHubQueries.mergedDailySearch(login: login))"], timeout: 20),
               let parsed = MergedSeries.parse(graphqlJSON: Data(raw.utf8)),
               let daily = MergedSeries.dailyCounts(dates: parsed.dates, total: parsed.total, now: Date(), timeZone: .current) {
                c.mergedDaily = daily
            }
            guard generation.isCurrent(ticket) else { return }
            let local = await Self.localCommits()
            guard generation.isCurrent(ticket) else { return }
            c.localCommits7 = local.d7; c.localCommits30 = local.d30; c.localRepos = local.repos; c.localRoots = local.roots
            counts = c
            problem = nil
            save(c)
        }
    }

    private func rescanLocal() async {
        let local = await Self.localCommits()
        guard var c = counts else { refreshIfDue(force: true); return }
        c.localCommits7 = local.d7; c.localCommits30 = local.d30; c.localRepos = local.repos; c.localRoots = local.roots
        counts = c
        save(c)
    }

    private func save(_ c: DevCounts) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try? enc.encode(c).write(to: Self.cacheFile, options: .atomic)
    }

    /// Empty URL uses the dated snapshot. A configured URL that fails hides the rank line.
    func loadRank() async {
        let raw = Prefs.shared.prRankURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw) else {
            rankTable = .bundled
            return
        }
        let cache = Self.rankCache
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cache.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 86_400,
           let data = try? Data(contentsOf: cache),
           let table = PRRankTable.decode(data) {
            rankTable = table
            return
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let table = PRRankTable.decode(data) else {
            rankTable = nil
            return
        }
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try? data.write(to: cache, options: .atomic)
        rankTable = table
    }

    private static var rankCache: URL { Paths.support.appendingPathComponent("pr-rank.json") }

    /// Commits by your git email. Roots default to Projects, Developer, code, src, and workspace, two levels deep, 30 newest repos.
    static func localCommits() async -> (d7: Int, d30: Int, repos: Int, roots: [String]) {
        let roots = LocalRepoScan.roots(home: Paths.home, custom: Prefs.shared.localRepoRoots)
        let shown = roots.map { LocalRepoScan.displayPath($0, home: Paths.home) }
        guard let git = Shell.which("git", extra: ["/usr/bin/git"]),
              let email = try? await Shell.run(git, ["config", "--global", "user.email"], timeout: 5), !email.isEmpty else {
            return (0, 0, 0, shown)
        }
        let repos = LocalRepoScan.discover(roots: roots)
        var d7 = 0, d30 = 0
        for r in repos {
            for (days, isWeek) in [(30, false), (7, true)] {
                let out = (try? await Shell.run(git, ["-C", r.path, "log", "--all", "--since=\(days) days ago",
                                                     "--author=\(email)", "--format=%H"], timeout: 15)) ?? ""
                let n = Set(out.split(separator: "\n")).count
                if isWeek { d7 += n } else { d30 += n }
            }
        }
        return (d7, d30, repos.count, shown)
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
