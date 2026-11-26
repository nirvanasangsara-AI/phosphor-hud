import Foundation

/// Burn-rate forecast for one window, from the last 30–60 minutes of samples.
struct Forecast: Hashable {
    let hitsLimitAt: Date      // when usage would reach 100% at the current rate
    let ratePerHour: Double    // percentage points per hour
    let beforeReset: Bool      // true = you run dry before the window resets
    let atReset: Double?       // projected usage when the window resets (0...100)
}

/// One persisted sample: `{"t":…, "p":"claude", "w":"5H", "u":62, "r":…}`.
struct UsageSample: Codable {
    let t: TimeInterval        // epoch seconds
    let p: String              // provider id
    let w: String              // window label
    let u: Double              // used %
    let r: TimeInterval?       // resetsAt (epoch seconds)
}

/// Append-only usage log at ~/Library/Application Support/Phosphor/history.jsonl,
/// plus the slope math behind "runs out at 14:32".
@MainActor
final class History {
    static let lookback: TimeInterval = 60 * 60      // fit over the last hour…
    static let minSpan: TimeInterval = 30 * 60       // …but only once we have 30 minutes of data
    static let minRate = 0.25                        // %/h below this counts as idle
    private static let keepInMemory: TimeInterval = 8 * 3600
    /// Weekly and longer windows move slowly: fit over 6 hours (at least 1 hour of data) so their
    /// burn rate shows up instead of drowning in rounding.
    static let longLookback: TimeInterval = 6 * 3600
    static let longMinSpan: TimeInterval = 60 * 60
    private static let keepOnDisk: TimeInterval = 30 * 86400
    private static let compactAbove = 4 * 1024 * 1024

    private let persist: Bool
    private var recent: [String: [UsageSample]] = [:]   // "<provider>|<window>" → samples, oldest first
    /// Newest sample per provider and window, from everything on disk (for cached bars).
    private var latest: [String: [String: UsageSample]] = [:]

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phosphor/history.jsonl")
    }

    init(persist: Bool) {
        self.persist = persist
        if persist { load() }
    }

    // MARK: Recording

    func record(_ snaps: [ProviderSnapshot], at now: Date = Date()) {
        var lines: [UsageSample] = []
        for s in snaps where s.staleNote == nil {   // never re-record a cached reading
            for w in s.gauges {   // balances without a total and meters have no % to forecast
                let sample = UsageSample(t: now.timeIntervalSince1970, p: s.id, w: w.label, u: w.usedPercent,
                                         r: w.resetsAt?.timeIntervalSince1970)
                remember(sample, now: now)
                lines.append(sample)
            }
        }
        if persist, !lines.isEmpty { append(lines) }
    }

    /// Demo mode: replace memory with synthetic samples.
    func seed(_ samples: [UsageSample], now: Date) {
        recent = [:]
        for s in samples.sorted(by: { $0.t < $1.t }) { remember(s, now: now) }
    }

    /// The last live reading of `provider`'s gauges, with when it was taken.
    func lastKnown(_ provider: String) -> (windows: [UsageWindow], at: Date)? {
        guard let byWindow = latest[provider], let newest = byWindow.values.map(\.t).max() else { return nil }
        // Only windows from the same reading (within 10 minutes of the newest).
        let keep = byWindow.values.filter { newest - $0.t < 600 }.sorted { ($0.w.count, $0.w) < ($1.w.count, $1.w) }
        let windows = keep.map { s in
            UsageWindow(label: s.w, usedPercent: s.u, resetsAt: s.r.map { Date(timeIntervalSince1970: $0) },
                        windowSeconds: s.w.hasPrefix("5H") ? 18000 : (s.w.hasPrefix("7D") ? 604800 : nil))
        }
        return (windows, Date(timeIntervalSince1970: newest))
    }

    private func remember(_ s: UsageSample, now: Date) {
        if (latest[s.p]?[s.w]?.t ?? 0) <= s.t { latest[s.p, default: [:]][s.w] = s }
        let key = "\(s.p)|\(s.w)"
        var list = recent[key, default: []]
        list.append(s)
        let cutoff = now.timeIntervalSince1970 - Self.keepInMemory
        list.removeAll { $0.t < cutoff }
        recent[key] = list
    }

    // MARK: Forecast

    func annotate(_ snaps: [ProviderSnapshot], now: Date = Date()) -> [ProviderSnapshot] {
        snaps.map { s in
            guard s.staleNote == nil, case .ok(let windows, let plan) = s.state else { return s }
            var copy = s
            copy.state = .ok(windows: windows.map { w in
                var w = w
                w.forecast = forecast(provider: s.id, window: w, now: now)
                return w
            }, plan: plan)
            return copy
        }
    }

    func forecast(provider: String, window w: UsageWindow, now: Date) -> Forecast? {
        guard w.gauged, w.usedPercent < 100, let all = recent["\(provider)|\(w.label)"] else { return nil }
        let nowT = now.timeIntervalSince1970
        let currentReset = w.resetsAt?.timeIntervalSince1970

        // Only samples from this window cycle: same reset time, and nothing before the last drop.
        var pts: [UsageSample] = []
        let long = (w.windowSeconds ?? 0) >= 86_400
        let lookback = long ? Self.longLookback : Self.lookback
        for s in all where s.t >= nowT - lookback && s.t <= nowT + 1 {
            if let a = s.r, let b = currentReset, abs(a - b) > 300 { continue }
            if let last = pts.last, s.u < last.u - 1 { pts = [] }
            pts.append(s)
        }
        guard pts.count >= 3, let first = pts.first, let last = pts.last,
              last.t - first.t >= (long ? Self.longMinSpan : Self.minSpan) else { return nil }

        // Least-squares slope, % per hour.
        let xs = pts.map { ($0.t - first.t) / 3600 }, ys = pts.map(\.u)
        let n = Double(pts.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
        guard den > 0 else { return nil }
        let rate = num / den
        guard rate >= Self.minRate else { return nil }

        let hits = now.addingTimeInterval((100 - w.usedPercent) / rate * 3600)
        var atReset: Double?
        var before = true
        if let r = w.resetsAt {
            before = hits < r
            atReset = min(100, w.usedPercent + rate * max(0, r.timeIntervalSince(now)) / 3600)
        }
        return Forecast(hitsLimitAt: hits, ratePerHour: rate, beforeReset: before, atReset: atReset)
    }

    // MARK: Disk

    private func load() {
        guard let data = try? Data(contentsOf: Self.file), !data.isEmpty else { return }
        let now = Date()
        let dec = JSONDecoder()
        var all: [UsageSample] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let s = try? dec.decode(UsageSample.self, from: Data(line)) { all.append(s) }
        }
        for s in all where (latest[s.p]?[s.w]?.t ?? 0) <= s.t { latest[s.p, default: [:]][s.w] = s }
        for s in all where s.t >= now.timeIntervalSince1970 - Self.keepInMemory { remember(s, now: now) }
        if data.count > Self.compactAbove {
            let keep = all.filter { $0.t >= now.timeIntervalSince1970 - Self.keepOnDisk }
            let enc = JSONEncoder()
            let out = keep.compactMap { try? enc.encode($0) }.reduce(into: Data()) { $0 += $1; $0.append(0x0A) }
            try? out.write(to: Self.file, options: .atomic)
        }
    }

    private func append(_ samples: [UsageSample]) {
        let fm = FileManager.default
        let url = Self.file
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        var blob = Data()
        for s in samples { if let d = try? enc.encode(s) { blob += d; blob.append(0x0A) } }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: blob)
    }
}
