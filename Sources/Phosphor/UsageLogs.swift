import Foundation
import PhosphorCore

/// Token history from local session logs (Claude Code, Codex, Gemini CLI, Cline, Roo Code),
/// priced at API list rates from LiteLLM's public table. Read-only: only usage numbers are kept,
/// never prompts or replies. The ledger lives in ~/Library/Application Support/Phosphor.
@MainActor
final class UsageLogs: ObservableObject {
    struct Snapshot: Sendable {
        var today: [String: UsageLedger.Summary] = [:]
        var week: [String: UsageLedger.Summary] = [:]
        var month: [String: UsageLedger.Summary] = [:]
        var scannedAt: Date?
        var pricesReady = false
    }

    @Published private(set) var daily: [UsageLedger.DayTotal] = []
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var scanning = false
    @Published private(set) var pricesAt: Date?
    @Published private(set) var priced = 0
    /// Set when every price URL failed. Rows use this only while the table is still empty.
    @Published private(set) var priceError: String?
    /// Host that supplied the cached file (`raw.githubusercontent.com` or `cdn.jsdelivr.net`).
    @Published private(set) var priceHost: String?
    /// `cache`, `bundle`, `demo`, or `none`.
    @Published private(set) var priceOrigin = "none"
    @Published private(set) var bundledPriceDate: String?
    var pricesReady: Bool { priced > 0 }
    private var ledger = UsageLedger()
    private var prices = PriceTable()
    private var lastScan: Date?
    private var priceBusy = false
    private var priceRetry: Task<Void, Never>?
    private let loader: any PriceURLLoading

    nonisolated static var ledgerFile: URL { Paths.support.appendingPathComponent("usage-ledger.json") }
    nonisolated static var pricesFile: URL { Paths.caches.appendingPathComponent("litellm-prices.json") }
    static let sources = ["claude", "codex", "gemini", "cline", "roo"]

    init(load: Bool, loader: any PriceURLLoading = URLSessionPriceLoader()) {
        self.loader = loader
        guard load else { return }
        if let d = try? Data(contentsOf: Self.ledgerFile), let l = try? JSONDecoder().decode(UsageLedger.self, from: d) { ledger = l }
        loadPrices()
        recompute()
    }

    /// Scans at most every 10 minutes (incremental: only bytes added since the last scan).
    /// Price retries are separate: a failed download tries again in two minutes even while this guard holds.
    func refreshIfDue(force: Bool = false) {
        guard !scanning, force || (lastScan.map { Date().timeIntervalSince($0) > 600 } ?? true) else { return }
        scanning = true
        lastScan = Date()
        let start = ledger
        Task {
            async let priceUpdate: Void = updatePricesIfStale()
            let scanned = await Task.detached(priority: .background) { () -> UsageLedger in
                var l = start
                LogScanner().scan(&l)
                if let data = try? JSONEncoder().encode(l) {
                    try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
                    try? data.write(to: UsageLogs.ledgerFile, options: .atomic)
                }
                return l
            }.value
            _ = await priceUpdate
            ledger = scanned
            recompute()
            scanning = false
        }
    }

    /// Banner click. Does not wait for the log-scan guard.
    func refreshPrices() {
        Task { await updatePricesIfStale(force: true) }
    }

    func models(_ source: String, days: Int) -> [(model: String, usage: TokenUsage, cost: Double?)] {
        ledger.modelBreakdown(lastDays: days, source: source).map { ($0.model, $0.usage, prices.cost($0.usage, model: $0.model)) }
    }

    /// One point per day for the last `days` days (oldest first), including zeros for missing days.
    func sparkline(source: String, days: Int, cost: Bool, now: Date = Date()) -> [Double] {
        let keys = (0..<days).reversed().map { DayKey.of(now.addingTimeInterval(-Double($0) * 86_400)) }
        let byDay = Dictionary(uniqueKeysWithValues: daily.filter { $0.source == source }.map { ($0.day, $0) })
        return keys.map { key in
            guard let row = byDay[key] else { return 0 }
            return cost ? row.cost : Double(row.tokens)
        }
    }

