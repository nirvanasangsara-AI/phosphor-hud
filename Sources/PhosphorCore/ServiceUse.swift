import Foundation

/// Whether a catalog row is drawn. New installs use `.auto`: the row appears only when this Mac
/// has a login, a usage log, an API key, or a billing-screen reading. A binary, an app bundle,
/// or an empty config folder is not enough.
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

    /// `hasUseEvidence` is a credential file, usage log, API key, or billing-screen hit recorded by
    /// the registry. It keeps the row even when the reader still phrases its placeholder as "Installed".
    public static func shown(display: Display, inUse: Bool, hasUseEvidence: Bool = false) -> Bool {
        switch display {
        case .always: return true
        case .hidden: return false
        case .auto: return inUse || hasUseEvidence
        }
    }

    /// Local servers are probed whenever the app is installed, so a running LM Studio or Ollama
    /// can answer. The row is still hidden until that answer, or other use evidence, says so.
    public static func shouldProbe(localServer: Bool, installed: Bool, display: Display, enabled: Bool) -> Bool {
        if display == .hidden { return false }
        if enabled { return true }
        return localServer && installed
    }

    public static func inUse(_ presence: Presence) -> Bool {
        switch presence {
        case .liveReading, .signedIn: return true
        case .installOnly, .absent: return false
        }
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
