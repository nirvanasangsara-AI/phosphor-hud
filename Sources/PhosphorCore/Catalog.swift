import Foundation

/// Where a provider's numbers can come from. A provider may have several.
public enum DataSource: String, Sendable, Hashable, CaseIterable {
    /// A live quota/limit API the official CLI or app already signs in to.
    case liveQuota
    /// Token counts in session logs the tool writes on this Mac (read-only, content never kept).
    case localLogs
    /// An API key the user gave Phosphor (environment variable or Phosphor's own Keychain item).
    case apiKey
    /// A server running on this Mac (e.g. Ollama on localhost).
    case localServer
    /// Values read from the service's own settings/billing screen into `billing-screens.json`.
    case billingScreen
}

public enum ProviderCategory: String, Sendable, Hashable {
    case subscription, api, editor, cli, local
}

/// How Phosphor tells a provider is installed: a command on PATH, an app bundle, or a folder
/// the tool keeps in your home folder. Any one hit counts.
public struct Detection: Sendable, Hashable {
    public var binaries: [String]
    public var apps: [String]
    public var paths: [String]      // relative to the home folder
    public init(binaries: [String] = [], apps: [String] = [], paths: [String] = []) {
        self.binaries = binaries; self.apps = apps; self.paths = paths
    }
}

/// Which public status page covers a provider, and which of its components matter.
public struct StatusRef: Sendable, Hashable {
    public enum Feed: String, Sendable, Hashable {
        case anthropic, openai, github, xai, windsurf, googleCloud
    }
    public var feed: Feed
    /// Component names (or name prefixes) on that page that affect this provider.
    public var components: [String]
    /// Words that tie an open incident to this provider even when no component is marked.
    public var incidentKeywords: [String]
    public init(_ feed: Feed, components: [String], incidentKeywords: [String] = []) {
        self.feed = feed; self.components = components; self.incidentKeywords = incidentKeywords
    }
}

public struct ProviderSpec: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let monogram: String
    public let colorHex: String
    public let category: ProviderCategory
    public let sources: Set<DataSource>
    public let detect: Detection
    public let status: StatusRef?
    /// The page where the plan, price and next bill appear (for billing-screens.json readings).
    public let billingURL: String?
    /// Environment variable that may hold an API key for `.apiKey` providers.
    public let apiKeyEnv: String?

    public init(id: String, name: String, monogram: String, colorHex: String, category: ProviderCategory,
                sources: Set<DataSource>, detect: Detection, status: StatusRef? = nil,
                billingURL: String? = nil, apiKeyEnv: String? = nil) {
        self.id = id; self.name = name; self.monogram = monogram; self.colorHex = colorHex
        self.category = category; self.sources = sources; self.detect = detect; self.status = status
        self.billingURL = billingURL; self.apiKeyEnv = apiKeyEnv
    }

    /// Keychain service name for a key the user stores for Phosphor:
    /// `security add-generic-password -s "Phosphor: openrouter" -a default -w`
    public var keychainService: String { "Phosphor: \(id)" }

    /// Neither a live API nor logs nor a key nor a local server: only the billing screen.
    public var screenOnly: Bool { sources == [.billingScreen] }
}

public enum ProviderCatalog {
    private static let vscodeHosts = ["Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium", "Kiro"]
    private static func extensionDirs(_ ext: String) -> [String] {
        vscodeHosts.map { "Library/Application Support/\($0)/User/globalStorage/\(ext)" }
    }

