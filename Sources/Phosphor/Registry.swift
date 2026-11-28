import Foundation
import PhosphorCore

/// Which catalog providers are installed on this Mac and which the user turned on.
/// Native readers (Claude, Codex, …) always run; this decides the rest, so the HUD
/// only shows what you actually use unless you switch more on in Providers → More Providers.
@MainActor
final class ProviderRegistry: ObservableObject {
    static let shared = ProviderRegistry()
    static let native: Set<String> = ["claude", "codex", "antigravity", "grok", "grokbot", "copilot", "muse"]

    /// id → login, log, API key, or billing-screen evidence. A binary or an app bundle is not enough.
    @Published private(set) var detected: [String: String] = [:]
    /// id → install hit ("bin amp", "app IntelliJ IDEA.app"). Shown in the menu, not drawn by itself.
    @Published private(set) var installed: [String: String] = [:]
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var profileProblems: [String] = []
    private(set) var detectedAt: Date?

    /// Catalog providers beyond the native readers.
    var extras: [ProviderSpec] { ProviderCatalog.all.filter { !Self.native.contains($0.id) } }

    var enabledExtras: [ProviderSpec] {
        extras.filter { spec in
            ServiceUse.shouldProbe(localServer: spec.sources.contains(.localServer),
                                   installed: installed[spec.id] != nil,
                                   display: Prefs.shared.display(for: spec.id),
                                   enabled: isEnabled(spec.id))
        }
    }

    func isEnabled(_ id: String) -> Bool {
        switch Prefs.shared.display(for: id) {
        case .always: return true
        case .hidden: return false
        case .auto: return Prefs.shared.providerOverrides[id] ?? (detected[id] != nil)
        }
    }

    func toggle(_ id: String) {
        if isEnabled(id) {
            Prefs.shared.providerOverrides[id] = false
            if Prefs.shared.display(for: id) == .always { Prefs.shared.setDisplay(id, .auto) }
        } else {
            Prefs.shared.providerOverrides[id] = true
            Prefs.shared.setDisplay(id, .always)
        }
    }

    /// Re-check installs (cheap file checks) and API keys (Keychain attributes only, never the secret).
    func rescan() async {
        installed = Detector().detected()
        var all = Detector().useEvidence()
        for spec in ProviderCatalog.all where spec.sources.contains(.apiKey) {
            if let env = spec.apiKeyEnv, ProcessInfo.processInfo.environment[env]?.isEmpty == false {
                all[spec.id] = "$\(env)"
            } else if await APIKeys.exists(spec) {
                all[spec.id] = "key in Keychain"
            }
        }
        // Screen-only services (Gemini web, Google AI credits, Cursor…) count as "in use" once their
        // billing screen has been read into billing-screens.json.
        let screens = ScreenReadings.all()
        for spec in ProviderCatalog.all where all[spec.id] == nil && screens[spec.id] != nil { all[spec.id] = "billing-screens.json" }
        detected = all
        detectedAt = Date()
        loadProfiles()
    }

    func loadProfiles() {
        let url = Paths.config.appendingPathComponent(ProfilesConfig.fileName)
        guard let data = try? Data(contentsOf: url) else { profiles = []; profileProblems = []; return }
        let r = ProfilesConfig.parse(data)
        profiles = r.profiles
        profileProblems = r.problems
    }
}

/// API keys the user gives Phosphor: an environment variable, or Phosphor's own Keychain item
/// (`security add-generic-password -s "Phosphor: openrouter" -a default -w`). Keys are only ever
/// sent to their own service and never logged or shown.
enum APIKeys {
    static func exists(_ spec: ProviderSpec) async -> Bool {
        // Without -w, `security` prints only the item's attributes.
        (try? await Shell.run("/usr/bin/security", ["find-generic-password", "-s", spec.keychainService], timeout: 5)) != nil
    }

    static func key(_ spec: ProviderSpec) async -> String? {
        if let env = spec.apiKeyEnv, let v = ProcessInfo.processInfo.environment[env], !v.isEmpty { return v }
        guard let v = try? await Shell.run("/usr/bin/security", ["find-generic-password", "-s", spec.keychainService, "-w"], timeout: 5),
              !v.isEmpty else { return nil }
        return v
    }

    static func howTo(_ spec: ProviderSpec) -> String {
        "Set \(spec.apiKeyEnv.map { "$\($0) or " } ?? "")Keychain item “\(spec.keychainService)”"
    }
}
