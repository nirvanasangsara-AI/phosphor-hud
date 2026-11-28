import Testing
@testable import PhosphorCore

@Suite struct ServiceUseTests {
    @Test func autoShowsOnlyRecentNonZeroUse() {
        #expect(ServiceUse.shown(display: .auto, recentUse: true))
        #expect(!ServiceUse.shown(display: .auto, recentUse: false))
        #expect(ServiceUse.shown(display: .always, recentUse: false))
        #expect(!ServiceUse.shown(display: .hidden, recentUse: true))
        #expect(ServiceUse.Display.newInstall == .auto)
    }

    @Test func loginInstallAndBillingNotesAreNotUse() {
        #expect(ServiceUse.presence(forMessage: "Installed (bin amp) · no usage API — hover for billing screen", connected: false) == .installOnly)
        #expect(ServiceUse.presence(forMessage: "Login found (~/.aider.conf.yml) · no usage API — hover for billing screen", connected: false) == .signedIn)
        #expect(ServiceUse.presence(forMessage: "No usage API · plan/price from its billing screen (hover)", connected: false) == .signedIn)
        #expect(ServiceUse.presence(forMessage: "Signed in · no usage data yet", connected: false) == .signedIn)
        #expect(ServiceUse.presence(forMessage: "Key works (12 models) · Google reports usage only in AI Studio", connected: false) == .signedIn)
        #expect(!ServiceUse.inUse(.signedIn))
        #expect(!ServiceUse.inUse(.installOnly))
        #expect(!ServiceUse.inUse(.absent))
        #expect(ServiceUse.inUse(.liveReading))
    }

    @Test func aZeroQuotaOrAModelListIsNotRecentUse() {
        #expect(!ServiceUse.recentUse([.init(label: "5H", amount: 0, isQuota: true)], localServer: false))
        #expect(ServiceUse.recentUse([.init(label: "5H", amount: 12, isQuota: true)], localServer: false))
        #expect(ServiceUse.recentUse([.init(label: "7D", amount: 1_000, isQuota: false)], localServer: false))
        #expect(!ServiceUse.recentUse([
            .init(label: "INSTALLED", amount: 4, isQuota: false),
            .init(label: "LOADED", amount: 0, isQuota: false),
        ], localServer: true))
        #expect(ServiceUse.recentUse([
            .init(label: "INSTALLED", amount: 4, isQuota: false),
            .init(label: "LOADED", amount: 1, isQuota: false),
        ], localServer: true))
        #expect(!ServiceUse.recentUse([.init(label: "MODELS", amount: 6, isQuota: false)], localServer: true))
    }

    @Test func localServersAreProbedWhenInstalled() {
        #expect(ServiceUse.shouldProbe(localServer: true, installed: true, display: .auto, enabled: false))
        #expect(!ServiceUse.shouldProbe(localServer: true, installed: true, display: .hidden, enabled: false))
        #expect(!ServiceUse.shouldProbe(localServer: false, installed: true, display: .auto, enabled: false))
        #expect(ServiceUse.shouldProbe(localServer: false, installed: false, display: .auto, enabled: true))
        #expect(ServiceUse.shouldProbe(localServer: true, installed: false, display: .always, enabled: true))
    }
}