    private func recompute() {
        daily = ledger.dailyTotals(prices: prices)
        var s = Snapshot(scannedAt: ledger.scannedAt, pricesReady: pricesReady)
        for src in Self.sources {
            s.today[src] = ledger.summary(lastDays: 1, source: src, prices: prices)
            s.week[src] = ledger.summary(lastDays: 7, source: src, prices: prices)
            s.month[src] = ledger.summary(lastDays: 30, source: src, prices: prices)
        }
        snapshot = s
    }

    /// The earliest day the ledger has fully read (the first scan covers 7 days, then grows to 30).
    var coverageStart: Date? { demoDaily != nil ? Date().addingTimeInterval(-40 * 86_400) : ledger.since }

    func total(days: Int) -> UsageLedger.Summary {
        if let demo = demoDaily {
            let keep = Set((0..<days).map { DayKey.of(Date().addingTimeInterval(-Double($0) * 86_400)) })
            var s = UsageLedger.Summary()
            for d in demo where keep.contains(d.day) { s.tokens += d.tokens; s.cost += d.cost }
            return s
        }
        return ledger.summary(lastDays: days, prices: prices)
    }

    // MARK: Demo (`--demo`): made-up daily totals for screenshots

    private var demoDaily: [UsageLedger.DayTotal]?

    func seedDemo() {
        var out: [UsageLedger.DayTotal] = []
        for k in 0..<30 {
            let day = DayKey.of(Date().addingTimeInterval(-Double(k) * 86_400))
            let wave = 0.6 + 0.4 * sin(Double(k) * 0.9) + (k % 7 == 5 || k % 7 == 6 ? -0.35 : 0.1)
            for (src, base, perM) in [("claude", 180.0, 0.55), ("codex", 70.0, 0.9), ("gemini", 25.0, 0.4)] {
                let m = max(5, base * wave * (k == 0 ? 0.55 : 1))
                out.append(.init(day: day, source: src, tokens: Int(m * 1_000_000), cost: m * perM, unpricedTokens: 0))
            }
        }
        demoDaily = out
        daily = out
        priced = 1
        priceOrigin = "demo"
        priceError = nil
    }

    // MARK: Prices (cache, then the copy bundled in the app, then the network)

    private func bundleData() -> Data? {
        guard let url = Bundle.main.url(forResource: "litellm-prices", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    private func loadPrices(host: String? = nil) {
        let cache = try? Data(contentsOf: Self.pricesFile)
        let outcome = PriceLoading.choose(cache: cache, bundle: bundleData())
        prices = outcome.table
        priced = outcome.table.prices.count
        priceOrigin = outcome.origin
        bundledPriceDate = outcome.bundledOn
        if outcome.origin == "cache" {
            pricesAt = (try? FileManager.default.attributesOfItem(atPath: Self.pricesFile.path))?[.modificationDate] as? Date
            priceHost = host ?? (try? String(contentsOf: Self.pricesFile.appendingPathExtension("source"), encoding: .utf8))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if !outcome.table.isEmpty { priceError = nil }
    }

    private func updatePricesIfStale(force: Bool = false) async {
        guard !priceBusy else { return }
        guard force || PriceRefresh.shouldFetch(cachedAt: pricesAt, ready: pricesReady, origin: priceOrigin) else { return }
        priceBusy = true
        defer { priceBusy = false }
        if let got = await PriceFetcher.fetch(loader: loader) {
            do {
                let outcome = try PriceCache.storeAndReload(data: got.data, cache: Self.pricesFile, bundle: bundleData())
                try? got.host.write(to: Self.pricesFile.appendingPathExtension("source"), atomically: true, encoding: .utf8)
                prices = outcome.table
                priced = outcome.table.prices.count
                priceOrigin = outcome.origin
                bundledPriceDate = nil
                pricesAt = Date()
                priceHost = got.host
                priceError = nil
                priceRetry?.cancel()
                recompute()
                return
            } catch {
                // Fall through to the same visible failure as a refused download.
            }
        }
        priceError = "price table not loaded"
        schedulePriceRetry()
    }

    private func schedulePriceRetry() {
        priceRetry?.cancel()
        priceRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(PriceRefresh.retryDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.updatePricesIfStale(force: true)
        }
    }
}
