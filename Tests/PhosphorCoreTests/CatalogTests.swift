import Testing
import Foundation
@testable import PhosphorCore

struct FakeProbe: FileProbe {
    var files: Set<String> = []
    var executables: Set<String> = []
    func exists(_ p: String) -> Bool { files.contains(p) || executables.contains(p) }
    func isExecutable(_ p: String) -> Bool { executables.contains(p) }
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
