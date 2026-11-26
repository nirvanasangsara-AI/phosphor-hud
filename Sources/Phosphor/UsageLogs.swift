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
    }

    @Published private(set) var daily: [UsageLedger.DayTotal] = []
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var scanning = false
    @Published private(set) var pricesAt: Date?
    @Published private(set) var priced = 0
    private var ledger = UsageLedger()
    private var prices = PriceTable()
    private var lastScan: Date?

    nonisolated static var ledgerFile: URL { Paths.support.appendingPathComponent("usage-ledger.json") }
    nonisolated static var pricesFile: URL { Paths.caches.appendingPathComponent("litellm-prices.json") }
    static let sources = ["claude", "codex", "gemini", "cline", "roo"]

    init(load: Bool) {
        guard load else { return }
        if let d = try? Data(contentsOf: Self.ledgerFile), let l = try? JSONDecoder().decode(UsageLedger.self, from: d) { ledger = l }
        loadPrices()
        recompute()
    }

    /// Scans at most every 10 minutes (incremental: only bytes added since the last scan).
    func refreshIfDue(force: Bool = false) {
        guard !scanning, force || (lastScan.map { Date().timeIntervalSince($0) > 600 } ?? true) else { return }
        scanning = true
        lastScan = Date()
        let start = ledger
        Task {
            await updatePricesIfStale()
            let scanned = await Task.detached(priority: .background) { () -> UsageLedger in
                var l = start
                LogScanner().scan(&l)
                if let data = try? JSONEncoder().encode(l) {
                    try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
                    try? data.write(to: UsageLogs.ledgerFile, options: .atomic)
                }
                return l
            }.value
            ledger = scanned
            recompute()
            scanning = false
        }
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
        var s = Snapshot(scannedAt: ledger.scannedAt)
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
    }

    // MARK: Prices (public file, refreshed daily)

    private func loadPrices() {
        guard let d = try? Data(contentsOf: Self.pricesFile), let t = try? PriceTable(litellmJSON: d) else { return }
        prices = t
        priced = t.prices.count
        pricesAt = (try? FileManager.default.attributesOfItem(atPath: Self.pricesFile.path))?[.modificationDate] as? Date
    }

    private func updatePricesIfStale() async {
        if let at = pricesAt, Date().timeIntervalSince(at) < 86_400, !prices.isEmpty { return }
        var req = URLRequest(url: PriceTable.sourceURL)
        req.timeoutInterval = 30
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, (try? PriceTable(litellmJSON: data)) != nil else { return }
        try? FileManager.default.createDirectory(at: Paths.caches, withIntermediateDirectories: true)
        try? data.write(to: Self.pricesFile, options: .atomic)
        loadPrices()
    }
}
