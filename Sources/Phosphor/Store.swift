import Foundation
import Combine
import UserNotifications
import PhosphorCore

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderSnapshot] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var refreshing = false
    /// Combat log: what changed between refreshes (newest last).
    @Published private(set) var log: [LogLine] = []
    /// When each provider's window last reset — drives the Raid Frames revive animation.
    @Published private(set) var revivedAt: [String: Date] = [:]
    /// Plan, price, next bill and credits per provider, read from each service (refreshed every 30 min).
    @Published private(set) var accounts: [String: AccountInfo] = [:]
    private var accountsAt: Date?
    private var screensAt: Date?
    private var previous: [String: ProviderSnapshot] = [:]

    private let demo: Bool
    private let claude = ClaudeSource()
    private let codex = CodexSource()
    private let antigravity = AntigravitySource()
    private let grok = GrokSource()
    private let copilot = CopilotSource()
    private let muse = MuseSource()
    private let grokbot = GrokBotSource()
    private var timer: Timer?
    private var connectTimer: Timer?
    private let history: History
    /// Token history and API-equivalent cost from local session logs (chart, log-based rows).
    let logs: UsageLogs
    /// Public status pages for the providers on screen.
    let status = StatusMonitor()
    let registry = ProviderRegistry.shared
    /// GitHub PRs / commits and the efficiency numbers built on them (off until turned on).
    let dev: DevStatsService
    private var alertMemory = AlertMemory()
    private var bag = Set<AnyCancellable>()
    private static var alertMemoryFile: URL { Paths.support.appendingPathComponent("alerts-memory.json") }
    static var alertSettingsFile: URL { Paths.config.appendingPathComponent(AlertSettings.file) }
    private let demoSource = DemoSource()

    /// Fixed order for the native three; everything else is sorted by name.
    private let order = ["claude", "codex", "antigravity", "grok", "grokbot", "copilot", "muse"]

    init(demo: Bool) {
        self.demo = demo
        self.history = History(persist: !demo)
        self.logs = UsageLogs(load: !demo)
        self.dev = DevStatsService(demo: demo)
        if demo { logs.seedDemo(); accounts = DemoSource.accounts() }
        // Redraw rows when status dots or log totals change.
        status.objectWillChange.merge(with: logs.objectWillChange).merge(with: registry.objectWillChange)
            .merge(with: dev.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        if !demo, let d = try? Data(contentsOf: Self.alertMemoryFile),
           let m = try? JSONDecoder().decode(AlertMemory.self, from: d) { alertMemory = m }
    }

    /// Notification settings from ~/.config/phosphor/alerts.json (defaults when absent).
    var alertSettings: AlertSettings {
        get { (try? Data(contentsOf: Self.alertSettingsFile)).map(AlertSettings.decode) ?? AlertSettings() }
        set {
            try? FileManager.default.createDirectory(at: Paths.config, withIntermediateDirectories: true)
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? e.encode(newValue).write(to: Self.alertSettingsFile, options: .atomic)
        }
    }

    func start() {
        if !demo {
            Task {
                await registry.rescan()
                refresh()
                logs.refreshIfDue()
            }
        } else {
            refresh()
        }
        watchConnections()   // resume a sign-in started before a relaunch
        reschedule()
    }

    func reschedule() {
        timer?.invalidate()
        // The demo ticks fast so animations (Raid revive, pulses) show up in a recording.
        let interval = demo ? 6 : max(60, Prefs.shared.refreshSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let loaded = await self.loadSnapshots()
            self.applyLoadedSnapshots(loaded)
        }
    }

    /// Split out of `refresh()` so the Swift type checker on Xcode 16.4 can finish
    /// (the old 9-way `await a + b + …` expression timed out on GitHub Actions).
    private func loadSnapshots() async -> [ProviderSnapshot] {
        if demo {
            let d = demoSource.fetch()
            history.seed(d.samples, now: Date())
            return d.snapshots
        }

        async let claudeSnaps = claude.fetch()
        async let codexSnaps = codex.fetch()
        async let antigravitySnaps = antigravity.fetch()
        async let grokSnaps = grok.fetch()
        async let copilotSnaps = copilot.fetch()
        async let museSnaps = muse.fetch()
        async let grokbotSnaps = grokbot.fetch()
        async let customSnaps = CustomSource().fetch()
        async let extraSnaps = fetchExtras()

        var all: [ProviderSnapshot] = []
        all.append(contentsOf: await claudeSnaps)
        all.append(contentsOf: await codexSnaps)
        all.append(contentsOf: await antigravitySnaps)
        all.append(contentsOf: await grokSnaps)
        all.append(contentsOf: await copilotSnaps)
        all.append(contentsOf: await museSnaps)
        all.append(contentsOf: await grokbotSnaps)
        all.append(contentsOf: await customSnaps)
        all.append(contentsOf: await extraSnaps)

        all = keepLastGoodOnBlip(all)
        claudeWaiting = nil
        all = all.map(claudeFallback)
        history.record(all)
        return all
    }

    /// Rate-limited (429) or a 5xx blip: keep showing the last good reading.
    private func keepLastGoodOnBlip(_ incoming: [ProviderSnapshot]) -> [ProviderSnapshot] {
        incoming.map { current in
            guard case .error(let message) = current.state,
                  isTransientFetchError(message),
                  let previous = snapshots.first(where: { $0.id == current.id }),
                  previous.isConnected
            else { return current }
            return previous
        }
    }

    private func isTransientFetchError(_ message: String) -> Bool {
        message == "HTTP 429" || message.hasPrefix("HTTP 5")
    }

    private func applyLoadedSnapshots(_ loaded: [ProviderSnapshot]) {
        let annotated = decorate(history.annotate(loaded))
        narrate(annotated)
        snapshots = sorted(annotated)
        lastRefresh = Date()
        refreshing = false
        checkAlerts()
        guard !demo else { return }
        logs.refreshIfDue()
        status.refreshIfDue(ids: visible.map(\.id))
        if Prefs.shared.showDevStats { dev.refreshIfDue() }
        refreshAccountsIfDue()
    }

    /// Every 30 min, or as soon as new settings-screen readings are saved.
    private func refreshAccountsIfDue() {
        let screens = screenReadingsModifiedAt()
        let accountsStale = accountsAt.map { Date().timeIntervalSince($0) > 1800 } ?? true
        guard accountsStale || screens != screensAt else { return }
        screensAt = screens
        refreshAccounts()
    }

    private func screenReadingsModifiedAt() -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: ScreenReadings.file.path)
        return attrs?[.modificationDate] as? Date
    }

    func refreshAccounts() {
        accountsAt = Date()
        let claude = self.claude
        Task {
            var out: [String: AccountInfo] = [:]
            await withTaskGroup(of: (String, AccountInfo?).self) { group in
                for id in Set(order + snapshots.map(\.id)) {
                    group.addTask { (id, await Accounts.fetch(id, claude: claude)) }
                }
                for await (id, info) in group { if let info { out[id] = info } }
            }
            accounts = out
            writeEventsExport()
            checkAlerts()
        }
    }

    /// Default order, Google rows together, and whatever order the user dragged rows into.
    private func sorted(_ snaps: [ProviderSnapshot]) -> [ProviderSnapshot] {
        let names = Dictionary(snaps.map { ($0.id, $0.info.name) }, uniquingKeysWith: { a, _ in a })
        let ids = RowOrdering.sort(snaps.map(\.id), defaultOrder: order, custom: Prefs.shared.rowOrder) { names[$0] ?? $0 }
        let byID = Dictionary(snaps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    /// Saves a dragged scope's new order (top-level units, or one group's members) and re-sorts.
    func saveOrder(scope keys: [String]) {
        Prefs.shared.rowOrder = RowOrdering.merge(custom: Prefs.shared.rowOrder, scope: keys)
        snapshots = sorted(snapshots)
    }

    func resetOrder() {
        Prefs.shared.rowOrder = []
        snapshots = sorted(snapshots)
    }

    /// Attach API-equivalent spend from local logs (Codex / Claude / Gemini) and weekly sparklines.
    private func decorate(_ snaps: [ProviderSnapshot]) -> [ProviderSnapshot] {
        snaps.map { s in
            var s = attachLogSpend(s)
            guard case .ok(var windows, let plan) = s.state else { return s }
            windows = windows.map { w in
                var w = w
                if w.sparkline.isEmpty, w.isWeekly {
                    let hist = history.sparkline(provider: s.id, window: w.label)
                    if !hist.isEmpty { w.sparkline = hist }
                    else if w.gauged { w.sparkline = [w.usedPercent] }
                }
                return w
            }
            s.state = .ok(windows: windows, plan: plan)
            return s
        }
    }

    private func logSourceKey(_ id: String) -> String? {
        if id == "claude" || id.hasPrefix("claude@") { return "claude" }
        if id == "codex" || id.hasPrefix("codex@") { return "codex" }
        if id == "gemini" || id.hasPrefix("gemini@") { return "gemini" }
        return nil
    }

    /// Show 7-day API-equivalent $ on the row itself whenever local logs have priced usage.
    private func attachLogSpend(_ s: ProviderSnapshot) -> ProviderSnapshot {
        guard let key = logSourceKey(s.id), let week = logs.snapshot.week[key], week.tokens > 0 else { return s }
        func series(_ cost: Bool) -> [Double] {
            logs.sparkline(source: key, days: 7, cost: cost)
        }
        func appendMeters(_ windows: inout [UsageWindow]) {
            if !windows.contains(where: { $0.label == "7D EST" || $0.label == "7D API" }) {
                if week.cost > 0 {
                    var m = UsageWindow.meter("7D EST", used: week.cost, unit: "usd")
                    m.detail = "l10n:logs.apiEquivalent"
                    m.sparkline = series(true)
                    windows.append(m)
                } else if !windows.contains(where: { $0.label == "7D TOK" }) {
                    var m = UsageWindow.meter("7D TOK", used: Double(week.tokens), unit: "tokens")
                    if week.unpricedTokens > 0 {
                        m.detail = "unpriced:\(Fmt.compact(Double(week.unpricedTokens)))"
                    }
                    m.sparkline = series(false)
                    windows.append(m)
                }
            }
        }
        switch s.state {
        case .ok(var windows, let plan):
            appendMeters(&windows)
            var out = s
            out.state = .ok(windows: windows, plan: plan)
            return out
        case .idle(let m, let plan):
            var windows: [UsageWindow] = []
            appendMeters(&windows)
            guard !windows.isEmpty else { return s }
            var out = s
            out.state = .ok(windows: windows, plan: plan)
            out.staleNote = m
            return out
        default:
            return s
        }
    }

    /// Claude Code's token is waiting for Claude Code to refresh it: instead of a Connect prompt,
    /// show today's and this week's tokens from Claude Code's own logs (plan from its account cache).
    private func claudeFallback(_ s: ProviderSnapshot) -> ProviderSnapshot {
        guard s.id == "claude" || s.id.hasPrefix("claude@"),
              case .idle(let m, _) = s.state, ClaudeSource.isWaiting(m) else { return s }
        let plan = accounts[s.id]?.plan ?? snapshots.first { $0.id == s.id }?.plan
        claudeWaiting = m
        // Keep the bars: the last live 5H / 7D reading, clearly marked as cached.
        var windows: [UsageWindow] = []
        var note: String?
        if let last = history.lastKnown(s.id), !last.windows.isEmpty {
            // Always attach a forecast line (rate, measuring, steady, or no session) so the row
            // never goes blank while the token is waiting to refresh.
            windows = last.windows.map { w in
                var w = w
                w.forecast = history.forecast(provider: s.id, window: w, now: Date())
                return w
            }
            note = "cached:\(Int(last.at.timeIntervalSince1970))"
        }
        if s.id == "claude", let w = logs.snapshot.week["claude"], w.tokens > 0 {
            windows.append(.meter("TODAY", used: Double(logs.snapshot.today["claude"]?.tokens ?? 0), unit: "tokens"))
            if windows.contains(where: { $0.label == "7D" }) {
                if w.cost > 0 { windows.append(.meter("7D EST", used: w.cost, unit: "usd")) }
            } else {
                windows.append(.meter("7D TOK", used: Double(w.tokens), unit: "tokens"))
            }
            note = note ?? "logs"
        }
        guard !windows.isEmpty else { return ProviderSnapshot(info: s.info, state: .idle(m, plan: plan), updatedAt: s.updatedAt) }
        var out = ProviderSnapshot(info: s.info, state: .ok(windows: windows, plan: plan), updatedAt: s.updatedAt)
        out.staleNote = note
        return out
    }
    /// Why the Claude row shows log usage instead of live limits (hover card).
    @Published private(set) var claudeWaiting: String?

    /// Catalog providers that are on (installed, or switched on by hand) plus extra accounts.
    private func fetchExtras() async -> [ProviderSnapshot] {
        let snap = logs.snapshot
        let detected = registry.detected
        var sources: [UsageSource] = registry.enabledExtras.map {
            ExtraSources.source(for: $0, evidence: detected[$0.id], logs: snap)
        }
        for p in registry.profiles {
            let info = ProviderInfo.lookup(p.id)
            switch p.provider {
            case "codex": sources.append(CodexSource(info: info, home: p.home))
            case "claude": sources.append(ClaudeSource(info: info, service: p.claudeKeychainService, configDir: p.configDir))
            default: break
            }
        }
        return await withTaskGroup(of: [ProviderSnapshot].self) { g in
            for s in sources { g.addTask { await s.fetch() } }
            var out: [ProviderSnapshot] = []
            for await r in g { out += r }
            return out
        }
    }

    /// ~/.config/phosphor/events-export.json: upcoming bills and credit expiries for calendar apps.
    private func writeEventsExport() {
        guard !demo else { return }
        let inputs: [EventsExport.Input] = accounts.compactMap { id, a in
            let credits = a.credits.compactMap { c in c.expires.map { BillingReading.Credit(title: c.title, amount: c.amount.isEmpty ? nil : c.amount, expires: $0) } }
            guard a.nextBill != nil || !credits.isEmpty else { return nil }
            let price = a.monthlyPrice.map { Fmt.money($0, a.currency) }
            return EventsExport.Input(provider: id, providerName: ProviderInfo.lookup(id).name, nextBill: a.nextBill,
                                      price: price, credits: credits, source: a.screenSource ?? a.source,
                                      checkedAt: a.screenCheckedAt ?? accountsAt)
        }
        let export = EventsExport.build(inputs)
        guard let data = try? export.encoded() else { return }
        try? FileManager.default.createDirectory(at: Paths.config, withIntermediateDirectories: true)
        try? data.write(to: Paths.config.appendingPathComponent(EventsExport.fileName), options: .atomic)
        exportedEvents = export.events.count
    }
    @Published private(set) var exportedEvents = 0

    /// Monthly prices read, summed per currency ("KRW": 290000, "USD": 20).
    var monthlySums: [String: Double] {
        var sums: [String: Double] = [:]
        for id in pricedIDs { if let a = accounts[id], let p = a.monthlyPrice { sums[a.currency, default: 0] += p } }
        return sums
    }

    /// Sum of the monthly prices Phosphor read, per currency, over the providers on screen.
    var monthlyTotal: (text: String, read: Int, of: Int)? {
        let ids = pricedIDs
        guard !ids.isEmpty else { return nil }
        let sums = monthlySums
        let read = ids.filter { accounts[$0]?.monthlyPrice != nil }.count
        let text = sums.isEmpty ? "–" : sums.keys.sorted().map { Fmt.money(sums[$0]!, $0) }.joined(separator: " + ")
        return (text, read, ids.count)
    }

    private var pricedIDs: [String] {
        // Only subscriptions have a monthly price; local servers, API meters and log-only rows don't.
        let ids = visible.map(\.id).filter { id in
            guard accounts[id] != nil else { return false }
            let base = String(id.split(separator: "@").first ?? Substring(id))
            // A family (Google AI) is one subscription: only its billing row counts toward the total.
            if let f = ProviderFamilies.family(of: id), base != f.billingProvider { return false }
            guard let spec = ProviderCatalog.spec(base) else { return true }
            return spec.sources.contains(.billingScreen) && (ProviderRegistry.native.contains(base) || accounts[id]?.fromScreen.isEmpty == false)
        }
        return ids
    }

    // MARK: Connect (sign-in started from Phosphor)

    private func source(_ id: String) -> UsageSource? {
        switch id {
        case "claude": return claude      // keep the instance (Claude caches its token)
        default: return nativeSource(id)
        }
    }

    /// Short status under a row while a sign-in is in progress or just failed.
    @Published private(set) var connectNotes: [String: String] = [:]

    /// Opens the official sign-in for `id` and polls just that provider until it connects.
    func connect(_ id: String) {
        let name = snapshots.first { $0.id == id }?.info.name ?? ProviderInfo.lookup(id).name
        switch Connect.start(id, name: name) {
        case .unsupported: return
        case .alreadyOpen: break          // window brought to front; keep the current note
        case .opened:
            connectNotes[id] = id == "muse"
                ? "Approve the code in your browser. It isn't done until you press Approve."
                : "Finish signing in in the Terminal window and browser…"
        }
        Prefs.shared.hidden.remove(id)
        watchConnections()
    }

    /// Polls every 4 s only the providers being signed in to (not the whole set, to spare the
    /// other services' APIs), and stops once each is connected or after 15 minutes.
    func watchConnections() {
        guard !demo, connectTimer == nil, !Connect.pending.isEmpty else { return }
        connectTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollConnections() }
        }
    }

    private var polling = false
    private func pollConnections() async {
        let ids = Connect.pending
        guard !ids.isEmpty else { connectTimer?.invalidate(); connectTimer = nil; return }
        guard !polling else { return }
        polling = true
        defer { polling = false }
        for id in ids {
            guard let src = source(id) else { Connect.finish(id); continue }
            if let why = Connect.failure(id) {         // the sign-in script checked and gave up
                Connect.finish(id)
                connectNotes[id] = "Sign-in didn't connect: \(why)"
                say("\(ProviderInfo.lookup(id).name) sign-in failed", .warn, at: Date())
                continue
            }
            let fresh = await src.fetch()
            guard let snap = fresh.first, snap.isConnected else { continue }
            Connect.finish(id)
            connectNotes[id] = nil
            if let i = snapshots.firstIndex(where: { $0.id == id }) { snapshots[i] = snap }
            say("\(snap.info.name) connected", .info, at: Date())
            refresh()   // full refresh so history/forecast pick it up
        }
    }

    /// Snapshots that should be drawn given current prefs.
    var visible: [ProviderSnapshot] {
        let p = Prefs.shared
        return snapshots.filter { !p.hidden.contains($0.id) && (p.showUnavailable || $0.isAvailable) }.map { s in
            guard let a = accounts[s.id], a.planOverridden, let plan = a.plan else { return s }
            var s = s; s.planOverride = plan; return s
        }
    }

    // MARK: Combat log

    private func say(_ text: String, _ kind: LogLine.Kind, at now: Date) {
        log.append(LogLine(at: now, text: text, kind: kind))
        if log.count > 30 { log.removeFirst(log.count - 30) }
    }

    private func narrate(_ snaps: [ProviderSnapshot]) {
        let now = Date()
        defer { previous = Dictionary(uniqueKeysWithValues: snaps.map { ($0.id, $0) }) }
        let online = snaps.filter { !$0.windows.isEmpty }

        guard !previous.isEmpty else {
            say("Raid assembled · \(online.count) online", .info, at: now)
            if let (s, w, f) = online.flatMap({ s in s.windows.compactMap { w in w.forecast.map { (s, w, $0) } } })
                .filter({ $0.2.warnsBeforeReset }).min(by: { ($0.2.hitsLimitAt ?? .distantFuture) < ($1.2.hitsLimitAt ?? .distantFuture) }),
               let hits = f.hitsLimitAt {
                say(T.t("log.runsDry", s.info.name, w.label, T.clock(hits, now: now)), .warn, at: now)
            }
            return
        }

        for s in snaps {
            guard let prev = previous[s.id] else { continue }
            let name = s.info.name
            if !prev.windows.isEmpty, s.windows.isEmpty, s.isAvailable {
                say("\(name) has gone offline", .danger, at: now); continue
            }
            if prev.windows.isEmpty, !s.windows.isEmpty {
                say("\(name) joins the raid", .info, at: now)
            }
            for w in s.windows {
                guard let pw = prev.windows.first(where: { $0.label == w.label }) else { continue }
                let resetMoved = (w.resetsAt?.timeIntervalSince(pw.resetsAt ?? .distantPast) ?? 0) > 3600
                if pw.usedPercent - w.usedPercent >= 25 || (resetMoved && w.usedPercent < pw.usedPercent) {
                    revivedAt[s.id] = now
                    say("✚ \(name) \(w.label) resurrected · \(Int(w.remainingPercent.rounded()))% HP", .heal, at: now)
                } else if pw.usedPercent < 100, w.usedPercent >= 100 {
                    say("☠ \(name) has been defeated (\(w.label))", .danger, at: now)
                } else if pw.usedPercent < 95, w.usedPercent >= 95 {
                    say("\(name) is Exhausted · \(w.label) at \(Int(w.usedPercent))%", .danger, at: now)
                } else if pw.usedPercent < 90, w.usedPercent >= 90 {
                    say("\(name) \(w.label) is at \(Int(w.usedPercent))% · low HP", .danger, at: now)
                } else if let f = w.forecast, f.warnsBeforeReset, pw.forecast?.warnsBeforeReset != true,
                          let hits = f.hitsLimitAt {
                    say(T.t("log.runsDry", name, w.label, T.clock(hits, now: now)), .warn, at: now)
                }
            }
        }
    }

    // MARK: Alerts — warning / critical / reset / bill / credit expiry (see AlertEngine)

    private func checkAlerts() {
        guard !demo else { return }
        let quotas = snapshots.filter { $0.staleNote == nil }.flatMap { s in
            s.gauges.map { QuotaReading(provider: s.id, providerName: s.info.name, window: $0.label,
                                        used: $0.usedPercent, resetsAt: $0.resetsAt) }
        }
        let bills = accounts.map { id, a in
            BillingReading(provider: id, providerName: ProviderInfo.lookup(id).name,
                           nextBill: a.staleReasons.isEmpty ? a.nextBill : nil,   // never warn from a stale date
                           price: a.monthlyPrice.map { Fmt.money($0, a.currency) },
                           credits: a.credits.compactMap { c in c.expires.map { .init(title: c.title, amount: c.amount.isEmpty ? nil : c.amount, expires: $0) } })
        }
        let fired = AlertEngine.evaluate(quotas: quotas, bills: bills, settings: alertSettings, memory: &alertMemory)
        for a in fired { notify(title: a.title, body: a.body) }
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(alertMemory).write(to: Self.alertMemoryFile, options: .atomic)
    }

    private func notify(title: String, body: String) {
        // UNUserNotificationCenter needs a real .app bundle.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
}
