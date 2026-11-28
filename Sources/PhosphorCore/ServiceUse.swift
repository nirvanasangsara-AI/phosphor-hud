import Foundation

/// Whether a catalog row is drawn. New installs use `.auto`: the row appears only after recent
/// non-zero use (a quota above 0%, tokens or API spend in the last 30 days, or a model loaded
/// in Ollama). A login file, an installed app, a config file, or a billing-screen reading is not enough.
public enum ServiceUse {
    public enum Display: String, Codable, Sendable, CaseIterable, Equatable {
        case auto
        case always
        case hidden

        public static let newInstall = Display.auto

        public var labelKey: String {
            switch self {
            case .auto: return "service.auto"
            case .always: return "service.always"
            case .hidden: return "service.hidden"
            }
        }
    }

    /// What the latest reading says, without AppKit types.
    public enum Presence: Sendable, Equatable {
        /// A live quota, a log total, or a local server answered.
        case liveReading
        /// Signed in, a working key, or a billing screen, with no install-only placeholder.
        case signedIn
        /// The tool may be installed, but nothing shows a signup or any use.
        case installOnly
        case absent
    }

    /// Under `.auto` the row needs recent non-zero use. A login file, an install, a config file,
    /// or a billing-screen reading is not enough. `.always` still forces the row on.
    public static func shown(display: Display, recentUse: Bool) -> Bool {
        switch display {
        case .always: return true
        case .hidden: return false
        case .auto: return recentUse
        }
    }

    /// One meter or quota from a reading. `localServer` rows count only a loaded model, not a model list.
    public struct UseSample: Equatable, Sendable {
        public var label: String
        public var amount: Double
        public var isQuota: Bool
        public init(label: String, amount: Double, isQuota: Bool) {
            self.label = label; self.amount = amount; self.isQuota = isQuota
        }
    }

    public static func recentUse(_ samples: [UseSample], localServer: Bool) -> Bool {
        if localServer {
            return samples.contains { $0.label == "LOADED" && $0.amount > 0 }
        }
        let inventory: Set<String> = ["INSTALLED", "MODELS"]
        return samples.contains { sample in
            if inventory.contains(sample.label) { return false }
            return sample.amount > 0
        }
    }

    /// Local servers are probed whenever the app is installed, so a running LM Studio or Ollama
    /// can answer. The row is still hidden until that answer, or other use evidence, says so.
    public static func shouldProbe(localServer: Bool, installed: Bool, display: Display, enabled: Bool) -> Bool {
        if display == .hidden { return false }
        if enabled { return true }
        return localServer && installed
    }

    /// Placeholder text is never recent use. A signed-in note, a billing screen, or "login found" stays off.
    public static func inUse(_ presence: Presence) -> Bool {
        presence == .liveReading
    }

    /// Status text from a reader. "Installed (…)" and "not logged in" are not a signup.
    public static func presence(forMessage message: String, connected: Bool) -> Presence {
        if connected { return .liveReading }
        let m = message.lowercased()
        if m.hasPrefix("installed") || m.hasPrefix("turned on") || m.hasPrefix("web only")
            || m.contains("not found on this mac") || m.contains("not installed")
            || m.contains("not logged in") || m.contains("not signed in") || m.contains("not connected")
            || m.contains("scanning local logs") || m.contains("no token usage") {
            return .installOnly
        }
        if m.isEmpty { return .absent }
        return .signedIn
    }

    /// Home-relative files the readers already open. A directory does not count.
    public static let credentialFiles: [String: [String]] = [
        "claude": [".claude/.credentials.json"],
        "codex": [".codex/auth.json"],
        "grok": [".grok/auth.json"],
        "muse": [".config/muse/auth.json"],
        "aider": [".aider.conf.yml"],
    ]

    /// Home-relative directories that count when they contain a log or a login file, not merely by existing.
    /// Amp, Droid, and the other CLIs landed in the catalog because a competitor HUD listed them.
    /// On the Mac mini they were detected from the binary or the config folder alone.
    public static let activityDirectories: [String: [String]] = [
        "amp": [".config/amp", ".local/share/amp"],
        "droid": [".factory"],
        "kimi": [".kimi", ".kimi-code"],
        "opencode": [".local/share/opencode"],
    ]

    /// Any ordinary file inside means the tool has written logs or models, not just that the folder exists.
    public static let logDirectories: [String: [String]] = [
        "gemini": [".gemini/tmp"],
        "ollama": [".ollama/models"],
        "cline": ["Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks"],
        "roo": ["Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks"],
    ]

    public static func isActivityFile(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.hasPrefix(".") { return false }
        return n.contains("auth") || n.contains("credential") || n.contains("token")
            || n.contains("session") || n.hasSuffix(".jsonl")
            || (n.hasSuffix(".json") && (n.contains("usage") || n.contains("account")))
    }

    public static func isLogChild(_ name: String) -> Bool {
        !name.hasPrefix(".") && name.caseInsensitiveCompare(".DS_Store") != .orderedSame
    }
}
