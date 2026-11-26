import Foundation
import PhosphorCore

/// Refreshes Codex and Grok CLI access tokens through each tool's official OAuth endpoint
/// and writes the updated `auth.json` atomically, without dropping unknown fields.
/// Cooldown state is stored under Application Support and never includes tokens.
actor AuthRefresh {
    static let shared = AuthRefresh()

    struct Access: Sendable {
        var token: String
        var accountID: String?
    }

    private var cooldowns: [String: TokenRefresh.Cooldown] = [:]
    private let fileManager = FileManager.default
    private var loaded = false

    private var cooldownURL: URL {
        Paths.support.appendingPathComponent("auth-refresh.json")
    }

    func codexAccess(home: URL, force: Bool = false) async throws -> Access {
        try await token(for: .codex(home: home), force: force)
    }

    func grokAccess(file: URL, force: Bool = false) async throws -> Access {
        try await token(for: .grok(file: file), force: force)
    }

    private enum Target {
        case codex(home: URL)
        case grok(file: URL)

        var file: URL {
            switch self {
            case .codex(let home): return home.appendingPathComponent("auth.json")
            case .grok(let file): return file
            }
        }

        var cooldownKey: String {
            switch self {
            case .codex(let home): return "codex:\(home.path)"
            case .grok(let file): return "grok:\(file.path)"
            }
        }
    }

    private func token(for target: Target, force: Bool) async throws -> Access {
        try loadCooldowns()
        guard var auth = readJSONFile(target.file) else {
            throw ProviderError.notConfigured(missingMessage(target))
        }
        if !force, let access = currentAccess(target, auth: auth),
           !TokenRefresh.needsRefresh(expiry: expiry(target, auth: auth)) {
            return access
        }
        guard let refresh = refreshToken(target, auth: auth), !refresh.isEmpty else {
            if let access = currentAccess(target, auth: auth),
               !TokenRefresh.needsRefresh(expiry: expiry(target, auth: auth), leeway: 0) {
                return access
            }
            throw ProviderError.expired("login expired")
        }
        var cooldown = cooldowns[target.cooldownKey] ?? TokenRefresh.Cooldown()
        let now = Date()
        if !cooldown.canAttempt(at: now) {
            if let access = currentAccess(target, auth: auth),
               !TokenRefresh.needsRefresh(expiry: expiry(target, auth: auth), leeway: 0) {
                return access
            }
            throw ProviderError.expired("login expired")
        }

        // Reload immediately before the request so a concurrent official-CLI refresh wins the race.
        guard let fresh = readJSONFile(target.file) else {
            throw ProviderError.notConfigured(missingMessage(target))
        }
        auth = fresh
        guard let usedRefresh = refreshToken(target, auth: auth), !usedRefresh.isEmpty else {
            throw ProviderError.expired("login expired")
        }
        if !force, let access = currentAccess(target, auth: auth),
           !TokenRefresh.needsRefresh(expiry: expiry(target, auth: auth)) {
            return access
        }

        let (status, body) = try await post(target, auth: auth, refresh: usedRefresh)
        let text = String(decoding: body, as: UTF8.self)
        let kind = TokenRefresh.classify(status: status, body: text)
        switch kind {
        case .success:
            guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                cooldown.recordTransient(at: now)
                cooldowns[target.cooldownKey] = cooldown
                try persistCooldowns()
                throw ProviderError.parse("token refresh: not an object")
            }
            // If the official CLI rotated the refresh token while we were in flight, keep the disk file.
            if let disk = readJSONFile(target.file), refreshToken(target, auth: disk) != usedRefresh {
                cooldown.recordSuccess(at: Date())
                cooldowns[target.cooldownKey] = cooldown
                try persistCooldowns()
                if let access = currentAccess(target, auth: disk) { return access }
                throw ProviderError.expired("login expired")
            }
            guard let updated = apply(target, auth: auth, response: obj) else {
                cooldown.recordTransient(at: Date())
                cooldowns[target.cooldownKey] = cooldown
                try persistCooldowns()
                throw ProviderError.parse("token refresh: missing access_token")
            }
            try atomicWriteJSON(updated, to: target.file)
            cooldown.recordSuccess(at: Date())
            cooldowns[target.cooldownKey] = cooldown
            try persistCooldowns()
            guard let access = currentAccess(target, auth: updated) else {
                throw ProviderError.parse("token refresh: write succeeded but access token missing")
            }
            return access
        case .permanent:
            cooldown.recordPermanent(at: now)
            cooldowns[target.cooldownKey] = cooldown
            try persistCooldowns()
            if let access = currentAccess(target, auth: auth),
               !TokenRefresh.needsRefresh(expiry: expiry(target, auth: auth), leeway: 0) {
                return access
            }
            throw ProviderError.expired("login expired")
        case .transient:
            cooldown.recordTransient(at: now)
            cooldowns[target.cooldownKey] = cooldown
            try persistCooldowns()
            if let access = currentAccess(target, auth: auth),
               !TokenRefresh.needsRefresh(expiry: expiry(target, auth: auth), leeway: 0) {
                return access
            }
            throw ProviderError.http(status == 0 ? 503 : status)
        }
    }

    private func missingMessage(_ target: Target) -> String {
        switch target {
        case .codex: return "Codex not logged in with ChatGPT"
        case .grok: return "Grok CLI not logged in"
        }
    }

    private func currentAccess(_ target: Target, auth: [String: Any]) -> Access? {
        switch target {
        case .codex:
            let tokens = auth["tokens"] as? [String: Any] ?? [:]
            guard let token = TokenRefresh.string(tokens["access_token"]), !token.isEmpty else { return nil }
            return Access(token: token, accountID: TokenRefresh.string(tokens["account_id"]))
        case .grok:
            guard let found = TokenRefresh.grokEntry(in: auth),
                  let token = TokenRefresh.string(found.entry["key"]), !token.isEmpty else { return nil }
            return Access(token: token, accountID: nil)
        }
    }

    private func expiry(_ target: Target, auth: [String: Any]) -> Date? {
        switch target {
        case .codex: return TokenRefresh.codexAccessExpiry(auth)
        case .grok:
            guard let found = TokenRefresh.grokEntry(in: auth) else { return nil }
            return TokenRefresh.grokExpiry(found.entry)
        }
    }

    private func refreshToken(_ target: Target, auth: [String: Any]) -> String? {
        switch target {
        case .codex:
            let tokens = auth["tokens"] as? [String: Any] ?? [:]
            return TokenRefresh.string(tokens["refresh_token"])
        case .grok:
            return TokenRefresh.grokEntry(in: auth).flatMap { TokenRefresh.string($0.entry["refresh_token"]) }
        }
    }

    private func apply(_ target: Target, auth: [String: Any], response: [String: Any]) -> [String: Any]? {
        switch target {
        case .codex:
            return TokenRefresh.applyingCodexRefresh(auth, response: response)
        case .grok:
            guard let key = TokenRefresh.grokEntry(in: auth)?.key else { return nil }
            return TokenRefresh.applyingGrokRefresh(auth, entryKey: key, response: response)
        }
    }

    private func post(_ target: Target, auth: [String: Any], refresh: String) async throws -> (Int, Data) {
        var req: URLRequest
        switch target {
        case .codex:
            req = URLRequest(url: TokenRefresh.codexURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("phosphor-hud/0.2", forHTTPHeaderField: "User-Agent")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_id": TokenRefresh.codexClientID,
                "grant_type": "refresh_token",
                "refresh_token": refresh,
            ])
        case .grok:
            guard let entry = TokenRefresh.grokEntry(in: auth),
                  let clientID = TokenRefresh.grokClientID(entryKey: entry.key, entry: entry.entry) else {
                throw ProviderError.parse("Grok auth.json has no OIDC client id")
            }
            req = URLRequest(url: TokenRefresh.grokURL)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("phosphor-hud/0.2", forHTTPHeaderField: "User-Agent")
            req.httpBody = form([
                ("grant_type", "refresh_token"),
                ("refresh_token", refresh),
                ("client_id", clientID),
            ])
        }
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (status, data)
        } catch {
            return (0, Data())
        }
    }

    private func form(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private func atomicWriteJSON(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
        let dir = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .withoutOverwriting)
        let mode: NSNumber
        if let existing = try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber {
            mode = existing
        } else {
            mode = 0o600 as NSNumber
        }
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
        _ = try fileManager.replaceItemAt(url, withItemAt: tmp)
    }

    private func loadCooldowns() throws {
        if loaded { return }
        loaded = true
        guard let data = try? Data(contentsOf: cooldownURL) else { return }
        if let decoded = try? JSONDecoder().decode([String: TokenRefresh.Cooldown].self, from: data) {
            cooldowns = decoded
        }
    }

    private func persistCooldowns() throws {
        try fileManager.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(cooldowns)
        try data.write(to: cooldownURL, options: .atomic)
    }
}
