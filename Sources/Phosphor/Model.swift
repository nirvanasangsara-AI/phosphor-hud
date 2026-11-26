import Foundation
import SwiftUI
import PhosphorCore

// MARK: - Core data

/// What a window measures. Most plans are a % quota that resets; some only tell you a balance
/// (credits or tokens left), and some only count what you used, with no limit at all.
enum Measure: Hashable {
    case quota                                              // usedPercent of a limit, resets
    case balance(left: Double, total: Double?, unit: String) // what's left; a bar only if the total is known
    case meter(used: Double, unit: String)                  // usage over a period, no limit
}

/// One usage window (e.g. Claude 5-hour, Codex weekly, a credit balance, 7-day tokens).
struct UsageWindow: Identifiable, Hashable {
    var id: String { label }
    let label: String            // "5H", "7D", "PRO", ...
    let usedPercent: Double      // 0...100; 0 when there's no limit to measure against
    let resetsAt: Date?
    let windowSeconds: TimeInterval?
    var forecast: Forecast? = nil   // filled in from History after each refresh
    var measure: Measure = .quota
    /// Optional subtitle (model names, “API-equivalent from local logs”, …).
    var detail: String? = nil
    /// Named tags drawn as compact badges (Ollama models, etc.).
    var tags: [String] = []
    /// Historical samples for a weekly sparkline (raw values, any unit).
    var sparkline: [Double] = []

    var remainingPercent: Double { max(0, 100 - usedPercent) }

    /// Has a limit to draw a bar against (and to alert, forecast and raid on).
    var gauged: Bool {
        switch measure {
        case .quota: return true
        case .balance(_, let total, _): return (total ?? 0) > 0
        case .meter: return false
        }
    }

    var isWeekly: Bool { SparklineSeries.isWeekly(label: label, windowSeconds: windowSeconds) }

    /// "1.2M of 5M credits left", "$4.20 left", "820K tokens": nil for a plain quota.
    var amountText: String? {
        switch measure {
        case .quota: return nil
        case .balance(let left, let total, let unit):
            if let total, total > 0 { return "\(Fmt.amount(left, unit, bare: true)) of \(Fmt.amount(total, unit)) left" }
            return "\(Fmt.amount(left, unit)) left"
        case .meter(let used, let unit): return Fmt.amount(used, unit)
        }
    }

    static func balance(_ label: String, left: Double, total: Double?, unit: String,
                        resetsAt: Date? = nil, windowSeconds: TimeInterval? = nil) -> UsageWindow {
        let used = total.flatMap { $0 > 0 ? min(100, max(0, ($0 - left) / $0 * 100)) : nil } ?? 0
        return UsageWindow(label: label, usedPercent: used, resetsAt: resetsAt, windowSeconds: windowSeconds,
                           measure: .balance(left: left, total: total, unit: unit))
    }

    static func meter(_ label: String, used: Double, unit: String,
                      resetsAt: Date? = nil, windowSeconds: TimeInterval? = nil) -> UsageWindow {
        UsageWindow(label: label, usedPercent: 0, resetsAt: resetsAt, windowSeconds: windowSeconds,
                    measure: .meter(used: used, unit: unit))
    }

    /// Where you "should" be if you spread usage evenly across the window (0...100).
    var pacePercent: Double? {
        guard let r = resetsAt, let w = windowSeconds, w > 0 else { return nil }
        let elapsed = w - r.timeIntervalSinceNow
        return min(max(elapsed / w * 100, 0), 100)
    }
}

/// Static description of a provider: name, short monogram, colour.
struct ProviderInfo: Hashable {
    let id: String
    let name: String
    let monogram: String
    let colorHex: String

    var color: Color { Color(hex: colorHex) }

