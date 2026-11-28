import Foundation
import Security

/// The snapshot the phone is allowed to store. No paths, tokens, or prompts.
public struct PhoneSnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var generatedAt: String
    public var hostName: String
    public var rows: [PhoneRow]
    public init(version: Int = 1, generatedAt: String, hostName: String, rows: [PhoneRow]) {
        self.version = version
        self.generatedAt = generatedAt
        self.hostName = hostName
        self.rows = rows
    }
    public func json() -> Data { (try? JSONEncoder().encode(self)) ?? Data("{}".utf8) }
}

public struct PhoneRow: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var monogram: String
    public var color: String
    public var plan: String?
    public var status: String
    public var windows: [PhoneWindow]
    public init(id: String, name: String, monogram: String, color: String, plan: String?, status: String, windows: [PhoneWindow]) {
        self.id = id; self.name = name; self.monogram = monogram; self.color = color
        self.plan = plan; self.status = status; self.windows = windows
    }
}

public struct PhoneWindow: Codable, Equatable, Sendable {
    public var label: String
    public var usedPercent: Double
    public var kind: String
    public var resetsIn: String?
    public var forecastText: String?
    public var warns: Bool
    public var amount: String?
    public init(label: String, usedPercent: Double, kind: String, resetsIn: String? = nil,
                forecastText: String? = nil, warns: Bool = false, amount: String? = nil) {
        self.label = label; self.usedPercent = usedPercent; self.kind = kind
        self.resetsIn = resetsIn; self.forecastText = forecastText; self.warns = warns; self.amount = amount
    }
}

public struct SyncSession: Sendable {
    public var code: String
    public var codeUntil: TimeInterval
    public var tokens: Set<String>
    public init(code: String, codeUntil: TimeInterval, tokens: Set<String> = []) {
        self.code = code; self.codeUntil = codeUntil; self.tokens = tokens
    }
}

public struct RawHTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
}

public enum HTTPRead: Sendable {
    case needMore
    case bad
    case ready(RawHTTPRequest)
}

public enum PhoneSyncProtocol {
    public static let defaultPort: UInt16 = 47321
    public static let codeTTL: TimeInterval = 10 * 60
    public static let maxTokens = 8

    public static func pairLink(host: String, port: UInt16, code: String) -> String {
        "phosphor://pair?v=1&host=\(host)&port=\(port)&code=\(code)"
    }

    public static func read(_ data: Data) -> HTTPRead {
        if data.count > 65_536 { return .bad }
        guard let split = headerEnd(data) else { return .needMore }
        let head = data.subdata(in: 0..<split)
        let rest = data.subdata(in: (split + 4)..<data.count)
        guard let text = String(data: head, encoding: .utf8) else { return .bad }
        let lines = text.components(separatedBy: "\r\n")
        guard let start = lines.first else { return .bad }
        let headerLines = lines.dropFirst()
        let parts = start.split(separator: " ")
        guard parts.count >= 2 else { return .bad }
        let path = String(parts[1].split(separator: "?").first ?? parts[1])
        var headers: [String: String] = [:]
        for line in headerLines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let need = Int(headers["content-length"] ?? "") ?? 0
        if need > 65_536 { return .bad }
        if rest.count < need { return .needMore }
        return .ready(RawHTTPRequest(method: String(parts[0]), path: path,
                                     headers: headers, body: Data(rest.prefix(need))))
    }

    private static func headerEnd(_ data: Data) -> Int? {
        let n = data.count
        if n < 4 { return nil }
        let bytes = [UInt8](data)
        for i in 0...(n - 4) where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            return i
        }
        return nil
    }

    /// Same answers as the Rust server: health is public, the code works once, the snapshot needs the token.
    public static func handle(method: String, path: String, authorization: String?, body: Data,
                              now: TimeInterval, session: inout SyncSession,
                              snapshot: Data, issueToken: () -> String) -> (status: Int, json: Data) {
        switch (method, path) {
        case ("GET", "/v1/health"):
            return (200, Data(#"{"ok":true,"service":"phosphor"}"#.utf8))
        case ("POST", "/v1/pair"):
            return pair(body: body, now: now, session: &session, issueToken: issueToken)
        case ("GET", "/v1/snapshot"):
            guard let token = authorization.flatMap(bearer), session.tokens.contains(where: { ctEq($0, token) }) else {
                return (401, Data(#"{"error":"unauthorized"}"#.utf8))
            }
            return (200, snapshot)
        default:
            return (404, Data(#"{"error":"not_found"}"#.utf8))
        }
    }

    private static func pair(body: Data, now: TimeInterval, session: inout SyncSession, issueToken: () -> String) -> (Int, Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let code = obj["code"] as? String else {
            return (400, Data(#"{"error":"bad_code"}"#.utf8))
        }
        if session.code.isEmpty || now > session.codeUntil || !ctEq(code, session.code) {
            return (401, Data(#"{"error":"bad_code"}"#.utf8))
        }
        let token = issueToken()
        session.code = ""
        session.codeUntil = 0
        if session.tokens.count >= maxTokens, let old = session.tokens.first { session.tokens.remove(old) }
        session.tokens.insert(token)
        let json = #"{"token":"\#(token)"}"#
        return (200, Data(json.utf8))
    }

    private static func bearer(_ header: String) -> String? {
        guard header.hasPrefix("Bearer ") else { return nil }
        let token = header.dropFirst("Bearer ".count).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    private static func ctEq(_ a: String, _ b: String) -> Bool {
        guard a.utf8.count == b.utf8.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a.utf8, b.utf8) { diff |= x ^ y }
        return diff == 0
    }

    public static func randomCode() -> String {
        var n: UInt32 = 0
        for b in randomBytes(4) { n = (n << 8) | UInt32(b) }
        return String(format: "%06d", n % 1_000_000)
    }

    public static func randomToken() -> String {
        randomBytes(32).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &out)
        return out
    }
}