    public static let all: [ProviderSpec] = [
        // Native live-quota providers (read by Phosphor since 0.1)
        .init(id: "claude", name: "Claude Code", monogram: "C", colorHex: "#D97757", category: .subscription,
              sources: [.liveQuota, .localLogs, .billingScreen],
              detect: .init(binaries: ["claude"], paths: [".claude"]),
              status: .init(.anthropic, components: ["Claude Code"], incidentKeywords: ["Claude Code"]),
              billingURL: "https://claude.ai/settings/billing"),
        .init(id: "codex", name: "Codex", monogram: "Cx", colorHex: "#10A37F", category: .subscription,
              sources: [.liveQuota, .localLogs, .billingScreen],
              detect: .init(binaries: ["codex"], paths: [".codex"]),
              status: .init(.openai, components: ["Codex"], incidentKeywords: ["Codex"]),
              billingURL: "https://chatgpt.com/#settings/Subscription"),
        .init(id: "antigravity", name: "Antigravity", monogram: "A", colorHex: "#34A853", category: .subscription,
              sources: [.liveQuota, .billingScreen],
              detect: .init(binaries: ["agy"], apps: ["Antigravity.app"], paths: [".gemini/antigravity"]),
              status: .init(.googleCloud, components: ["Gemini"]),
              billingURL: "https://one.google.com/settings"),
        .init(id: "grok", name: "Grok CLI", monogram: "X", colorHex: "#E5E7EB", category: .subscription,
              sources: [.liveQuota, .billingScreen],
              detect: .init(binaries: ["grok"], paths: [".grok"]),
              status: .init(.xai, components: ["Grok Build and Cursor: CLI"]),
              billingURL: "https://grok.com/?_s=billing"),
        .init(id: "grokbot", name: "Grok Bot", monogram: "GB", colorHex: "#7DD3FC", category: .subscription,
              sources: [.liveQuota, .billingScreen],
              detect: .init(apps: ["Grok Bot.app"]),
              status: .init(.xai, components: ["Grok Bot"])),
        .init(id: "copilot", name: "Copilot", monogram: "Co", colorHex: "#8B5CF6", category: .subscription,
              sources: [.liveQuota, .billingScreen],
              detect: .init(paths: [".config/github-copilot"]),
              status: .init(.github, components: ["Copilot"]),
              billingURL: "https://github.com/settings/copilot"),
        .init(id: "muse", name: "Muse Code", monogram: "M", colorHex: "#0866FF", category: .subscription,
              sources: [.liveQuota, .billingScreen],
              detect: .init(binaries: ["muse"], paths: [".config/muse"])),

        // Subscriptions and editors without a public usage API: installed check + billing screen + status
        .init(id: "cursor", name: "Cursor", monogram: "Cu", colorHex: "#9CA3AF", category: .editor,
              sources: [.billingScreen],
              detect: .init(binaries: ["cursor-agent", "cursor"], apps: ["Cursor.app"]),
              status: .init(.xai, components: ["Grok Build and Cursor:", "IDE"]),
              billingURL: "https://cursor.com/dashboard?tab=billing"),
        .init(id: "windsurf", name: "Windsurf", monogram: "Ws", colorHex: "#0EA5E9", category: .editor,
              sources: [.billingScreen],
              detect: .init(binaries: ["windsurf"], apps: ["Windsurf.app"], paths: [".codeium/windsurf"]),
              status: .init(.windsurf, components: ["Cascade", "Windsurf Tab"]),
              billingURL: "https://windsurf.com/subscription/usage"),
        .init(id: "kiro", name: "Kiro", monogram: "Kr", colorHex: "#7C3AED", category: .editor,
              sources: [.billingScreen],
              detect: .init(binaries: ["kiro", "kiro-cli"], apps: ["Kiro.app"], paths: [".kiro"]),
              billingURL: "https://app.kiro.dev/account/usage"),
        .init(id: "warp", name: "Warp", monogram: "W", colorHex: "#01A4FF", category: .editor,
              sources: [.billingScreen],
              detect: .init(apps: ["Warp.app"], paths: [".warp"]),
              billingURL: "https://app.warp.dev/settings/billing"),
        .init(id: "jetbrains", name: "JetBrains AI", monogram: "JB", colorHex: "#FE2857", category: .editor,
              sources: [.billingScreen],
              detect: .init(apps: ["IntelliJ IDEA.app", "IntelliJ IDEA Ultimate.app", "PyCharm.app", "WebStorm.app",
                                   "GoLand.app", "RustRover.app", "CLion.app", "Rider.app", "PhpStorm.app",
                                   "DataGrip.app", "Android Studio.app"],
                            paths: ["Library/Application Support/JetBrains"]),
              billingURL: "https://account.jetbrains.com/licenses"),
        .init(id: "zed", name: "Zed", monogram: "Z", colorHex: "#084CCF", category: .editor,
              sources: [.billingScreen],
              detect: .init(binaries: ["zed"], apps: ["Zed.app"], paths: [".config/zed"]),
              billingURL: "https://zed.dev/account"),
        .init(id: "amp", name: "Amp", monogram: "Am", colorHex: "#EF4444", category: .cli,
              sources: [.billingScreen],
              detect: .init(binaries: ["amp"], paths: [".config/amp", ".local/share/amp"]),
              billingURL: "https://ampcode.com/settings"),
        .init(id: "kimi", name: "Kimi Code", monogram: "K", colorHex: "#6366F1", category: .cli,
              sources: [.billingScreen],
              detect: .init(binaries: ["kimi"], paths: [".kimi-code", ".kimi"])),
        .init(id: "droid", name: "Droid", monogram: "Dr", colorHex: "#F97316", category: .cli,
              sources: [.billingScreen],
              detect: .init(binaries: ["droid"], paths: [".factory"]),
              billingURL: "https://app.factory.ai/settings/billing"),
        .init(id: "opencode", name: "OpenCode", monogram: "Oc", colorHex: "#A3A3A3", category: .cli,
              sources: [.billingScreen],
              detect: .init(binaries: ["opencode"], paths: [".local/share/opencode"])),
        .init(id: "aider", name: "Aider", monogram: "Ai", colorHex: "#14B8A6", category: .cli,
              sources: [.billingScreen],
              detect: .init(binaries: ["aider"], paths: [".aider.conf.yml"])),

        // Google AI surfaces that agy /usage does NOT cover. Each is its own meter at Google:
        // Antigravity ≠ Gemini app (web) ≠ Gemini CLI ≠ AI Studio API ≠ Google One AI credits ≠ Vertex.
        .init(id: "gemini-app", name: "Gemini app (web)", monogram: "Gw", colorHex: "#8AB4F8", category: .subscription,
              sources: [.billingScreen], detect: .init(),
              status: .init(.googleCloud, components: ["Gemini app", "Gemini"]),
              billingURL: "https://gemini.google.com/app"),
        .init(id: "google-ai-credits", name: "Google AI credits (Flow/Whisk/Veo)", monogram: "Gc", colorHex: "#FBBC04",
              category: .subscription, sources: [.billingScreen], detect: .init(),
              billingURL: "https://one.google.com/settings"),
        .init(id: "gemini-api", name: "Gemini API (AI Studio)", monogram: "Gk", colorHex: "#1A73E8", category: .api,
              sources: [.apiKey], detect: .init(),
              status: .init(.googleCloud, components: ["Gemini API", "Generative Language", "AI Studio"]),
              billingURL: "https://aistudio.google.com/usage", apiKeyEnv: "GEMINI_API_KEY"),
        .init(id: "vertex", name: "Vertex AI (gcloud)", monogram: "Vx", colorHex: "#4285F4", category: .api,
              sources: [.billingScreen], detect: .init(binaries: ["gcloud"], paths: [".config/gcloud/configurations"]),
              status: .init(.googleCloud, components: ["Vertex"]),
              billingURL: "https://console.cloud.google.com/billing"),

        // Local session logs with token counts
        .init(id: "gemini", name: "Gemini CLI", monogram: "G", colorHex: "#4796E3", category: .cli,
              sources: [.localLogs],
              detect: .init(binaries: ["gemini"], paths: [".gemini/tmp"]),
              status: .init(.googleCloud, components: ["Gemini"])),
        .init(id: "cline", name: "Cline", monogram: "Cl", colorHex: "#F5F5F5", category: .editor,
              sources: [.localLogs],
              detect: .init(paths: extensionDirs("saoudrizwan.claude-dev"))),
        .init(id: "roo", name: "Roo Code", monogram: "Ro", colorHex: "#FACC15", category: .editor,
              sources: [.localLogs],
              detect: .init(paths: extensionDirs("rooveterinaryinc.roo-cline"))),

        // API keys you give Phosphor
        .init(id: "openrouter", name: "OpenRouter", monogram: "OR", colorHex: "#94A3B8", category: .api,
              sources: [.apiKey], detect: .init(), apiKeyEnv: "OPENROUTER_API_KEY"),
        .init(id: "openai-api", name: "OpenAI API", monogram: "OA", colorHex: "#74AA9C", category: .api,
              sources: [.apiKey], detect: .init(),
              status: .init(.openai, components: ["Chat Completions", "Responses"]),
              apiKeyEnv: "OPENAI_ADMIN_KEY"),
        .init(id: "anthropic-api", name: "Anthropic API", monogram: "An", colorHex: "#CC785C", category: .api,
              sources: [.apiKey], detect: .init(),
              status: .init(.anthropic, components: ["Claude API"]),
              apiKeyEnv: "ANTHROPIC_ADMIN_KEY"),

        // Local model servers
        .init(id: "ollama", name: "Ollama", monogram: "Ol", colorHex: "#E5E5E5", category: .local,
              sources: [.localServer],
              detect: .init(binaries: ["ollama"], apps: ["Ollama.app"], paths: [".ollama"])),
        .init(id: "lmstudio", name: "LM Studio", monogram: "LM", colorHex: "#6D28D9", category: .local,
              sources: [.localServer],
              detect: .init(binaries: ["lms"], apps: ["LM Studio.app"], paths: [".lmstudio"])),
    ]

