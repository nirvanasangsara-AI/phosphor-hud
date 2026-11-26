import Testing
import Foundation
@testable import PhosphorCore

@Suite struct AlertTests {
    let now = ISO.parse("2026-11-26T03:00:00Z")!
    let utc = TimeZone(identifier: "UTC")!
    func q(_ used: Double, reset: TimeInterval = 7200) -> QuotaReading {
        QuotaReading(provider: "claude", providerName: "Claude Code", window: "5H", used: used, resetsAt: now.addingTimeInterval(reset))
    }

    @Test func warnThenCriticalOncePerCycle() {
        var m = AlertMemory(); let s = AlertSettings()
        #expect(AlertEngine.evaluate(quotas: [q(50)], bills: [], settings: s, memory: &m, now: now, tz: utc).isEmpty)
        let w = AlertEngine.evaluate(quotas: [q(72)], bills: [], settings: s, memory: &m, now: now, tz: utc)
        #expect(w.map(\.kind) == [.warning])
        #expect(AlertEngine.evaluate(quotas: [q(75)], bills: [], settings: s, memory: &m, now: now, tz: utc).isEmpty)
        let c = AlertEngine.evaluate(quotas: [q(91)], bills: [], settings: s, memory: &m, now: now, tz: utc)
        #expect(c.map(\.kind) == [.critical])
        #expect(AlertEngine.evaluate(quotas: [q(95)], bills: [], settings: s, memory: &m, now: now, tz: utc).isEmpty)
    }

    @Test func jumpStraightToCriticalSkipsWarning() {
        var m = AlertMemory()
        let a = AlertEngine.evaluate(quotas: [q(93)], bills: [], settings: AlertSettings(), memory: &m, now: now, tz: utc)
        #expect(a.map(\.kind) == [.critical])
        #expect(AlertEngine.evaluate(quotas: [q(93)], bills: [], settings: AlertSettings(), memory: &m, now: now, tz: utc).isEmpty)
    }

    @Test func thresholdsAndSwitchesAreConfigurable() {
        var s = AlertSettings(); s.warnAt = 50; s.criticalEnabled = false
        var m = AlertMemory()
        let a = AlertEngine.evaluate(quotas: [q(95)], bills: [], settings: s, memory: &m, now: now, tz: utc)
        #expect(a.map(\.kind) == [.warning])
    }

    @Test func resetDetected() {
        var m = AlertMemory(); let s = AlertSettings()
        _ = AlertEngine.evaluate(quotas: [q(80, reset: -60)], bills: [], settings: s, memory: &m, now: now, tz: utc)
        let r = AlertEngine.evaluate(quotas: [q(2, reset: 18000)], bills: [], settings: s, memory: &m, now: now, tz: utc)
        #expect(r.map(\.kind) == [.reset])
        // Small windows that reset from low usage stay quiet.
        var m2 = AlertMemory()
        _ = AlertEngine.evaluate(quotas: [q(20, reset: -60)], bills: [], settings: s, memory: &m2, now: now, tz: utc)
        #expect(AlertEngine.evaluate(quotas: [q(0)], bills: [], settings: s, memory: &m2, now: now, tz: utc).isEmpty)
    }

    @Test func billAndCreditLeadTimes() {
        var m = AlertMemory(); let s = AlertSettings()
        let bills = [BillingReading(provider: "claude", providerName: "Claude", nextBill: now.addingTimeInterval(22 * 3600),
                                    price: "$30",
                                    credits: [.init(title: "Limit reset", amount: "×2", expires: now.addingTimeInterval(2 * 86_400)),
                                              .init(title: "Far", amount: nil, expires: now.addingTimeInterval(30 * 86_400))]),
                     BillingReading(provider: "grok", providerName: "Grok", nextBill: now.addingTimeInterval(5 * 86_400))]
        let a = AlertEngine.evaluate(quotas: [], bills: bills, settings: s, memory: &m, now: now, tz: utc)
        #expect(a.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.bill, .creditExpiry])
        #expect(a.first { $0.kind == .bill }?.title == "Claude bills tomorrow")
        #expect(AlertEngine.evaluate(quotas: [], bills: bills, settings: s, memory: &m, now: now, tz: utc).isEmpty)
    }

