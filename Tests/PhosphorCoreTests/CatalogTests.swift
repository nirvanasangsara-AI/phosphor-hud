import Testing
import Foundation
@testable import PhosphorCore

struct FakeProbe: FileProbe {
    var files: Set<String> = []
    var executables: Set<String> = []
    var regularFiles: Set<String> = []
    var children: [String: [String]] = [:]
    func exists(_ p: String) -> Bool { files.contains(p) || executables.contains(p) || regularFiles.contains(p) }
    func isExecutable(_ p: String) -> Bool { executables.contains(p) }
    func fileExists(_ p: String) -> Bool { regularFiles.contains(p) }
    func childNames(_ directory: String) -> [String] { children[directory] ?? [] }
}

@Suite struct CatalogTests {
    @Test func idsAreUniqueAndLowercase() {
        let ids = ProviderCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0 == $0.lowercased() })
        #expect(ProviderCatalog.all.count >= 25)
    }

    @Test func coversRequestedProviders() {
        for id in ["cursor", "gemini", "openai-api", "anthropic-api", "openrouter", "windsurf", "cline", "roo",
                   "aider", "kiro", "warp", "amp", "jetbrains", "ollama",
                   "gemini-app", "google-ai-credits", "gemini-api", "vertex"] {
            #expect(ProviderCatalog.spec(id) != nil, "missing \(id)")
        }
    }

    @Test func googleSurfacesAreSeparateAndLabelled() {
        let names = ["antigravity", "gemini", "gemini-app", "google-ai-credits", "gemini-api", "vertex"]
            .compactMap { ProviderCatalog.spec($0)?.name }
        #expect(Set(names).count == 6)
        #expect(ProviderCatalog.spec("gemini-app")?.screenOnly == true)
        #expect(ProviderCatalog.spec("gemini")?.name == "Gemini CLI")
    }

    @Test func apiProvidersNameAKeyVariable() {
        for s in ProviderCatalog.all where s.sources.contains(.apiKey) {
            #expect(s.apiKeyEnv != nil, "\(s.id) needs apiKeyEnv")
        }
    }

    @Test func detectsBinaryAppAndPath() {
        let probe = FakeProbe(files: ["/Applications/Cursor.app", "/Users/t/.kiro"],
                              executables: ["/opt/homebrew/bin/ollama"])
        let d = Detector(home: "/Users/t", environmentPath: "/usr/bin", probe: probe)
        let found = d.detected()
        #expect(found["cursor"] == "app Cursor.app")
        #expect(found["kiro"] == "~/.kiro")
        #expect(found["ollama"] == "bin ollama")
        #expect(found["windsurf"] == nil)
        #expect(found["openrouter"] == nil)   // key-only providers are never "installed"
    }

    @Test func useEvidenceIgnoresInstallAndBareConfigFolders() {
        let probe = FakeProbe(
            files: ["/Users/t/.factory", "/Users/t/Library/Application Support/JetBrains",
                    "/Applications/IntelliJ IDEA.app", "/Users/t/.config/amp"],
            executables: ["/opt/homebrew/bin/amp", "/opt/homebrew/bin/droid"],
            regularFiles: ["/Users/t/.grok/auth.json", "/Users/t/.aider.conf.yml"],
            children: [
                "/Users/t/.factory": ["settings.json"],
                "/Users/t/.config/amp": ["auth.json"],
                "/Users/t/.gemini/tmp": ["session.json"],
                "/Users/t/.ollama/models": ["llama3"],
            ])
        let d = Detector(home: "/Users/t", environmentPath: "/usr/bin", probe: probe)
        let installed = d.detected()
        let used = d.useEvidence()
        #expect(installed["amp"] != nil)
        #expect(installed["jetbrains"] != nil)
        #expect(used["droid"] == nil)          // settings.json is config, not a login or a log
        #expect(used["jetbrains"] == nil)
        #expect(used["amp"] == "~/.config/amp")
        #expect(used["grok"] == "~/.grok/auth.json")
        #expect(used["aider"] == "~/.aider.conf.yml")
        #expect(used["gemini"] == "~/.gemini/tmp")
        #expect(used["ollama"] == "~/.ollama/models")
    }

    @Test func userChoiceWinsOverDetection() {
        let cat = ProviderCatalog.all
        let on = ProviderSelection.enabled(catalog: cat, detected: ["cursor", "ollama"],
                                           overrides: ["ollama": false, "warp": true])
        #expect(on.contains("cursor"))
        #expect(on.contains("warp"))
        #expect(!on.contains("ollama"))
        #expect(!on.contains("kiro"))
    }
}