    public static let byID: [String: ProviderSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    public static func spec(_ id: String) -> ProviderSpec? { byID[id.lowercased()] }
}

// MARK: - Detection

/// What the detector may look at; swapped for a fake in tests.
public protocol FileProbe: Sendable {
    func exists(_ path: String) -> Bool
    func isExecutable(_ path: String) -> Bool
    /// A regular file. A directory path is not a credential.
    func fileExists(_ path: String) -> Bool
    /// Names directly inside a directory. Empty when the path is missing.
    func childNames(_ directory: String) -> [String]
}

extension FileProbe {
    public func fileExists(_ path: String) -> Bool { false }
    public func childNames(_ directory: String) -> [String] { [] }
}

public struct LocalFileProbe: FileProbe {
    public init() {}
    public func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    public func isExecutable(_ path: String) -> Bool { FileManager.default.isExecutableFile(atPath: path) }
    public func fileExists(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
    }
    public func childNames(_ directory: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    }
}

public struct Detector: Sendable {
    public let home: String
    public let searchPath: [String]
    public let appDirs: [String]
    public let probe: FileProbe

    /// GUI apps get a minimal PATH, so the usual install folders are searched too.
    public init(home: String = NSHomeDirectory(), environmentPath: String? = ProcessInfo.processInfo.environment["PATH"],
                probe: FileProbe = LocalFileProbe()) {
        self.home = home
        self.probe = probe
        var dirs = (environmentPath ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(home)/.local/bin", "\(home)/.bun/bin",
                 "\(home)/.npm-global/bin", "\(home)/.cargo/bin", "\(home)/bin"]
        var seen = Set<String>()
        self.searchPath = dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
        self.appDirs = ["/Applications", "\(home)/Applications", "/Applications/Setapp"]
    }