    /// Built-in catalogue. Unknown ids get a generated monogram + colour.
    /// Colours only — no third-party logos are bundled (drop your own PNGs in
    /// ~/.config/phosphor/icons/<id>.png if you want real icons).
    static let catalog: [String: ProviderInfo] = {
        let list: [ProviderInfo] = [
            .init(id: "claude", name: "Claude Code", monogram: "C", colorHex: "#D97757"),
            .init(id: "codex", name: "Codex", monogram: "Cx", colorHex: "#10A37F"),
            .init(id: "gemini", name: "Gemini CLI", monogram: "G", colorHex: "#4796E3"),
            .init(id: "cursor", name: "Cursor", monogram: "Cu", colorHex: "#9CA3AF"),
            .init(id: "copilot", name: "Copilot", monogram: "Co", colorHex: "#8B5CF6"),
            .init(id: "grok", name: "Grok CLI", monogram: "X", colorHex: "#E5E7EB"),
            .init(id: "grokbot", name: "Grok Bot", monogram: "GB", colorHex: "#7DD3FC"),
            .init(id: "perplexity", name: "Perplexity", monogram: "P", colorHex: "#20B8CD"),
            .init(id: "muse", name: "Muse Code", monogram: "M", colorHex: "#0866FF"),
            .init(id: "kimi", name: "Kimi", monogram: "K", colorHex: "#6366F1"),
            .init(id: "z.ai", name: "z.ai", monogram: "Z", colorHex: "#3B82F6"),
            .init(id: "openrouter", name: "OpenRouter", monogram: "OR", colorHex: "#94A3B8"),
            .init(id: "minimax", name: "MiniMax", monogram: "Mm", colorHex: "#F43F5E"),
            .init(id: "deepseek", name: "DeepSeek", monogram: "D", colorHex: "#4D6BFE"),
            .init(id: "mistral", name: "Mistral", monogram: "Mi", colorHex: "#FA520F"),
            .init(id: "warp", name: "Warp", monogram: "W", colorHex: "#01A4FF"),
            .init(id: "kilo", name: "Kilo", monogram: "Ki", colorHex: "#F8F675"),
            .init(id: "antigravity", name: "Antigravity", monogram: "A", colorHex: "#34A853"),
            .init(id: "factory", name: "Droid", monogram: "Dr", colorHex: "#F97316"),
            .init(id: "amp", name: "Amp", monogram: "Am", colorHex: "#EF4444"),
        ]
        // Every provider in PhosphorCore's catalog too; the entries above win where both exist.
        let extra = ProviderCatalog.all.map { ProviderInfo(id: $0.id, name: $0.name, monogram: $0.monogram, colorHex: $0.colorHex) }
        return Dictionary((list + extra).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    static func lookup(_ id: String, name: String? = nil, colorHex: String? = nil) -> ProviderInfo {
        // "codex@work": a second account of a known provider (accounts.json).
        if let at = id.firstIndex(of: "@"), let base = catalog[String(id[..<at]).lowercased()] {
            let profile = String(id[id.index(after: at)...])
            return ProviderInfo(id: id, name: name ?? "\(base.name) · \(profile)", monogram: base.monogram,
                                colorHex: colorHex ?? base.colorHex)
        }
        if let known = catalog[id.lowercased()] {
            return ProviderInfo(id: known.id, name: name ?? known.name,
                                monogram: known.monogram, colorHex: colorHex ?? known.colorHex)
        }
        let display = name ?? id.capitalized
        let mono = String(display.prefix(2))
        let palette = ["#F59E0B", "#22D3EE", "#A3E635", "#F472B6", "#60A5FA", "#C084FC"]
        let idx = abs(id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count
        return ProviderInfo(id: id, name: display, monogram: mono, colorHex: colorHex ?? palette[idx])
    }
}

struct LogLine: Identifiable {
    enum Kind { case info, heal, warn, danger }
    let id = UUID()
    let at: Date
    let text: String
    let kind: Kind
}

enum ProviderState {
    case loading
    case ok(windows: [UsageWindow], plan: String?)
    case idle(String, plan: String?)   // signed in, but the service reports nothing to show yet
    case unavailable(String)   // not installed / not logged in — hidden by default
    case error(String)         // logged in but fetch failed — shown dimmed
}

struct ProviderSnapshot: Identifiable {
    let info: ProviderInfo
    var state: ProviderState
    var updatedAt: Date?
    var id: String { info.id }

    var windows: [UsageWindow] {
        if case .ok(let w, _) = state { return w }
        return []
    }
    /// A plan name read from the service's own settings screen that replaces a stale cached label.
    var planOverride: String? = nil
    /// Set when the bars are a cached reading, not live ("cached 23:10 · …"); shown under the bars.
    var staleNote: String? = nil
    var plan: String? {
        if let planOverride { return planOverride }
        if case .ok(_, let p) = state { return p }
        if case .idle(_, let p) = state { return p }
        return nil
    }
    /// Not signed in, or the login expired: Connect can fix it.
    var needsSignIn: Bool {
        switch state {
        case .unavailable: return true
        case .error(let m): return m.contains("expired") || m == "HTTP 401" || m == "HTTP 403"
        default: return false
        }
    }
    var isAvailable: Bool {
        if case .unavailable = state { return false }
        return true
    }
    /// Windows with a limit (quotas, balances with a known total).
    var gauges: [UsageWindow] { windows.filter(\.gauged) }
    /// Signed in and readable, with or without numbers.
    var isConnected: Bool {
        switch state { case .ok, .idle: return true; default: return false }
    }
    /// Highest pressure across windows — used for sorting / alerts.
    var maxUsed: Double { gauges.map(\.usedPercent).max() ?? 0 }
}

enum ProviderError: LocalizedError {
    case notConfigured(String)
    case expired(String)
    case idle(String)          // signed in, nothing to count yet
    case http(Int)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let m): return m
        case .expired(let m): return m
        case .idle(let m): return m
        case .http(let c): return "HTTP \(c)"
        case .parse(let m): return "parse: \(m)"
        }
    }

