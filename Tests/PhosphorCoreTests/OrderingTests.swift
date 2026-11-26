import Testing
@testable import PhosphorCore

@Suite struct OrderingTests {
    let defaults = ["claude", "codex", "antigravity", "grok", "grokbot", "copilot", "muse"]

    @Test func googleRowsStayTogetherAtAntigravitysPlace() {
        let ids = ["vertex", "claude", "gemini", "grok", "codex", "antigravity", "ollama", "gemini-app"]
        let out = RowOrdering.sort(ids, defaultOrder: defaults, custom: [])
        #expect(out == ["claude", "codex", "antigravity", "gemini", "gemini-app", "vertex", "grok", "ollama"])
    }

    @Test func customOrderMovesWholeGroupAndMembers() {
        let ids = ["claude", "codex", "antigravity", "gemini", "grok"]
        let custom = ["group:google", "grok", "claude", "codex", "gemini", "antigravity"]
        #expect(RowOrdering.sort(ids, defaultOrder: defaults, custom: custom)
                == ["gemini", "antigravity", "grok", "claude", "codex"])
    }

    @Test func newProvidersGoAfterCustomOnes() {
        let out = RowOrdering.sort(["claude", "muse", "codex"], defaultOrder: defaults, custom: ["codex", "claude"])
        #expect(out == ["codex", "claude", "muse"])
    }

    @Test func moveDropAndMerge() {
        #expect(RowOrdering.moved(["a", "b", "c"], key: "a", to: 2) == ["b", "c", "a"])
        #expect(RowOrdering.dropIndex(draggedMid: 55, otherMids: [10, 40, 80]) == 2)
        #expect(RowOrdering.merge(custom: ["x", "a", "b"], scope: ["b", "a"]) == ["b", "a", "x"])
    }

    @Test func familyLookup() {
        #expect(ProviderFamilies.family(of: "gemini-api")?.id == "google")
        #expect(ProviderFamilies.family(of: "codex") == nil)
        #expect(RowOrdering.unitKey("vertex") == "group:google")
    }
}
