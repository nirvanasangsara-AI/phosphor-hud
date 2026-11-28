import Testing
@testable import PhosphorCore

@Suite struct ServiceUseTests {
    @Test func autoShowsOnlyRealUse() {
        #expect(ServiceUse.shown(display: .auto, inUse: true))
        #expect(!ServiceUse.shown(display: .auto, inUse: false))
        #expect(ServiceUse.shown(display: .always, inUse: false))
        #expect(!ServiceUse.shown(display: .hidden, inUse: true))
        #expect(ServiceUse.Display.newInstall == .auto)
    }

    @Test func installTextIsNotASignup() {
        #expect(ServiceUse.presence(forMessage: "Installed (bin amp) · no usage API — hover for billing screen", connected: false) == .installOnly)
        #expect(ServiceUse.presence(forMessage: "Installed · no token usage in its logs (35 days)", connected: false) == .installOnly)
        #expect(ServiceUse.presence(forMessage: "GitHub CLI not logged in", connected: false) == .installOnly)
        #expect(ServiceUse.presence(forMessage: "Muse Code not signed in", connected: false) == .installOnly)
        #expect(ServiceUse.presence(forMessage: "No usage API · plan/price from its billing screen (hover)", connected: false) == .signedIn)
        #expect(ServiceUse.presence(forMessage: "Signed in · no usage data yet", connected: false) == .signedIn)
        #expect(ServiceUse.presence(forMessage: "Key works (12 models) · Google reports usage only in AI Studio", connected: false) == .signedIn)
        #expect(ServiceUse.inUse(.liveReading))
        #expect(!ServiceUse.inUse(.installOnly))
        #expect(!ServiceUse.inUse(.absent))
    }
}
