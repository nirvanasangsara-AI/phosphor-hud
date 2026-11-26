import Foundation

/// When a reading copied from a billing screen can't be trusted any more.
public enum Staleness {
    public enum Reason: Sendable, Hashable {
        case billDatePassed(Date)
        case old(days: Int)
        case unknownAge
    }

    public static let maxAgeDays = 30

    public static func reasons(nextBill: Date?, checkedAt: Date?, now: Date = Date(), maxAgeDays: Int = maxAgeDays) -> [Reason] {
        var out: [Reason] = []
        if let nextBill, nextBill < now { out.append(.billDatePassed(nextBill)) }
        if let checkedAt {
            let days = Int(now.timeIntervalSince(checkedAt) / 86_400)
            if days > maxAgeDays { out.append(.old(days: days)) }
        } else {
            out.append(.unknownAge)
        }
        return out
    }

    public static func text(_ r: Reason) -> String {
        switch r {
        case .billDatePassed(let d):
            let f = DateFormatter(); f.dateFormat = "MMM d"; f.locale = Locale(identifier: "en_US_POSIX")
            return "next bill (\(f.string(from: d))) has passed"
        case .old(let days): return "read \(days) days ago"
        case .unknownAge: return "no check date"
        }
    }

    /// "Needs refresh: next bill (Nov 30) has passed · read 41 days ago", or nil when fresh.
    public static func summary(_ rs: [Reason]) -> String? {
        rs.isEmpty ? nil : "Needs refresh: " + rs.map(text).joined(separator: " · ")
    }
}

/// `~/.config/phosphor/events-export.json`: dates other apps (e.g. 일정) can show on a calendar.
public struct EventsExport: Codable, Sendable, Equatable {
    public struct Event: Codable, Sendable, Equatable {
        public var id: String
        public var kind: String         // "bill" | "credit-expiry"
        public var provider: String
        public var providerName: String
        public var title: String
        public var date: String         // ISO 8601 with offset
        public var allDay: Bool
        public var amount: String?
        public var source: String?      // where the value was read
        public var checkedAt: String?
        public var stale: Bool
    }
    public var version = 1
    public var generator = "Phosphor"
    public var generatedAt: String
    public var events: [Event]

    public static let fileName = "events-export.json"

    public struct Input: Sendable {
        public var provider: String
        public var providerName: String
        public var nextBill: Date?
        public var price: String?
        public var credits: [BillingReading.Credit]
        public var source: String?
        public var checkedAt: Date?
        public init(provider: String, providerName: String, nextBill: Date?, price: String?,
                    credits: [BillingReading.Credit], source: String?, checkedAt: Date?) {
            self.provider = provider; self.providerName = providerName; self.nextBill = nextBill; self.price = price
            self.credits = credits; self.source = source; self.checkedAt = checkedAt
        }
    }

    /// Upcoming bills and credit expiries only (past dates are dropped), soonest first.
    public static func build(_ inputs: [Input], now: Date = Date(), tz: TimeZone = .current) -> EventsExport {
        let f = ISO8601DateFormatter(); f.timeZone = tz
        f.formatOptions = [.withInternetDateTime]
        var events: [(Date, Event)] = []
        for i in inputs {
            let stale = !Staleness.reasons(nextBill: nil, checkedAt: i.checkedAt, now: now).isEmpty
            let checked = i.checkedAt.map(f.string)
            if let d = i.nextBill, d >= now.addingTimeInterval(-86_400) {
                events.append((d, Event(id: "phosphor.bill.\(i.provider).\(DayKey.of(d, in: tz))", kind: "bill",
                                        provider: i.provider, providerName: i.providerName,
                                        title: "\(i.providerName) renews" + (i.price.map { " · \($0)" } ?? ""),
                                        date: f.string(from: d), allDay: true, amount: i.price, source: i.source,
                                        checkedAt: checked, stale: stale)))
            }
            for c in i.credits where c.expires >= now {
                events.append((c.expires, Event(id: "phosphor.credit.\(i.provider).\(c.title).\(DayKey.of(c.expires, in: tz))",
                                                kind: "credit-expiry", provider: i.provider, providerName: i.providerName,
                                                title: "\(i.providerName): \(c.title)\(c.amount.map { " \($0)" } ?? "") expires",
                                                date: f.string(from: c.expires), allDay: false, amount: c.amount,
                                                source: i.source, checkedAt: checked, stale: stale)))
            }
        }
        return EventsExport(generatedAt: f.string(from: now),
                            events: events.sorted { ($0.0, $0.1.id) < ($1.0, $1.1.id) }.map(\.1))
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}
