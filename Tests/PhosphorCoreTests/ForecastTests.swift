import Foundation
import Testing
@testable import PhosphorCore

@Suite struct ForecastTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let reset = Date(timeIntervalSince1970: 1_700_000_000 + 3 * 3600)

    private func sample(minutesAgo: Double, used: Double, reset r: Date? = nil) -> ForecastSample {
        ForecastSample(t: now.timeIntervalSince1970 - minutesAgo * 60, u: used,
                       r: (r ?? reset).timeIntervalSince1970)
    }

    @Test func twoSamplesTenMinutesApartYieldARate() {
        // After a mid-cycle drop, two 10-minute polls (23% → 24%) should show a rate immediately.
        let week = now.addingTimeInterval(604_800)
        let samples = [
            sample(minutesAgo: 10, used: 23, reset: week),
            sample(minutesAgo: 0, used: 24, reset: week),
        ]
        let f = QuotaForecast.make(usedPercent: 24, resetsAt: week, windowSeconds: 604_800,
                                   samples: samples, now: now)
        #expect(f.kind == .rate)
        #expect(abs(f.ratePerHour - 6) < 0.01)
        #expect(f.warnsBeforeReset)
        #expect(f.hitsLimitAt != nil)
        #expect(f.atReset == 100)
    }

    @Test func twoSamplesAtMinSpanAreEnough() {
        let samples = [
            sample(minutesAgo: 5, used: 10),
            sample(minutesAgo: 0, used: 10.5),
        ]
        let f = QuotaForecast.make(usedPercent: 10.5, resetsAt: reset, windowSeconds: 18_000,
                                   samples: samples, now: now)
        #expect(f.kind == .rate)
        #expect(abs(f.ratePerHour - 6) < 0.01)
    }

    @Test func spanShorterThanFiveMinutesStaysMeasuring() {
        let samples = [
            sample(minutesAgo: 4, used: 10),
            sample(minutesAgo: 0, used: 11),
        ]
        let f = QuotaForecast.make(usedPercent: 11, resetsAt: reset, windowSeconds: 18_000,
                                   samples: samples, now: now)
        #expect(f.kind == .measuring)
        #expect(f.ratePerHour == 0)
        #expect(!f.warnsBeforeReset)
        #expect(f.atReset == 11)
    }

    @Test func singleSampleIsMeasuring() {
        let f = QuotaForecast.make(usedPercent: 23, resetsAt: reset, windowSeconds: 604_800,
                                   samples: [sample(minutesAgo: 0, used: 23)], now: now)
        #expect(f.kind == .measuring)
        #expect(f.ratePerHour == 0)
        #expect(f.atReset == 23)
    }

    @Test func noSamplesYetIsMeasuring() {
        let f = QuotaForecast.make(usedPercent: 40, resetsAt: reset, windowSeconds: 18_000,
                                   samples: [], now: now)
        #expect(f.kind == .measuring)
        #expect(f.ratePerHour == 0)
    }

    @Test func dropClearsEarlierPointsThenFitsTheNewCycle() {
        // 72% plateau, then a same-cycle cliff to 23% / 24% — only the post-drop pair should be fitted.
        let samples = [
            sample(minutesAgo: 40, used: 72),
            sample(minutesAgo: 20, used: 72),
            sample(minutesAgo: 10, used: 23),
            sample(minutesAgo: 0, used: 24),
        ]
        let f = QuotaForecast.make(usedPercent: 24, resetsAt: reset, windowSeconds: 604_800,
                                   samples: samples, now: now)
        #expect(f.kind == .rate)
        #expect(abs(f.ratePerHour - 6) < 0.01)
    }

    @Test func dropWithOnlyOneNewSampleIsMeasuring() {
        let samples = [
            sample(minutesAgo: 20, used: 72),
            sample(minutesAgo: 0, used: 23),
        ]
        let f = QuotaForecast.make(usedPercent: 23, resetsAt: reset, windowSeconds: 604_800,
                                   samples: samples, now: now)
        #expect(f.kind == .measuring)
        #expect(f.atReset == 23)
    }

    @Test func idleSlopeIsSteadyAtCurrentUsage() {
        let samples = [
            sample(minutesAgo: 40, used: 50),
            sample(minutesAgo: 20, used: 50.05),
            sample(minutesAgo: 0, used: 50.1),
        ]
        let f = QuotaForecast.make(usedPercent: 50.1, resetsAt: reset, windowSeconds: 18_000,
                                   samples: samples, now: now)
        #expect(f.kind == .steady)
        #expect(f.ratePerHour == 0)
        #expect(f.atReset == 50.1)
        #expect(!f.warnsBeforeReset)
    }

    @Test func flatZeroUsageIsSteady() {
        let samples = (0...6).map { i in sample(minutesAgo: Double(60 - i * 10), used: 0) }
        let f = QuotaForecast.make(usedPercent: 0, resetsAt: reset, windowSeconds: 18_000,
                                   samples: samples, now: now)
        #expect(f.kind == .steady)
        #expect(f.ratePerHour == 0)
    }

    @Test func atCapIsLimitReachedEvenWithNoSamples() {
        let f = QuotaForecast.make(usedPercent: 100, resetsAt: reset, windowSeconds: 604_800,
                                   samples: [], now: now)
        #expect(f.kind == .limitReached)
        #expect(f.atReset == 100)
        #expect(f.hitsLimitAt == now)
        #expect(!f.warnsBeforeReset)
    }

    @Test func overCapIsLimitReached() {
        let f = QuotaForecast.make(usedPercent: 100.4, resetsAt: reset, windowSeconds: 18_000,
                                   samples: [sample(minutesAgo: 0, used: 100.4)], now: now)
        #expect(f.kind == .limitReached)
    }

    @Test func inactiveSessionIsNoSessionEvenWithSamples() {
        let samples = [
            sample(minutesAgo: 10, used: 0),
            sample(minutesAgo: 0, used: 0),
        ]
        let f = QuotaForecast.make(usedPercent: 0, resetsAt: nil, windowSeconds: 18_000,
                                   activeSession: false, samples: samples, now: now)
        #expect(f.kind == .noSession)
        #expect(f.ratePerHour == 0)
        #expect(f.hitsLimitAt == nil)
    }

    @Test func rateThatFitsBeforeResetWarns() {
        // +10%/h from 50% hits 100% in 5h; reset is in 8h, so it warns.
        let farReset = now.addingTimeInterval(8 * 3600)
        let samples = [
            ForecastSample(t: now.timeIntervalSince1970 - 3600, u: 40, r: farReset.timeIntervalSince1970),
            ForecastSample(t: now.timeIntervalSince1970, u: 50, r: farReset.timeIntervalSince1970),
        ]
        let f = QuotaForecast.make(usedPercent: 50, resetsAt: farReset, windowSeconds: 18_000,
                                   samples: samples, now: now)
        #expect(f.kind == .rate)
        #expect(abs(f.ratePerHour - 10) < 0.01)
        #expect(f.warnsBeforeReset)
        #expect(f.atReset == 100)
    }

    @Test func rateThatFitsAfterResetShowsProjectedUsage() {
        // +2%/h from 50% would take 25h to hit 100%; reset is in 3h → ≈ 56% at reset.
        let soon = now.addingTimeInterval(3 * 3600)
        let samples = [
            ForecastSample(t: now.timeIntervalSince1970 - 3600, u: 48, r: soon.timeIntervalSince1970),
            ForecastSample(t: now.timeIntervalSince1970, u: 50, r: soon.timeIntervalSince1970),
        ]
        let f = QuotaForecast.make(usedPercent: 50, resetsAt: soon, windowSeconds: 604_800,
                                   samples: samples, now: now)
        #expect(f.kind == .rate)
        #expect(abs(f.ratePerHour - 2) < 0.01)
        #expect(!f.warnsBeforeReset)
        #expect(f.atReset != nil)
        #expect(abs((f.atReset ?? 0) - 56) < 0.01)
    }
}