    var state: ProviderState {
        switch self {
        case .notConfigured(let m): return .unavailable(m)
        case .idle(let m): return .idle(m, plan: nil)
        default: return .error(errorDescription ?? "error")
        }
    }
}

// MARK: - Helpers

enum Fmt {
    static func countdown(to date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "now" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// "14:32" today, "Thu 14:32" otherwise.
    static func clock(_ date: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }

    static func windowLabel(seconds: Double?) -> String {
        guard let s = seconds, s > 0 else { return "LIM" }
        if abs(s - 18000) < 60 { return "5H" }
        if abs(s - 604800) < 600 { return "7D" }
        if abs(s - 86400) < 600 { return "1D" }
        if s >= 86400 { return "\(Int((s / 86400).rounded()))D" }
        if s >= 3600 { return "\(Int((s / 3600).rounded()))H" }
        return "\(Int((s / 60).rounded()))M"
    }

    /// 1234 → "1.2K tokens", 4.2 USD → "$4.20". `bare` drops the unit (for "1.2M of 5M tokens").
    static func amount(_ v: Double, _ unit: String, bare: Bool = false) -> String {
        let u = unit.trimmingCharacters(in: .whitespaces)
        if ["usd", "$"].contains(u.lowercased()) {
            if v >= 10_000 { return "$" + compact(v) }
            if v >= 1000 { return "$" + v.rounded().formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))) }
            return String(format: "$%.2f", v)
        }
        let n = compact(v)
        return bare || u.isEmpty ? n : "\(n) \(u)"
    }

    static func compact(_ v: Double) -> String {
        let a = abs(v)
        func f(_ x: Double, _ s: String) -> String {
            let t = x >= 100 ? String(format: "%.0f", x) : String(format: "%.1f", x)
            return (t.hasSuffix(".0") ? String(t.dropLast(2)) : t) + s
        }
        if a >= 1e9 { return f(v / 1e9, "B") }
        if a >= 1e6 { return f(v / 1e6, "M") }
        if a >= 1e4 { return f(v / 1e3, "K") }
        return a == a.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    static func parseISO(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return d }
        // Microsecond fractions ("...:00.123456+00:00") trip ISO8601DateFormatter.
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            var t = s
            t.removeSubrange(r)
            return f2.date(from: t)
        }
        return nil
    }

    /// Accepts epoch seconds, epoch millis or ISO strings.
    static func date(_ v: Any?) -> Date? {
        if let s = v as? String {
            if let n = Double(s) { return date(n) }
            return parseISO(s)
        }
        guard let n = num(v), n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
    }
}

