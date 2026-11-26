import Foundation

public struct AlertSettings: Codable, Sendable, Hashable {
    public var warnEnabled = true
    public var warnAt = 70.0            // percent used
    public var criticalEnabled = true
    public var criticalAt = 90.0
    public var resetEnabled = true
    /// Only say a window reset if it had reached this much (a reset from 3 % is not news).
    public var resetFrom = 50.0
    public var billEnabled = true
    public var billDaysBefore = 1
    public var creditEnabled = true
    public var creditDaysBefore = 3
    public init() {}

    public static let file = "alerts.json"

    /// Missing keys keep their defaults, so an old or hand-written file still loads.
    public static func decode(_ data: Data) -> AlertSettings {
        var s = AlertSettings()
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return s }
        func b(_ k: String, _ v: inout Bool) { if let x = o[k] as? Bool { v = x } }
        func d(_ k: String, _ v: inout Double) { if let x = (o[k] as? NSNumber)?.doubleValue { v = x } }
        func i(_ k: String, _ v: inout Int) { if let x = (o[k] as? NSNumber)?.intValue { v = x } }
        b("warnEnabled", &s.warnEnabled); d("warnAt", &s.warnAt)
        b("criticalEnabled", &s.criticalEnabled); d("criticalAt", &s.criticalAt)
        b("resetEnabled", &s.resetEnabled); d("resetFrom", &s.resetFrom)
        b("billEnabled", &s.billEnabled); i("billDaysBefore", &s.billDaysBefore)
        b("creditEnabled", &s.creditEnabled); i("creditDaysBefore", &s.creditDaysBefore)
        return s
    }
}

public struct QuotaReading: Sendable, Hashable, Codable {
    public var provider: String
    public var providerName: String
    public var window: String
    public var used: Double             // percent
    public var resetsAt: Date?
    public init(provider: String, providerName: String, window: String, used: Double, resetsAt: Date?) {
        self.provider = provider; self.providerName = providerName; self.window = window
        self.used = used; self.resetsAt = resetsAt
    }
    var key: String { "\(provider).\(window)" }
}

public struct BillingReading: Sendable, Hashable {
    public struct Credit: Sendable, Hashable {
        public var title: String; public var amount: String?; public var expires: Date
        public init(title: String, amount: String?, expires: Date) { self.title = title; self.amount = amount; self.expires = expires }
    }
    public var provider: String
    public var providerName: String
    public var nextBill: Date?
    public var price: String?
    public var credits: [Credit]
    public init(provider: String, providerName: String, nextBill: Date?, price: String? = nil, credits: [Credit] = []) {
        self.provider = provider; self.providerName = providerName; self.nextBill = nextBill
        self.price = price; self.credits = credits
    }
}

public struct UsageAlert: Sendable, Hashable {
    public enum Kind: String, Sendable { case warning, critical, reset, bill, creditExpiry }
    public var kind: Kind
    public var key: String
    public var title: String
    public var body: String
}

/// What has already been said, so each alert fires once. Persisted between launches.
public struct AlertMemory: Codable, Sendable {
    public var sent: [String: Date] = [:]
    public var last: [String: QuotaReading] = [:]
    public init() {}
}

public enum AlertEngine {
    static func bucket(_ d: Date?) -> String { d.map { String(Int($0.timeIntervalSince1970 / 3600)) } ?? "x" }

    public static func evaluate(quotas: [QuotaReading], bills: [BillingReading], settings s: AlertSettings,
                                memory: inout AlertMemory, now: Date = Date(), tz: TimeZone = .current) -> [UsageAlert] {
        var out: [UsageAlert] = []
        func fire(_ a: UsageAlert) {
            guard memory.sent[a.key] == nil else { return }
            memory.sent[a.key] = now
            out.append(a)
        }
        for q in quotas {
            let prev = memory.last[q.key]
            let cycle = bucket(q.resetsAt)
            let resetIn = q.resetsAt.map { " Resets in \(countdown($0, now))." } ?? ""
            if s.criticalEnabled, q.used >= s.criticalAt {
                fire(UsageAlert(kind: .critical, key: "crit.\(q.key).\(cycle)",
                           title: "\(q.providerName) \(q.window) at \(Int(q.used))%",
                           body: "Critical (≥\(Int(s.criticalAt))%).\(resetIn)"))
                memory.sent["warn.\(q.key).\(cycle)"] = memory.sent["warn.\(q.key).\(cycle)"] ?? now  // don't also warn
            } else if s.warnEnabled, q.used >= s.warnAt {
                fire(UsageAlert(kind: .warning, key: "warn.\(q.key).\(cycle)",
                           title: "\(q.providerName) \(q.window) at \(Int(q.used))%",
                           body: "Passed \(Int(s.warnAt))%.\(resetIn)"))
            }
            if s.resetEnabled, let p = prev, p.used >= s.resetFrom, q.used < p.used {
                let passedReset = p.resetsAt.map { now >= $0 } ?? false
                let bigDrop = p.used - q.used >= 40 && q.used <= 10
                if passedReset || bigDrop {
                    fire(UsageAlert(kind: .reset, key: "reset.\(q.key).\(bucket(p.resetsAt)).\(Int(p.used))",
                               title: "\(q.providerName) \(q.window) reset",
                               body: "Back to \(Int(q.used))% used (was \(Int(p.used))%)."))
                }
            }
            memory.last[q.key] = q
        }
        for b in bills {
            if s.billEnabled, let bill = b.nextBill {
                let left = bill.timeIntervalSince(now)
                if left > 0, left <= Double(s.billDaysBefore) * 86_400 {
                    fire(UsageAlert(kind: .bill, key: "bill.\(b.provider).\(DayKey.of(bill, in: tz))",
                               title: "\(b.providerName) bills \(relativeDay(bill, now, tz))",
                               body: b.price.map { "Renews at \($0)." } ?? "Subscription renews."))
                }
            }
            guard s.creditEnabled else { continue }
            for c in b.credits {
                let left = c.expires.timeIntervalSince(now)
                if left > 0, left <= Double(s.creditDaysBefore) * 86_400 {
                    fire(UsageAlert(kind: .creditExpiry, key: "credit.\(b.provider).\(c.title).\(DayKey.of(c.expires, in: tz))",
                               title: "\(b.providerName): \(c.title)\(c.amount.map { " \($0)" } ?? "") expires \(relativeDay(c.expires, now, tz))",
                               body: "Use it before \(countdown(c.expires, now)) runs out."))
                }
            }
        }
        let horizon = now.addingTimeInterval(-40 * 86_400)
        memory.sent = memory.sent.filter { $0.value >= horizon }
        return out
    }

    static func countdown(_ d: Date, _ now: Date) -> String {
        let s = max(0, Int(d.timeIntervalSince(now)))
        let days = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if days > 0 { return "\(days)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func relativeDay(_ d: Date, _ now: Date, _ tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        default: return "in \(days) days"
        }
    }
}
