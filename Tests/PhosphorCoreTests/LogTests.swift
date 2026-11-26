import Testing
import Foundation
@testable import PhosphorCore

private func obj(_ s: String) -> [String: Any] {
    (try! JSONSerialization.jsonObject(with: Data(s.utf8))) as! [String: Any]
}

@Suite struct LogParserTests {
    @Test func claudeLine() throws {
        let e = try #require(LogParsers.claude(obj("""
        {"type":"assistant","timestamp":"2026-11-25T03:00:00.000Z","requestId":"req_1",
         "message":{"id":"msg_1","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":20,
         "cache_read_input_tokens":300,"cache_creation_input_tokens":40}}}
        """)))
        #expect(e.usage == TokenUsage(input: 10, output: 20, cacheRead: 300, cacheWrite: 40))
        #expect(e.model == "claude-sonnet-5")
        #expect(e.dedupeKey == "claude:msg_1:req_1")
    }

    @Test func claudeSkipsSyntheticAndEmpty() {
        #expect(LogParsers.claude(obj(#"{"timestamp":"2026-11-25T03:00:00Z","message":{"model":"<synthetic>","usage":{"input_tokens":5}}}"#)) == nil)
        #expect(LogParsers.claude(obj(#"{"timestamp":"2026-11-25T03:00:00Z","message":{"model":"m","usage":{}}}"#)) == nil)
        #expect(LogParsers.claude(obj(#"{"type":"user","message":{"content":"hi"}}"#)) == nil)
    }

    @Test func codexCumulativeDeltas() throws {
        var st = LogParsers.CodexState()
        #expect(LogParsers.codex(obj(#"{"type":"turn_context","payload":{"model":"gpt-6-astra"}}"#), state: &st) == nil)
        func tc(_ i: Int, _ c: Int, _ o: Int) -> [String: Any] {
            obj(#"{"timestamp":"2026-11-25T03:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(i),"cached_input_tokens":\#(c),"output_tokens":\#(o)}}}}"#)
        }
        let a = try #require(LogParsers.codex(tc(1000, 400, 50), state: &st))
        #expect(a.usage == TokenUsage(input: 600, output: 50, cacheRead: 400))
        #expect(a.model == "gpt-6-astra")
        let b = try #require(LogParsers.codex(tc(1500, 900, 80), state: &st))
        #expect(b.usage == TokenUsage(input: 0, output: 30, cacheRead: 500))
        // Same totals again (a repeated event) adds nothing.
        #expect(LogParsers.codex(tc(1500, 900, 80), state: &st) == nil)
    }

    @Test func codexNullInfoIgnored() {
        var st = LogParsers.CodexState()
        #expect(LogParsers.codex(obj(#"{"timestamp":"2026-11-25T03:00:00Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#), state: &st) == nil)
    }

    @Test func geminiLine() throws {
        let e = try #require(LogParsers.gemini(obj(#"{"id":"g1","timestamp":"2026-11-25T03:00:00Z","type":"gemini","model":"gemini-3-pro","tokens":{"input":1000,"output":100,"cached":600,"thoughts":50,"tool":0,"total":1150}}"#)))
        #expect(e.usage == TokenUsage(input: 400, output: 150, cacheRead: 600))
        #expect(LogParsers.gemini(obj(#"{"id":"u","timestamp":"2026-11-25T03:00:00Z","type":"user","content":"x"}"#)) == nil)
    }

    @Test func clineTask() {
        let msgs: [[String: Any]] = [
            ["ts": 1764039600000, "type": "say", "say": "api_req_started",
             "text": #"{"tokensIn":12,"tokensOut":34,"cacheWrites":5,"cacheReads":6,"cost":0.0123}"#],
            ["ts": 1764039601000, "type": "say", "say": "text", "text": "hello"],
        ]
        let ev = LogParsers.clineTask(msgs, source: "cline", taskID: "t1")
        #expect(ev.count == 1)
        #expect(ev[0].usage.loggedCost == 0.0123)
        #expect(ev[0].dedupeKey == "cline:t1:1764039600000")
    }
}

@Suite struct ScannerTests {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("phosphor-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func matchingLinesKeepsOrderAndSkipsOthers() {
        let buf = Data("a token_count 1\nnoise\nb turn_context\nc token_count 2\n".utf8)
        let lines = LogScanner.matchingLines(buf, needles: [Array("turn_context".utf8), Array("token_count".utf8)])
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["a token_count 1", "b turn_context", "c token_count 2"])
    }

    @Test func incrementalScanCountsOnceAndDedupes() throws {
        let dir = tempDir()
        let f1 = dir.appendingPathComponent("a.jsonl"), f2 = dir.appendingPathComponent("b.jsonl")
        let now = ISO.parse("2026-11-26T00:00:00Z")!
        let line = #"{"timestamp":"2026-11-25T03:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":20}}}"#
        try (line + "\n").write(to: f1, atomically: true, encoding: .utf8)
        try (line + "\n").write(to: f2, atomically: true, encoding: .utf8)   // resumed session repeats it
        let src = LogSource(id: "claude", format: .claude, roots: [dir.path], needles: ["\"usage\""], fileSuffix: ".jsonl")
        let utc = TimeZone(identifier: "UTC")!
        let scanner = LogScanner(sources: [src], windowDays: 3650, tz: utc)
        var ledger = UsageLedger()
        scanner.scan(&ledger, now: now)
        #expect(ledger.days["2026-11-25"]?["claude|claude-sonnet-5"] == TokenUsage(input: 10, output: 20))

        // Appending a new line (plus a half-written one) only reads the new complete line.
        let h = try FileHandle(forWritingTo: f1); try h.seekToEnd()
        try h.write(contentsOf: Data((#"{"timestamp":"2026-11-25T04:00:00Z","requestId":"r2","message":{"id":"m2","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":2}}}"# + "\n" + #"{"timestamp":"#).utf8))
        try h.close()
        scanner.scan(&ledger, now: now)
        #expect(ledger.days["2026-11-25"]?["claude|claude-sonnet-5"] == TokenUsage(input: 11, output: 22))
        scanner.scan(&ledger, now: now)
        #expect(ledger.days["2026-11-25"]?["claude|claude-sonnet-5"] == TokenUsage(input: 11, output: 22))
    }

    @Test func firstScanOnlyReachesBackInitialDays() throws {
        let dir = tempDir()
        let now = ISO.parse("2026-11-26T00:00:00Z")!
        let f = dir.appendingPathComponent("a.jsonl")
        let old = #"{"timestamp":"2026-11-10T03:00:00Z","requestId":"r0","message":{"id":"m0","model":"x","usage":{"input_tokens":100}}}"#
        let new = #"{"timestamp":"2026-11-24T03:00:00Z","requestId":"r1","message":{"id":"m1","model":"x","usage":{"input_tokens":7}}}"#
        try (old + "\n" + new + "\n").write(to: f, atomically: true, encoding: .utf8)
        let src = LogSource(id: "claude", format: .claude, roots: [dir.path], needles: ["\"usage\""], fileSuffix: ".jsonl")
        var ledger = UsageLedger()
        LogScanner(sources: [src], windowDays: 35, initialDays: 7, tz: TimeZone(identifier: "UTC")!).scan(&ledger, now: now)
        #expect(ledger.days.keys.sorted() == ["2026-11-24"])
        #expect(ledger.since == now.addingTimeInterval(-7 * 86_400))
    }

    @Test func ledgerSurvivesCoding() throws {
        var l = UsageLedger(); var seen = Set<UInt64>()
        l.add(UsageEvent(source: "codex", model: "gpt-6-astra", date: Date(), usage: TokenUsage(input: 5)), seenSet: &seen)
        let back = try JSONDecoder().decode(UsageLedger.self, from: JSONEncoder().encode(l))
        #expect(back.days == l.days)
    }

    @Test func summariesAndCost() {
        var l = UsageLedger(); var seen = Set<UInt64>()
        let utc = TimeZone(identifier: "UTC")!
        let now = ISO.parse("2026-11-26T12:00:00Z")!
        l.add(UsageEvent(source: "claude", model: "m", date: now, usage: TokenUsage(input: 1_000_000)), tz: utc, seenSet: &seen)
        l.add(UsageEvent(source: "codex", model: "unpriced", date: now.addingTimeInterval(-3 * 86_400), usage: TokenUsage(output: 500)), tz: utc, seenSet: &seen)
        l.add(UsageEvent(source: "codex", model: "m", date: now.addingTimeInterval(-20 * 86_400), usage: TokenUsage(output: 10)), tz: utc, seenSet: &seen)
        let prices = PriceTable(prices: ["m": ModelPrice(input: 3e-6, output: 1.5e-5)])
        let today = l.summary(lastDays: 1, prices: prices, now: now, tz: utc)
        #expect(today.tokens == 1_000_000)
        #expect(abs(today.cost - 3.0) < 1e-9)
        let week = l.summary(lastDays: 7, prices: prices, now: now, tz: utc)
        #expect(week.tokens == 1_000_500 && week.unpricedTokens == 500)
        let month = l.summary(lastDays: 30, source: "codex", prices: prices, now: now, tz: utc)
        #expect(month.tokens == 510)
    }
}

@Suite struct PricingTests {
    let table = try! PriceTable(litellmJSON: Data("""
    {"sample_spec":{"input_cost_per_token":0},
     "claude-sonnet-5":{"input_cost_per_token":3e-06,"output_cost_per_token":1.5e-05,"cache_read_input_token_cost":3e-07,"cache_creation_input_token_cost":3.75e-06},
     "gpt-6-astra":{"input_cost_per_token":1e-05,"output_cost_per_token":5e-05},
     "gemini/gemini-3-pro":{"input_cost_per_token":2e-06,"output_cost_per_token":1.2e-05},
     "embedding-only":{"input_cost_per_token":1e-07}}
    """.utf8))

    @Test func parsesOnlyPricedChatModels() {
        #expect(table.prices.count == 3)
        #expect(table.prices["sample_spec"] == nil)
    }

    @Test func lookupNormalises() {
        #expect(table.price(for: "claude-sonnet-5-20261001") != nil)
        #expect(table.price(for: "anthropic/claude-sonnet-5") != nil)
        #expect(table.price(for: "claude-sonnet-5[1m]") != nil)
        #expect(table.price(for: "gemini-3-pro") != nil)
        #expect(table.price(for: "mystery-model") == nil)
    }

    @Test func costUsesCacheRatesAndLoggedCost() throws {
        let c = try #require(table.cost(TokenUsage(input: 1000, output: 1000, cacheRead: 10000, cacheWrite: 1000), model: "claude-sonnet-5"))
        #expect(abs(c - (0.003 + 0.015 + 0.003 + 0.00375)) < 1e-12)
        // No cache rates: falls back to the input rate.
        let g = try #require(table.cost(TokenUsage(cacheRead: 1000), model: "gpt-6-astra"))
        #expect(abs(g - 0.01) < 1e-12)
        #expect(table.cost(TokenUsage(input: 5, loggedCost: 0.5), model: "mystery") == 0.5)
        #expect(table.cost(TokenUsage(input: 5), model: "mystery") == nil)
    }
}
