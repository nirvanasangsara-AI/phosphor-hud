import Foundation

/// Token counts normalised across tools. `input` never includes cached tokens.
public struct TokenUsage: Codable, Sendable, Hashable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    /// Cost the tool itself logged (Cline/Roo), in USD; when present it wins over the price table.
    public var loggedCost: Double?

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, loggedCost: Double? = nil) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.loggedCost = loggedCost
    }

    public var total: Int { input + output + cacheRead + cacheWrite }
    public var isZero: Bool { total == 0 && (loggedCost ?? 0) == 0 }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        let cost: Double? = (a.loggedCost == nil && b.loggedCost == nil) ? nil : (a.loggedCost ?? 0) + (b.loggedCost ?? 0)
        return TokenUsage(input: a.input + b.input, output: a.output + b.output,
                          cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite, loggedCost: cost)
    }
    public static func += (a: inout TokenUsage, b: TokenUsage) { a = a + b }
}

/// One usage record pulled from a log line.
public struct UsageEvent: Sendable, Hashable {
    public var source: String       // provider id: claude, codex, gemini, cline, roo
    public var model: String
    public var date: Date
    public var usage: TokenUsage
    /// Stable id for de-duplication across resumed sessions (nil = never duplicated).
    public var dedupeKey: String?
    public init(source: String, model: String, date: Date, usage: TokenUsage, dedupeKey: String? = nil) {
        self.source = source; self.model = model; self.date = date; self.usage = usage; self.dedupeKey = dedupeKey
    }
}

public enum DayKey {
    /// "yyyy-MM-dd" in the given time zone (the Mac's own by default).
    public static func of(_ date: Date, in tz: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    public static func date(_ key: String, in tz: TimeZone = .current) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

enum ISO {
    nonisolated(unsafe) static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) static let plain = ISO8601DateFormatter()
    static let lock = NSLock()
    static func parse(_ s: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return frac.date(from: s) ?? plain.date(from: s)
    }
}

extension Dictionary where Key == String, Value == Any {
    func int(_ k: String) -> Int {
        if let n = self[k] as? NSNumber { return n.intValue }
        return 0
    }
    func dict(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
}
