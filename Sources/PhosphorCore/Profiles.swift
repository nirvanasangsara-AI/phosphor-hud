import Foundation

/// Extra accounts for one provider, from `~/.config/phosphor/accounts.json`:
///
///     { "profiles": [
///         { "provider": "codex",  "name": "work", "home": "~/.codex-work" },
///         { "provider": "claude", "name": "work", "configDir": "~/.claude-work" }
///     ] }
///
/// Each profile points at a login the official CLI already made (`CODEX_HOME=~/.codex-work codex login`,
/// `CLAUDE_CONFIG_DIR=~/.claude-work claude`). Phosphor never signs in or stores tokens itself.
public struct Profile: Codable, Sendable, Hashable, Identifiable {
    public var provider: String
    public var name: String
    public var home: String?            // Codex: its CODEX_HOME
    public var configDir: String?       // Claude Code: its CLAUDE_CONFIG_DIR
    public var keychainService: String? // Claude Code: exact Keychain item, when known

    public var id: String { "\(provider)@\(Profile.slug(name))" }

    public static func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(s.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    public static let supportedProviders: Set<String> = ["claude", "codex"]

    public init(provider: String, name: String, home: String? = nil, configDir: String? = nil, keychainService: String? = nil) {
        self.provider = provider; self.name = name; self.home = home; self.configDir = configDir; self.keychainService = keychainService
    }

    public func expanded(home h: String = NSHomeDirectory()) -> Profile {
        func x(_ p: String?) -> String? {
            guard let p else { return nil }
            if p == "~" { return h }
            return p.hasPrefix("~/") ? h + p.dropFirst(1) : p
        }
        return Profile(provider: provider, name: name, home: x(home), configDir: x(configDir), keychainService: keychainService)
    }
}

public enum ProfilesConfig {
    public static let fileName = "accounts.json"

    public struct Result: Sendable {
        public var profiles: [Profile]
        public var problems: [String]
    }

    public static func parse(_ data: Data, home: String = NSHomeDirectory()) -> Result {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Result(profiles: [], problems: ["accounts.json is not a JSON object"])
        }
        var out: [Profile] = [], problems: [String] = [], ids = Set<String>()
        for (n, raw) in (o["profiles"] as? [[String: Any]] ?? []).enumerated() {
            guard let provider = (raw["provider"] as? String)?.lowercased(), let name = raw["name"] as? String, !name.isEmpty else {
                problems.append("profile \(n + 1): needs provider and name"); continue
            }
            guard Profile.supportedProviders.contains(provider) else {
                problems.append("profile \(n + 1): \(provider) has no multi-account support yet"); continue
            }
            let p = Profile(provider: provider, name: name, home: raw["home"] as? String,
                            configDir: raw["configDir"] as? String, keychainService: raw["keychainService"] as? String).expanded(home: home)
            if provider == "codex", p.home == nil { problems.append("\(p.id): set \"home\" (its CODEX_HOME)"); continue }
            if provider == "claude", p.configDir == nil, p.keychainService == nil {
                problems.append("\(p.id): set \"configDir\" or \"keychainService\""); continue
            }
            guard ids.insert(p.id).inserted else { problems.append("\(p.id): duplicate"); continue }
            out.append(p)
        }
        return Result(profiles: out, problems: problems)
    }
}

#if canImport(CryptoKit)
import CryptoKit
extension Profile {
    /// Claude Code keeps a non-default config dir's login in "Claude Code-credentials-<first 8 hex of sha256(dir)>".
    public var claudeKeychainService: String? {
        if let keychainService { return keychainService }
        guard let configDir else { return nil }
        let hex = SHA256.hash(data: Data(configDir.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hex.prefix(8))"
    }
}
#endif