    @Test func settingsDecodeKeepsDefaults() {
        let s = AlertSettings.decode(Data(#"{"warnAt":60,"billEnabled":false}"#.utf8))
        #expect(s.warnAt == 60 && !s.billEnabled && s.criticalAt == 90 && s.creditDaysBefore == 3)
    }
}

@Suite struct BillingTests {
    let now = ISO.parse("2026-12-05T00:00:00Z")!

    @Test func staleWhenBillPassedOrOld() {
        let passed = Staleness.reasons(nextBill: ISO.parse("2026-11-30T00:00:00Z"), checkedAt: ISO.parse("2026-11-26T00:00:00Z"), now: now)
        #expect(passed.count == 1)
        let old = Staleness.reasons(nextBill: ISO.parse("2027-01-30T00:00:00Z"), checkedAt: ISO.parse("2026-10-01T00:00:00Z"), now: now)
        #expect(old == [.old(days: 65)])
        #expect(Staleness.reasons(nextBill: ISO.parse("2026-12-15T00:00:00Z"), checkedAt: ISO.parse("2026-11-26T00:00:00Z"), now: now).isEmpty)
        #expect(Staleness.summary(old) == "Needs refresh: read 65 days ago")
    }

    @Test func exportKeepsUpcomingSorted() throws {
        let tz = TimeZone(identifier: "Asia/Seoul")!
        let e = EventsExport.build([
            .init(provider: "grok", providerName: "Grok", nextBill: ISO.parse("2026-12-15T00:00:00+09:00"), price: "$30",
                  credits: [], source: "App Store", checkedAt: ISO.parse("2026-11-26T08:00:00+09:00")),
            .init(provider: "claude", providerName: "Claude", nextBill: ISO.parse("2026-11-30T00:00:00+09:00"), price: nil,
                  credits: [.init(title: "Fable reset", amount: "×2", expires: ISO.parse("2027-03-09T16:59:00+09:00")!)],
                  source: "claude.ai", checkedAt: ISO.parse("2026-11-26T08:00:00+09:00")),
        ], now: now, tz: tz)
        #expect(e.events.map(\.kind) == ["bill", "credit-expiry"])     // Claude's 11/30 bill has passed
        #expect(e.events[0].date == "2026-12-15T00:00:00+09:00")
        #expect(e.events[1].title == "Claude: Fable reset ×2 expires")
        let back = try JSONDecoder().decode(EventsExport.self, from: e.encoded())
        #expect(back == e)
    }
}

@Suite struct StatusTests {
    let summary = Data("""
    {"status":{"indicator":"minor"},
     "components":[{"name":"Claude Code","status":"operational"},{"name":"claude.ai","status":"degraded_performance"},
                   {"name":"Claude API (api.anthropic.com)","status":"partial_outage"}],
     "incidents":[{"name":"Elevated errors with Codex GitHub reviews","status":"investigating","impact":"minor","components":[]},
                  {"name":"Old","status":"resolved","impact":"major","components":[{"name":"Claude Code"}]}]}
    """.utf8)

    @Test func statuspageComponentsAndIncidents() throws {
        let f = try StatusFeeds.parseStatuspage(summary)
        #expect(f.components.count == 3)
        #expect(f.incidents.count == 1)
        #expect(StatusFeeds.health(for: StatusRef(.anthropic, components: ["Claude Code"]), in: f) == nil)
        let api = try #require(StatusFeeds.health(for: StatusRef(.anthropic, components: ["Claude API"]), in: f))
        #expect(api.level == .partialOutage)
        let codex = try #require(StatusFeeds.health(for: StatusRef(.openai, components: ["Codex"], incidentKeywords: ["Codex"]), in: f))
        #expect(codex.level == .degraded)
        #expect(codex.summary.contains("Codex GitHub"))
    }

    @Test func googleOpenIncidentsOnly() throws {
        let data = Data("""
        [{"external_desc":"Vertex Gemini API errors\\nmore","severity":"medium","affected_products":[{"title":"Vertex Gemini API"}]},
         {"external_desc":"Fixed","end":"2026-11-01T00:00:00Z","severity":"high","affected_products":[{"title":"Vertex Gemini API"}]},
         {"external_desc":"BigQuery slow","severity":"low","affected_products":[{"title":"BigQuery"}]}]
        """.utf8)
        let f = try StatusFeeds.parseGoogleCloud(data)
        #expect(f.incidents.count == 2)
        let h = try #require(StatusFeeds.health(for: StatusRef(.googleCloud, components: ["Gemini"]), in: f))
        #expect(h.level == .partialOutage && h.summary == "Vertex Gemini API errors")
    }
}

@Suite struct ProfileTests {
    @Test func parsesAndValidates() {
        let r = ProfilesConfig.parse(Data("""
        {"profiles":[{"provider":"codex","name":"Work","home":"~/.codex-work"},
                     {"provider":"claude","name":"side","configDir":"~/.claude-side"},
                     {"provider":"codex","name":"nohome"},
                     {"provider":"cursor","name":"x"},
                     {"provider":"codex","name":"work","home":"/x"}]}
        """.utf8), home: "/Users/t")
        #expect(r.profiles.map(\.id) == ["codex@work", "claude@side"])
        #expect(r.profiles[0].home == "/Users/t/.codex-work")
        #expect(r.problems.count == 3)
    }

    @Test func claudeKeychainNameFromConfigDir() {
        let p = Profile(provider: "claude", name: "a", configDir: "/Users/t/.claude-side")
        let s = p.claudeKeychainService ?? ""
        #expect(s.hasPrefix("Claude Code-credentials-") && s.count == "Claude Code-credentials-".count + 8)
        #expect(Profile(provider: "claude", name: "b", keychainService: "X").claudeKeychainService == "X")
    }
}
