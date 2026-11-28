import Foundation
import Testing
@testable import PhosphorCore

@Suite struct ResetFeedTests {
    private func item(_ id: String, kind: ResetFeed.Item.Kind, official: Bool, posted: Date, expires: Date?) -> ResetFeed.Item {
        ResetFeed.Item(id: id, source: kind == .status ? "status" : "x", handle: "someone",
                       text: id, url: "https://example.com/\(id)", postedAt: posted, kind: kind,
                       expiresAt: expires, official: official, product: "claude")
    }

    @Test func parsesTheWorkerFeed() throws {
        let json = """
        {"generated_at":"2026-11-28T00:00:00Z","items":[
          {"id":"x:1","source":"x","handle":"Tibo","text":"Codex limits reset early","url":"https://x.com/Tibo/status/1",
           "posted_at":"2026-11-28T01:00:00Z","kind":"official","expected_reset_at":"2026-11-28T08:00:00Z",
           "expires_at":"2026-11-28T14:00:00Z","confidence":0.9,"official":true,"product":"codex"},
          {"id":"x:2","source":"x","handle":"someone","text":"Claude free reset maybe","url":"https://x.com/someone/status/2",
           "posted_at":"2026-11-28T02:00:00Z","kind":"rumor","expires_at":"2026-11-29T02:00:00Z","confidence":0.3,"official":false,"product":"claude"}
        ]}
        """.data(using: .utf8)!
        let now = ISO8601DateFormatter().date(from: "2026-11-28T03:00:00Z")!
        let items = try ResetFeed.parse(json: json, now: now)
        #expect(items.map(\.id) == ["x:1", "x:2"])
        #expect(items[0].handle == "Tibo")
        #expect(items[0].kind == .official)
        #expect(items[0].expectedResetAt == ISO8601DateFormatter().date(from: "2026-11-28T08:00:00Z"))
        #expect(items[1].isRumor)
    }

    @Test func dropsExpiredItemsAndKeepsOnesWithoutAnExpiry() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let live = item("live", kind: .official, official: true, posted: now, expires: now.addingTimeInterval(60))
        let dead = item("dead", kind: .rumor, official: false, posted: now, expires: now.addingTimeInterval(-1))
        let open = item("open", kind: .status, official: true, posted: now, expires: nil)
        let kept = ResetFeed.droppingExpired([live, dead, open], now: now).map(\.id)
        #expect(kept == ["live", "open"])
    }

    @Test func rumorsCanBeHiddenAndOfficialItemsStayFirst() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let official = item("official", kind: .official, official: true, posted: now.addingTimeInterval(-20), expires: nil)
        let status = item("status", kind: .status, official: true, posted: now.addingTimeInterval(-50), expires: nil)
        let rumor = item("rumor", kind: .rumor, official: false, posted: now, expires: nil)
        let all = ResetFeed.filtered([rumor, status, official], includeRumors: true)
        #expect(all.map(\.id) == ["official", "status", "rumor"])
        let quiet = ResetFeed.filtered([rumor, status, official], includeRumors: false)
        #expect(quiet.map(\.id) == ["official", "status"])
        let stale = item("stale", kind: .official, official: true, posted: now.addingTimeInterval(-100),
                         expires: now.addingTimeInterval(-5))
        let shown = ResetFeed.display([stale, rumor, official], includeRumors: true, now: now)
        #expect(shown.map(\.id) == ["official", "rumor"])
    }

    @Test func statusRSSBecomesTickerItems() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0"><channel>
          <item>
            <title><![CDATA[Elevated errors with Codex]]></title>
            <link>https://status.openai.com/incidents/abc</link>
            <guid>abc</guid>
            <pubDate>Thu, 26 Nov 2026 14:07:54 GMT</pubDate>
            <description><![CDATA[<b>Status: Resolved</b>]]></description>
          </item>
        </channel></rss>
        """.data(using: .utf8)!
        let source = URL(string: "https://status.openai.com/history.rss")!
        let items = ResetFeed.parseRSS(xml, source: source)
        #expect(items.count == 1)
        #expect(items[0].text == "Elevated errors with Codex")
        #expect(items[0].url == "https://status.openai.com/incidents/abc")
        #expect(items[0].kind == .status)
        #expect(items[0].official)
        #expect(items[0].product == "codex")
        #expect(items[0].handle == "OpenAI")
        let posted = ResetFeed.parseDate("Thu, 26 Nov 2026 14:07:54 GMT")
        #expect(items[0].postedAt == posted)
        let merged = ResetFeed.mergeStatus([items, items], now: posted ?? Date())
        #expect(merged.count == 1)
    }
}
