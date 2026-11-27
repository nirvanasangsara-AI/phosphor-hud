import Foundation
import Testing
@testable import PhosphorCore

@Suite struct L10nTests {
    @Test func defaultEnglishPreferenceIgnoresSystemKorean() {
        let resolved = AppLanguage.english.resolve(preferredLanguages: ["ko-KR", "en-US"])
        #expect(resolved == .english)
        #expect(L10n.text("forecast.measuring", language: .english, preferredLanguages: ["ko-KR"])
                == "measuring pace")
    }

    @Test func koreanPreferenceUsesKoreanCopy() {
        #expect(L10n.text("forecast.measuring", language: .korean) == "속도 측정 중")
        #expect(L10n.text("forecast.noSession", language: .korean) == "활성 세션 없음")
        #expect(L10n.text("forecast.limitReached", language: .korean) == "▲ 한도 도달")
    }

    @Test func systemFollowsPreferredLanguages() {
        #expect(AppLanguage.system.resolve(preferredLanguages: ["ko-KR"]) == .korean)
        #expect(AppLanguage.system.resolve(preferredLanguages: ["en-US", "ko"]) == .english)
        #expect(AppLanguage.system.resolve(preferredLanguages: ["ja-JP"]) == .english)
        #expect(L10n.text("forecast.steady", language: .system, preferredLanguages: ["ko"]) == "안정")
        #expect(L10n.text("forecast.steady", language: .system, preferredLanguages: ["en"]) == "steady")
    }

    @Test func burnRateLinesLocalizePlaceholders() {
        let en = L10n.text("forecast.limit", language: .english, "15:20", "1h 21m")
        #expect(en == "▲ limit 15:20 · in 1h 21m")
        let ko = L10n.text("forecast.limit", language: .korean, "15:20", "1시간 21분")
        #expect(ko == "▲ 한도 15:20 · 1시간 21분 후")
        #expect(L10n.text("forecast.atReset", language: .korean, "83") == "리셋 시 ≈ 83%")
        #expect(L10n.text("forecast.steadyAtReset", language: .english, "72") == "steady · ≈ 72% at reset")
    }

    @Test func countdownAndClockFollowLanguage() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let in90m = now.addingTimeInterval(90 * 60)
        #expect(L10n.countdown(to: in90m, now: now, language: .english) == "1h 30m")
        #expect(L10n.countdown(to: in90m, now: now, language: .korean) == "1시간 30분")
        #expect(L10n.countdown(to: now.addingTimeInterval(-10), now: now, language: .korean) == "지금")
        let tomorrow = now.addingTimeInterval(26 * 3600)
        let enClock = L10n.clock(tomorrow, now: now, language: .english)
        let koClock = L10n.clock(tomorrow, now: now, language: .korean)
        #expect(enClock != koClock)
        #expect(koClock.contains(":") )
    }

    @Test func englishAndKoreanTablesHaveTheSameKeys() {
        #expect(L10n.tablesMatch)
    }

    @Test func tokenWaitMarkerRecognizesNewAndLegacyPrefixes() {
        #expect(L10n.isTokenWaitMarker("token-refresh-waiting expired 1700000000"))
        #expect(L10n.isTokenWaitMarker("토큰 갱신 대기 · 로컬 로그 유지 · leftover"))
        #expect(!L10n.isTokenWaitMarker("cached:1700000000"))
        #expect(!L10n.isTokenWaitMarker("from local logs"))
    }
}
