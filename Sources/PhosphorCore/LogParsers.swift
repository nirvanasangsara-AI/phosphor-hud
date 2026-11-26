import Foundation

/// Turns one decoded log record into usage. Parsers read only usage fields; message text is never kept.
public enum LogParsers {

    // MARK: Claude Code — ~/.claude/projects/**/*.jsonl

    public static func claude(_ obj: [String: Any]) -> UsageEvent? {
        guard let msg = obj.dict("message"), let u = msg.dict("usage"),
              let ts = obj["timestamp"] as? String, let date = ISO.parse(ts) else { return nil }
        let model = (msg["model"] as? String) ?? "unknown"
        if model == "<synthetic>" { return nil }
        let usage = TokenUsage(input: u.int("input_tokens"), output: u.int("output_tokens"),
                               cacheRead: u.int("cache_read_input_tokens"),
                               cacheWrite: u.int("cache_creation_input_tokens"))
        if usage.isZero { return nil }
        var key: String?
        if let id = msg["id"] as? String { key = "claude:\(id):\((obj["requestId"] as? String) ?? "")" }
        return UsageEvent(source: "claude", model: model, date: date, usage: usage, dedupeKey: key)
    }

    // MARK: Codex — ~/.codex/sessions/**/*.jsonl (cumulative counters per session file)

    public struct CodexCounters: Codable, Sendable, Hashable {
        public var input = 0, cached = 0, cacheWrite = 0, output = 0
        init(_ d: [String: Any]) {
            input = d.int("input_tokens"); cached = d.int("cached_input_tokens")
            cacheWrite = d.int("cache_write_input_tokens"); output = d.int("output_tokens")
        }
        public init() {}
        func minus(_ o: CodexCounters) -> CodexCounters? {
            var r = CodexCounters()
            r.input = input - o.input; r.cached = cached - o.cached
            r.cacheWrite = cacheWrite - o.cacheWrite; r.output = output - o.output
            return (r.input < 0 || r.cached < 0 || r.cacheWrite < 0 || r.output < 0) ? nil : r
        }
        /// OpenAI counts cached tokens inside input_tokens, and reasoning inside output_tokens.
        var usage: TokenUsage {
            TokenUsage(input: max(0, input - cached), output: output, cacheRead: cached, cacheWrite: cacheWrite)
        }
    }

    public struct CodexState: Codable, Sendable, Hashable {
        public var model: String?
        public var last: CodexCounters?
        public init() {}
    }

    public static func codex(_ obj: [String: Any], state: inout CodexState) -> UsageEvent? {
        guard let type = obj["type"] as? String, let payload = obj.dict("payload") else { return nil }
        if type == "turn_context" {
            if let m = payload["model"] as? String { state.model = m }
            return nil
        }
        guard type == "event_msg", payload["type"] as? String == "token_count",
              let info = payload.dict("info"), let total = info.dict("total_token_usage"),
              let ts = obj["timestamp"] as? String, let date = ISO.parse(ts) else { return nil }
        let now = CodexCounters(total)
        var delta: CodexCounters
        if let last = state.last {
            if let d = now.minus(last) { delta = d }
            else if let l = info.dict("last_token_usage") { delta = CodexCounters(l) }   // counter reset
            else { delta = CodexCounters() }
        } else {
            delta = now
        }
        state.last = now
        let usage = delta.usage
        if usage.isZero { return nil }
        return UsageEvent(source: "codex", model: state.model ?? "unknown", date: date, usage: usage)
    }

    // MARK: Gemini CLI — ~/.gemini/tmp/<project>/chats/session-*.jsonl (or legacy .json)

    public static func gemini(_ obj: [String: Any]) -> UsageEvent? {
        guard obj["type"] as? String == "gemini", let t = obj.dict("tokens"),
              let ts = obj["timestamp"] as? String, let date = ISO.parse(ts) else { return nil }
        let cached = t.int("cached")
        // Gemini's prompt count includes cached tokens; thinking tokens bill as output.
        let usage = TokenUsage(input: max(0, t.int("input") - cached), output: t.int("output") + t.int("thoughts"),
                               cacheRead: cached)
        if usage.isZero { return nil }
        let key = (obj["id"] as? String).map { "gemini:\($0)" }
        return UsageEvent(source: "gemini", model: (obj["model"] as? String) ?? "gemini", date: date,
                          usage: usage, dedupeKey: key)
    }

    // MARK: Cline / Roo Code — globalStorage/<ext>/tasks/<id>/ui_messages.json

    public static func clineTask(_ messages: [[String: Any]], source: String, taskID: String) -> [UsageEvent] {
        messages.compactMap { m in
            guard m["say"] as? String == "api_req_started", let text = m["text"] as? String,
                  let ts = (m["ts"] as? NSNumber)?.doubleValue,
                  let data = text.data(using: .utf8),
                  let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            let cost = (info["cost"] as? NSNumber)?.doubleValue
            let usage = TokenUsage(input: info.int("tokensIn"), output: info.int("tokensOut"),
                                   cacheRead: info.int("cacheReads"), cacheWrite: info.int("cacheWrites"),
                                   loggedCost: cost)
            if usage.isZero { return nil }
            return UsageEvent(source: source, model: (info["model"] as? String) ?? "\(source) (logged cost)",
                              date: Date(timeIntervalSince1970: ts / 1000), usage: usage,
                              dedupeKey: "\(source):\(taskID):\(Int64(ts))")
        }
    }
}
