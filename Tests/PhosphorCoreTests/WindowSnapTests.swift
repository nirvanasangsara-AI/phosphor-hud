import Testing
@testable import PhosphorCore

@Suite struct WindowSnapTests {
    let screen = SnapRect(x: 0, y: 25, width: 1440, height: 875) // visibleFrame-like
    let cfg = SnapConfig(threshold: 14, gap: 4)

    @Test func optionBypassSkipsSnap() {
        let f = SnapRect(x: 3, y: 26, width: 300, height: 200)
        let out = WindowSnap.snap(f, visibleScreen: screen, companions: [], config: cfg, bypass: true)
        #expect(out == f)
    }

    @Test func snapsToScreenEdgesWithGap() {
        let f = SnapRect(x: 2, y: 28, width: 300, height: 200)
        let out = WindowSnap.snap(f, visibleScreen: screen, companions: [], config: cfg)
        #expect(abs(out.minX - (screen.minX + 4)) < 0.01)
        #expect(abs(out.minY - (screen.minY + 4)) < 0.01)
    }

    @Test func snapsToCompanionAdjacentAndAligned() {
        let companion = SnapRect(x: 100, y: 200, width: 280, height: 360)
        // Just to the right of the companion, slightly vertically offset.
        let f = SnapRect(x: companion.maxX + 10, y: companion.minY + 8, width: 300, height: 200)
        let out = WindowSnap.snap(f, visibleScreen: screen, companions: [companion], config: cfg)
        #expect(abs(out.minX - (companion.maxX + 4)) < 0.01)
        #expect(abs(out.minY - companion.minY) < 0.01)
    }

    @Test func snapsRightEdgeToCompanionLeft() {
        let companion = SnapRect(x: 500, y: 100, width: 200, height: 300)
        let f = SnapRect(x: 190, y: 100, width: 300, height: 180) // maxX = 490, 10pt gap to 500
        let out = WindowSnap.snap(f, visibleScreen: screen, companions: [companion], config: cfg)
        #expect(abs(out.maxX - (companion.minX - 4)) < 0.01)
    }

    @Test func doesNotSnapOutsideThreshold() {
        let companion = SnapRect(x: 100, y: 200, width: 200, height: 200)
        let f = SnapRect(x: 400, y: 500, width: 200, height: 150)
        let out = WindowSnap.snap(f, visibleScreen: screen, companions: [companion], config: cfg)
        #expect(out == f)
    }
}

@Suite struct ProviderVisibilityTests {
    let google = ["antigravity", "gemini", "gemini-app", "google-ai-credits", "gemini-api", "vertex"]

    @Test func hidesOneFamilyMemberAndKeepsTheRest() {
        let hidden = ProviderVisibility.hiding("gemini-app", in: [])
        #expect(ProviderVisibility.visibleMembers(of: google, hidden: hidden)
                == ["antigravity", "gemini", "google-ai-credits", "gemini-api", "vertex"])
    }

    @Test func emptyGroupWhenEveryMemberIsHidden() {
        let hidden = Set(google)
        #expect(ProviderVisibility.visibleMembers(of: google, hidden: hidden).isEmpty)
    }

    @Test func showingIsReversible() {
        let hidden = ProviderVisibility.hiding("ollama", in: ["codex"])
        #expect(hidden == ["codex", "ollama"])
        #expect(ProviderVisibility.showing("ollama", in: hidden) == ["codex"])
        #expect(ProviderVisibility.visible(ids: ["claude", "codex", "ollama"], hidden: hidden)
                == ["claude"])
    }
}

@Suite struct SparklineSeriesTests {
    @Test func weeklyLabels() {
        #expect(SparklineSeries.isWeekly(label: "7D", windowSeconds: nil))
        #expect(SparklineSeries.isWeekly(label: "7D EST", windowSeconds: nil))
        #expect(SparklineSeries.isWeekly(label: "WEEKLY", windowSeconds: nil))
        #expect(SparklineSeries.isWeekly(label: "5H", windowSeconds: 18_000) == false)
        #expect(SparklineSeries.isWeekly(label: "PRO", windowSeconds: 604_800))
    }

    @Test func singleSampleIsAFlatMidline() {
        #expect(SparklineSeries.normalize([42]) == [0.5])
        #expect(SparklineSeries.normalize([3, 3, 3]) == [0.5, 0.5, 0.5])
    }

    @Test func normalizesAndDownsamples() {
        let pts = SparklineSeries.normalize([0, 50, 100])
        #expect(pts.count == 3)
        #expect(abs(pts[0] - 0) < 1e-9)
        #expect(abs(pts[1] - 0.5) < 1e-9)
        #expect(abs(pts[2] - 1) < 1e-9)
        let long = SparklineSeries.downsample((0..<100).map(Double.init), cap: 10)
        #expect(long.count == 10)
        #expect(long.first == 0 && long.last == 99)
    }
}
