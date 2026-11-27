import Foundation

/// One usage sample used to fit a burn-rate forecast (`t` is epoch seconds, `u` is used %).
public struct ForecastSample: Hashable, Sendable {
    public var t: TimeInterval
    public var u: Double
    public var r: TimeInterval?

    public init(t: TimeInterval, u: Double, r: TimeInterval? = nil) {
        self.t = t
        self.u = u
        self.r = r
    }
}

/// Burn-rate forecast for one quota window. Always produced for a gauged window so the HUD
/// can keep a status line on screen, even before a slope can be fitted.
public struct Forecast: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// Fitted slope at or above `QuotaForecast.minRate`.
        case rate
        /// Enough samples, but the slope is idle (below `minRate`).
        case steady
        /// Not enough samples or span yet to fit a slope (reset/drop, first reading).
        case measuring
        /// Usage is already at or above 100 %.
        case limitReached
        /// Placeholder row for a window that isn't running (e.g. Claude `five_hour` is null).
        case noSession
    }

    public var kind: Kind
    public var hitsLimitAt: Date?
    public var ratePerHour: Double
    public var beforeReset: Bool
    public var atReset: Double?
    public var resetsAt: Date?

    public init(kind: Kind, hitsLimitAt: Date? = nil, ratePerHour: Double = 0,
                beforeReset: Bool = false, atReset: Double? = nil, resetsAt: Date? = nil) {
        self.kind = kind
        self.hitsLimitAt = hitsLimitAt
        self.ratePerHour = ratePerHour
        self.beforeReset = beforeReset
        self.atReset = atReset
        self.resetsAt = resetsAt
    }

    /// True when a real fitted rate will hit 100 % before the window resets — used for warn colours
    /// and the combat-log "runs dry" line. Measuring / steady / cap / no-session never trip this.
    public var warnsBeforeReset: Bool {
        kind == .rate && beforeReset && hitsLimitAt != nil
    }
}

/// Pure slope math behind "+N%/h" and the run-out time, unit-tested in PhosphorCoreTests.
public enum QuotaForecast {
    public static let lookback: TimeInterval = 60 * 60
    public static let longLookback: TimeInterval = 6 * 3600
    /// Two samples this far apart are enough to show a rate immediately (one 10-minute poll is plenty).
    public static let minSpan: TimeInterval = 5 * 60
    public static let minRate = 0.25
    public static let minSamples = 2

    public static func make(usedPercent: Double, resetsAt: Date?, windowSeconds: TimeInterval?,
                            activeSession: Bool = true, samples: [ForecastSample],
                            now: Date) -> Forecast {
        if !activeSession {
            return Forecast(kind: .noSession, resetsAt: resetsAt)
        }
        if usedPercent >= 100 {
            return Forecast(kind: .limitReached, hitsLimitAt: now, atReset: 100, resetsAt: resetsAt)
        }

        let nowT = now.timeIntervalSince1970
        let currentReset = resetsAt?.timeIntervalSince1970
        let long = (windowSeconds ?? 0) >= 86_400
        let lookback = long ? Self.longLookback : Self.lookback

        var pts: [ForecastSample] = []
        for s in samples where s.t >= nowT - lookback && s.t <= nowT + 1 {
            if let a = s.r, let b = currentReset, abs(a - b) > 300 { continue }
            if let last = pts.last, s.u < last.u - 1 { pts = [] }
            pts.append(s)
        }

        guard pts.count >= Self.minSamples, let first = pts.first, let last = pts.last,
              last.t - first.t >= Self.minSpan else {
            return Forecast(kind: .measuring, atReset: resetsAt.map { _ in usedPercent }, resetsAt: resetsAt)
        }

        let xs = pts.map { ($0.t - first.t) / 3600 }, ys = pts.map(\.u)
        let n = Double(pts.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
        let rate = den > 0 ? num / den : 0

        guard rate >= Self.minRate else {
            return Forecast(kind: .steady, atReset: resetsAt.map { _ in usedPercent }, resetsAt: resetsAt)
        }

        let hits = now.addingTimeInterval((100 - usedPercent) / rate * 3600)
        var atReset: Double?
        var before = true
        if let r = resetsAt {
            before = hits < r
            atReset = min(100, usedPercent + rate * max(0, r.timeIntervalSince(now)) / 3600)
        }
        return Forecast(kind: .rate, hitsLimitAt: hits, ratePerHour: rate,
                        beforeReset: before, atReset: atReset, resetsAt: resetsAt)
    }
}
