import Foundation

/// Shared OAuth refresh helpers for Codex (`~/.codex/auth.json`) and Grok CLI (`~/.grok/auth.json`).
/// Pure JSON/date math lives here so it can be unit-tested without touching a keychain or the network.
public enum TokenRefresh {
    /// Official Codex CLI token endpoint (`codex-rs` `REFRESH_TOKEN_URL`).
    public static let codexURL = URL(string: "https://auth.openai.com/oauth/token")!
    /// Public Codex CLI OAuth client id, as used by the official CLI.
    public static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    /// Official xAI OIDC token endpoint (`https://auth.x.ai/.well-known/openid-configuration`).
    public static let grokURL = URL(string: "https://auth.x.ai/oauth2/token")!

    public static let defaultLeeway: TimeInterval = 5 * 60
    public static let permanentHold: TimeInterval = 6 * 3600

    public enum Kind: String, Codable, Sendable { case success, transient, permanent }

    /// Backoff so a revoked refresh token is not retried in a tight loop.
    public struct Cooldown: Codable, Equatable, Sendable {
        public var lastAttempt: Date?
        public var consecutiveFailures: Int
        public var permanentUntil: Date?

        public init(lastAttempt: Date? = nil, consecutiveFailures: Int = 0, permanentUntil: Date? = nil) {
            self.lastAttempt = lastAttempt
            self.consecutiveFailures = consecutiveFailures
            self.permanentUntil = permanentUntil
        }

        public func canAttempt(at now: Date = Date()) -> Bool {
            if let until = permanentUntil, now < until { return false }
            guard let last = lastAttempt else { return true }
            return now >= last.addingTimeInterval(Self.delay(after: consecutiveFailures))
        }

        /// After 0 failures: immediately; then 1 min, 5 min, 15 min, 1 hour.
        public static func delay(after failures: Int) -> TimeInterval {
            let table: [TimeInterval] = [0, 60, 300, 900, 3600]
            return table[min(max(0, failures), table.count - 1)]
        }

        public mutating func recordSuccess(at now: Date = Date()) {
            lastAttempt = now
            consecutiveFailures = 0
            permanentUntil = nil
        }

        public mutating func recordTransient(at now: Date = Date()) {
            lastAttempt = now
            consecutiveFailures += 1
        }

        public mutating func recordPermanent(at now: Date = Date(), hold: TimeInterval = TokenRefresh.permanentHold) {
            lastAttempt = now
            consecutiveFailures += 1
            permanentUntil = now.addingTimeInterval(hold)
        }
    }

    /// `exp` claim from an unsigned JWT payload. Returns nil when the string is not a JWT.
    public static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var mid = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - mid.count % 4) % 4
        mid += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: mid),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let exp: Double
        if let n = obj["exp"] as? NSNumber { exp = n.doubleValue }
        else if let s = obj["exp"] as? String, let n = Double(s) { exp = n }
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    public static func needsRefresh(expiry: Date?, now: Date = Date(), leeway: TimeInterval = defaultLeeway) -> Bool {
        guard let expiry else { return false }
        return expiry.timeIntervalSince(now) <= leeway
    }

    public static func classify(status: Int, body: String = "") -> Kind {
        if (200..<300).contains(status) { return .success }
        let lower = body.lowercased()
        let revoked = lower.contains("invalid_grant")
            || lower.contains("refresh_token_expired")
            || lower.contains("refresh_token_reused")
            || lower.contains("refresh_token_invalidated")
        if status == 401 || status == 403 { return .permanent }
        if status == 400, revoked { return .permanent }
        if revoked { return .permanent }
        return .transient
    }

    /// Merge a Codex `/oauth/token` JSON response into `auth.json`, keeping unknown fields.
    public static func applyingCodexRefresh(_ auth: [String: Any], response: [String: Any], at now: Date = Date()) -> [String: Any]? {
        guard let access = string(response["access_token"]), !access.isEmpty else { return nil }
        var auth = auth
        var tokens = auth["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = access
        if let id = string(response["id_token"]), !id.isEmpty { tokens["id_token"] = id }
        if let refresh = string(response["refresh_token"]), !refresh.isEmpty { tokens["refresh_token"] = refresh }
        auth["tokens"] = tokens
        auth["last_refresh"] = iso(now)
        return auth
    }

    /// Merge a Grok OIDC token response into the named entry of `auth.json`, keeping unknown fields.
    public static func applyingGrokRefresh(_ auth: [String: Any], entryKey: String, response: [String: Any], at now: Date = Date()) -> [String: Any]? {
        guard var entry = auth[entryKey] as? [String: Any] else { return nil }
        guard let access = string(response["access_token"]), !access.isEmpty else { return nil }
        entry["key"] = access
        if let refresh = string(response["refresh_token"]), !refresh.isEmpty { entry["refresh_token"] = refresh }
        let expires: Date
        if let seconds = number(response["expires_in"]), seconds > 0 {
            expires = now.addingTimeInterval(seconds)
        } else if let jwt = jwtExpiry(access) {
            expires = jwt
        } else {
            expires = now.addingTimeInterval(3600)
        }
        entry["expires_at"] = iso(expires, fractional: true)
        var auth = auth
        auth[entryKey] = entry
        return auth
    }

    /// First usable Grok OIDC entry (has a `key` and usually a `refresh_token`).
    public static func grokEntry(in auth: [String: Any]) -> (key: String, entry: [String: Any])? {
        for (k, v) in auth {
            guard let entry = v as? [String: Any], let token = string(entry["key"]), !token.isEmpty else { continue }
            return (k, entry)
        }
        return nil
    }

    /// Client id from the auth entry (`oidc_client_id`) or an `issuer::client_id` map key.
    /// Returns nil rather than inventing a client id when neither is present.
    public static func grokClientID(entryKey: String, entry: [String: Any]) -> String? {
        if let id = string(entry["oidc_client_id"]), !id.isEmpty { return id }
        if let r = entryKey.range(of: "::") {
            let id = String(entryKey[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !id.isEmpty { return id }
        }
        return nil
    }

    public static func codexAccessExpiry(_ auth: [String: Any]) -> Date? {
        let tokens = auth["tokens"] as? [String: Any] ?? [:]
        return string(tokens["access_token"]).flatMap(jwtExpiry)
    }

    public static func grokExpiry(_ entry: [String: Any]) -> Date? {
        if let s = string(entry["expires_at"]) { return parseISO(s) }
        return string(entry["key"]).flatMap(jwtExpiry)
    }

    public static func iso(_ date: Date, fractional: Bool = false) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return f.string(from: date)
    }

    public static func parseISO(_ s: String) -> Date? {
        let fFrac = ISO8601DateFormatter()
        fFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fFrac.date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        guard let r = s.range(of: #"\.\d+"#, options: .regularExpression) else { return nil }
        let digits = String(s[r]).dropFirst()
        var millis = s
        millis.replaceSubrange(r, with: ".\(digits.prefix(3))")
        if let d = fFrac.date(from: millis) { return d }
        var plain = s
        plain.removeSubrange(r)
        return f.date(from: plain)
    }

    public static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        return nil
    }

    public static func number(_ v: Any?) -> TimeInterval? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}
