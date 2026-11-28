import Foundation
import Testing
@testable import PhosphorCore

@Suite struct IconColorTests {
    @Test func paceBandsFollowTheProjectionAtReset() {
        #expect(IconColor.classifyPace(projectedAtReset: 85, exhaustsBeforeReset: false) == .green)
        #expect(IconColor.classifyPace(projectedAtReset: 110, exhaustsBeforeReset: false) == .green)
        #expect(IconColor.classifyPace(projectedAtReset: 100, exhaustsBeforeReset: false) == .green)
        #expect(IconColor.classifyPace(projectedAtReset: 84.9, exhaustsBeforeReset: false) == .yellow)
        #expect(IconColor.classifyPace(projectedAtReset: 110.1, exhaustsBeforeReset: false) == .red)
        #expect(IconColor.classifyPace(projectedAtReset: 90, exhaustsBeforeReset: true) == .red)
        #expect(IconColor.classifyPace(projectedAtReset: nil, exhaustsBeforeReset: false) == .neutral)
    }

    @Test func usageBandsArePlainPercent() {
        #expect(IconColor.usage(0) == .green)
        #expect(IconColor.usage(49.9) == .green)
        #expect(IconColor.usage(50) == .yellow)
        #expect(IconColor.usage(80) == .yellow)
        #expect(IconColor.usage(80.1) == .red)
    }

    @Test func measuringUsesElapsedTimeAndAFittedRateCanExhaustEarly() {
        let measuring = IconColor.pace(usedPercent: 20, elapsedFraction: 0.5, forecast: nil)
        #expect(measuring == .yellow) // 20 / 0.5 = 40, under the 85% green band

        let onTrack = IconColor.pace(usedPercent: 50, elapsedFraction: 0.5, forecast: nil)
        #expect(onTrack == .green) // projects to 100% at reset

        let tooSoon = IconColor.pace(usedPercent: 40, elapsedFraction: 0.2, forecast: nil)
        #expect(tooSoon == .red) // projects to 200%

        let early = IconColor.pace(usedPercent: 30, elapsedFraction: 0.02, forecast: nil)
        #expect(early == .neutral)

        let now = Date()
        let exhaust = Forecast(kind: .rate, hitsLimitAt: now.addingTimeInterval(600), ratePerHour: 40,
                               beforeReset: true, atReset: 100, resetsAt: now.addingTimeInterval(3600))
        #expect(IconColor.pace(usedPercent: 60, elapsedFraction: 0.4, forecast: exhaust) == .red)

        let steady = Forecast(kind: .steady, atReset: 40, resetsAt: now.addingTimeInterval(3600))
        #expect(IconColor.pace(usedPercent: 40, elapsedFraction: 0.5, forecast: steady) == .yellow)

        #expect(IconColor.pace(usedPercent: 100, elapsedFraction: 0.5,
                               forecast: Forecast(kind: .limitReached)) == .red)
        #expect(IconColor.band(mode: .usage, usedPercent: 90, elapsedFraction: nil,
                               forecast: Forecast(kind: .steady, atReset: 90)) == .red)
    }
}