func num(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        var r = 1.0, g = 1.0, b = 1.0, a = 1.0
        if s.count == 8 {              // #RRGGBBAA
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255
            a = Double(v & 0xFF) / 255
        } else if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Preferences

final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var theme: String { didSet { d.set(theme, forKey: "theme") } }
    @Published var compact: Bool { didSet { d.set(compact, forKey: "compact") } }
    @Published var opacity: Double { didSet { d.set(opacity, forKey: "opacity") } }
    @Published var clickThrough: Bool { didSet { d.set(clickThrough, forKey: "clickThrough") } }
    @Published var showUnavailable: Bool { didSet { d.set(showUnavailable, forKey: "showUnavailable") } }
    @Published var hidden: Set<String> { didSet { d.set(Array(hidden), forKey: "hiddenProviders") } }
    @Published var refreshSeconds: Double { didSet { d.set(refreshSeconds, forKey: "refreshSeconds") } }
    /// Off by default: Claude Code doesn't expose reset credits, so reading them means using the
    /// Claude login outside Claude Code, which Anthropic's terms restrict.
    @Published var claudeResetCredits: Bool { didSet { d.set(claudeResetCredits, forKey: "claudeResetCredits") } }
    /// Catalog providers switched on or off by hand; absent = on when installed.
    @Published var providerOverrides: [String: Bool] { didSet { d.set(providerOverrides, forKey: "providerOverrides") } }
    /// The usage chart under the rows (tokens and API-equivalent cost from local logs).
    @Published var showChart: Bool { didSet { d.set(showChart, forKey: "showChart") } }
    @Published var showDevStats: Bool { didSet { d.set(showDevStats, forKey: "showDevStats") } }
    @Published var chartCost: Bool { didSet { d.set(chartCost, forKey: "chartCost") } }
    /// Row order dragged by hand (row ids and "group:<family>" keys); empty = default order.
    @Published var rowOrder: [String] { didSet { d.set(rowOrder, forKey: "rowOrder") } }
    /// Family groups folded to one line.
    @Published var collapsedGroups: Set<String> { didSet { d.set(Array(collapsedGroups), forKey: "collapsedGroups") } }
    /// The user dragged an edge or corner; the HUD keeps this frame across launches.
    @Published var hudUserSized: Bool { didSet { d.set(hudUserSized, forKey: "hudUserSized") } }
    @Published var hudWidth: Double { didSet { d.set(hudWidth, forKey: "hudWidth") } }
    @Published var hudHeight: Double { didSet { d.set(hudHeight, forKey: "hudHeight") } }

    private init() {
        theme = d.string(forKey: "theme") ?? "clean"
        compact = d.bool(forKey: "compact")
        opacity = d.object(forKey: "opacity") as? Double ?? 1.0
        clickThrough = d.bool(forKey: "clickThrough")
        showUnavailable = d.bool(forKey: "showUnavailable")
        hidden = Set(d.stringArray(forKey: "hiddenProviders") ?? [])
        refreshSeconds = d.object(forKey: "refreshSeconds") as? Double ?? 180
        claudeResetCredits = d.bool(forKey: "claudeResetCredits")
        providerOverrides = (d.dictionary(forKey: "providerOverrides") as? [String: Bool]) ?? [:]
        showChart = d.bool(forKey: "showChart")
        showDevStats = d.bool(forKey: "showDevStats")
        chartCost = d.object(forKey: "chartCost") as? Bool ?? true
        rowOrder = d.stringArray(forKey: "rowOrder") ?? []
        collapsedGroups = Set(d.stringArray(forKey: "collapsedGroups") ?? [])
        hudUserSized = d.bool(forKey: "hudUserSized")
        hudWidth = d.object(forKey: "hudWidth") as? Double ?? 0
        hudHeight = d.object(forKey: "hudHeight") as? Double ?? 0
    }

    func hideProvider(_ id: String) {
        hidden = ProviderVisibility.hiding(id, in: hidden)
    }

    func showProvider(_ id: String) {
        hidden = ProviderVisibility.showing(id, in: hidden)
    }
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var config: URL { home.appendingPathComponent(".config/phosphor") }
    static var customProviders: URL { config.appendingPathComponent("providers.json") }
    static var support: URL { home.appendingPathComponent("Library/Application Support/Phosphor") }
    static var caches: URL { home.appendingPathComponent("Library/Caches/Phosphor") }
    static func icon(for id: String) -> URL { config.appendingPathComponent("icons/\(id).png") }
}