    /// Credential files and log/login files. A binary, an app, or a bare config folder does not count.
    public func useEvidence() -> [String: String] {
        var out: [String: String] = [:]
        for (id, rels) in ServiceUse.credentialFiles {
            for rel in rels where probe.fileExists("\(home)/\(rel)") {
                out[id] = "~/\(rel)"
                break
            }
        }
        for (id, rels) in ServiceUse.activityDirectories where out[id] == nil {
            for rel in rels {
                let hit = probe.childNames("\(home)/\(rel)").contains(where: ServiceUse.isActivityFile)
                if hit { out[id] = "~/\(rel)"; break }
            }
        }
        for (id, rels) in ServiceUse.logDirectories where out[id] == nil {
            for rel in rels {
                let hit = probe.childNames("\(home)/\(rel)").contains(where: ServiceUse.isLogChild)
                if hit { out[id] = "~/\(rel)"; break }
            }
        }
        return out
    }

    /// The first thing that shows `spec` is installed ("bin claude", "app Cursor.app", "~/.kiro"), or nil.
    public func evidence(for spec: ProviderSpec) -> String? {
        for b in spec.detect.binaries {
            if searchPath.contains(where: { probe.isExecutable("\($0)/\(b)") }) { return "bin \(b)" }
        }
        for a in spec.detect.apps where appDirs.contains(where: { probe.exists("\($0)/\(a)") }) { return "app \(a)" }
        for p in spec.detect.paths where probe.exists("\(home)/\(p)") { return "~/\(p)" }
        return nil
    }

    public func detected(_ specs: [ProviderSpec] = ProviderCatalog.all) -> [String: String] {
        var out: [String: String] = [:]
        for s in specs { if let e = evidence(for: s) { out[s.id] = e } }
        return out
    }
}

/// Which providers are on: the user's explicit choice wins, otherwise "installed".
public enum ProviderSelection {
    public static func enabled(catalog: [ProviderSpec], detected: Set<String>, overrides: [String: Bool]) -> [String] {
        catalog.filter { overrides[$0.id] ?? detected.contains($0.id) }.map(\.id)
    }
}
