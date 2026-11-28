import Foundation

/// In-app language preference. English is the default; "system" follows macOS preferred languages.
public enum AppLanguage: String, CaseIterable, Sendable {
    case english
    case korean
    case system

    /// Resolve to a concrete language. "system" becomes Korean when a `ko` locale is preferred, otherwise English.
    public func resolve(preferredLanguages: [String] = Locale.preferredLanguages) -> ResolvedLanguage {
        switch self {
        case .english: return .english
        case .korean: return .korean
        case .system:
            // First preferred language wins, matching macOS's primary locale.
            if let first = preferredLanguages.first, first.lowercased().hasPrefix("ko") { return .korean }
            return .english
        }
    }
}

public enum ResolvedLanguage: String, Sendable {
    case english
    case korean

    var locale: Locale {
        switch self {
        case .english: return Locale(identifier: "en_US")
        case .korean: return Locale(identifier: "ko_KR")
        }
    }
}

/// UI copy for menus, settings, and burn-rate / depletion descriptions. Placeholders are `{0}`, `{1}`, …
public enum L10n {
    public static func text(_ key: String, language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages,
                            _ args: String...) -> String {
        text(key, language: language, preferredLanguages: preferredLanguages, args)
    }

    public static func text(_ key: String, language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages,
                            _ args: [String]) -> String {
        text(key, resolved: language.resolve(preferredLanguages: preferredLanguages), args)
    }

    public static func text(_ key: String, resolved: ResolvedLanguage, _ args: [String] = []) -> String {
        var s = table[resolved]?[key] ?? table[.english]?[key] ?? key
        for (i, a) in args.enumerated() {
            s = s.replacingOccurrences(of: "{\(i)}", with: a)
        }
        return s
    }

    public static func clock(_ date: Date, now: Date = Date(), language: AppLanguage,
                             preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        clock(date, now: now, resolved: language.resolve(preferredLanguages: preferredLanguages))
    }

    public static func ago(_ date: Date, now: Date = Date(), language: AppLanguage,
                           preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        ago(date, now: now, resolved: language.resolve(preferredLanguages: preferredLanguages))
    }

    public static func ago(_ date: Date, now: Date = Date(), resolved: ResolvedLanguage) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 45 { return text("ticker.now", resolved: resolved) }
        if seconds < 3600 { return text("ticker.minutes", resolved: resolved, ["\(max(1, seconds / 60))"]) }
        if seconds < 86_400 { return text("ticker.hours", resolved: resolved, ["\(max(1, seconds / 3600))"]) }
        return text("ticker.days", resolved: resolved, ["\(max(1, seconds / 86_400))"])
    }

    public static func clock(_ date: Date, now: Date = Date(), resolved: ResolvedLanguage) -> String {
        let f = DateFormatter()
        f.locale = resolved.locale
        f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }

    public static func countdown(to date: Date?, now: Date = Date(), language: AppLanguage,
                                 preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        countdown(to: date, now: now, resolved: language.resolve(preferredLanguages: preferredLanguages))
    }

    public static func countdown(to date: Date?, now: Date = Date(), resolved: ResolvedLanguage) -> String {
        guard let date else { return "" }
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return text("time.now", resolved: resolved) }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return text("time.daysHours", resolved: resolved, ["\(d)", "\(h)"]) }
        if h > 0 { return text("time.hoursMinutes", resolved: resolved, ["\(h)", "\(m)"]) }
        return text("time.minutes", resolved: resolved, ["\(m)"])
    }

    public static func displayDetail(_ raw: String, language: AppLanguage,
                                     preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let resolved = language.resolve(preferredLanguages: preferredLanguages)
        if raw.hasPrefix("l10n:"), let key = raw.split(separator: ":", maxSplits: 1).last {
            return text(String(key), resolved: resolved)
        }
        if raw.hasPrefix("unpriced:") {
            return text("logs.unpriced", resolved: resolved, [String(raw.dropFirst(9))])
        }
        return raw
    }

    /// True when the English and Korean tables define the same keys.
    public static var tablesMatch: Bool { Set(en.keys) == Set(ko.keys) }

    /// Language-agnostic token-wait marker, plus the pre-localization Korean prefix.
    public static func isTokenWaitMarker(_ message: String) -> Bool {
        message.hasPrefix("token-refresh-waiting") || message.hasPrefix("토큰 갱신 대기")
    }

    public static func staleText(_ raw: String, now: Date = Date(), language: AppLanguage,
                                 preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let resolved = language.resolve(preferredLanguages: preferredLanguages)
        if raw.hasPrefix("cached:"), let t = TimeInterval(raw.dropFirst(7)) {
            return text("stale.cached", resolved: resolved, [clock(Date(timeIntervalSince1970: t), now: now, resolved: resolved)])
        }
        if raw == "logs" { return text("stale.logs", resolved: resolved) }
        return raw
    }

    /// Known API credit titles (e.g. Codex "사용량 초기화") shown in the selected language.
    public static func creditTitle(_ raw: String, language: AppLanguage,
                                   preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let resolved = language.resolve(preferredLanguages: preferredLanguages)
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key = creditTitleKeys[n] ?? creditTitleKeys[n.lowercased()] {
            return text(key, resolved: resolved)
        }
        return raw
    }
}

private let table: [ResolvedLanguage: [String: String]] = [
    .english: en,
    .korean: ko,
]

/// Aliases used by provider APIs, keyed as stored (or lowercased for Latin titles).
private let creditTitleKeys: [String: String] = [
    "사용량 초기화": "credit.usageReset",
    "usage reset": "credit.usageReset",
]

private let en: [String: String] = [
    // Forecast / depletion
    "forecast.limit": "▲ limit {0} · in {1}",
    "forecast.atReset": "≈ {0}% at reset",
    "forecast.rateOnly": "+{0}%/h",
    "forecast.steadyAtReset": "steady · ≈ {0}% at reset",
    "forecast.steady": "steady",
    "forecast.measuring": "measuring pace",
    "forecast.limitReachedIn": "▲ limit reached · in {0}",
    "forecast.limitReached": "▲ limit reached",
    "forecast.noSession": "no active session",
    "forecast.rate": "+{0}%/h",
    "forecast.rateIdle": "0%/h",
    "pace.ahead": "{0} points ahead of pace — you're burning fast.",
    "pace.under": "{0} points under pace — you have room.",
    "pace.on": "Right on pace.",
    "pace.help": "Pace marker: spreading usage evenly over this window, you'd be at {0}% by now. You're at {1}%. {2}",
    "sparkline.help": "Last 7 days",
    "sparkline.access": "Weekly trend",
    "raid.outBy": "Out by {0}",
    "log.runsDry": "{0} {1} runs dry at {2}",
    "time.now": "now",
    "time.daysHours": "{0}d {1}h",
    "time.hoursMinutes": "{0}h {1}m",
    "time.minutes": "{0}m",

    // Stale / token wait (display only; internal markers stay English)
    "stale.cached": "cached {0} · waiting for token refresh · local logs kept",
    "stale.logs": "from local logs · waiting for token refresh · local logs kept",
    "stale.help": "Waiting for token refresh · local logs active. Claude Code renews its own token the next time it runs; Phosphor does not write that Keychain item. These bars are the last live reading or local log usage.",
    "status.signedIn": "signed in",
    "raid.signedIn": "Signed in",

    // Hide / settings (HUD)
    "hide.action": "Hide — {0}",
    "hide.actionNamed": "Hide — {0}",
    "hide.button": "Hide",
    "hide.help": "Hide this service (restore from Show hidden services)",
    "hidden.count": "Hidden services {0}",
    "hidden.help": "Show hidden services and turn any of them back on",
    "hidden.title": "Visible services",
    "hidden.body": "Hidden providers are left out of the HUD, the menu-bar % and the monthly total. Turn any of them back on here.",
    "hidden.badge": "Hidden",
    "ollama.installed": "installed · models on disk",
    "ollama.loaded": "running · currently loaded in memory",
    "logs.apiEquivalent": "API-equivalent from local logs",
    "logs.unpriced": "{0} tokens unpriced",
    "logs.priceMissing": "price table not loaded · retrying",
    "logs.priceBanner": "Price table not loaded · retrying",
    "logs.bundledPrices": "bundled prices ({0})",
    "dev.thisWeek": "This week {0} PRs",
    "dev.today": "today {0}",
    "dev.thirty": "30d {0} PRs · avg {1}/wk",
    "dev.updated": "updated {0}",
    "dev.clickRefresh": "Click to refresh GitHub counts",
    "dev.unknownAccount": "GitHub account @{0} was not found",
    "dev.localRoots": "Local git commits (your email, {0} repos, not deduped with GitHub). Roots: {1}. 7D {2} · 30D {3}",
    "menu.githubAccount": "GitHub account: @{0}…",
    "menu.githubAccountUnset": "GitHub account…",
    "menu.githubAccountTitle": "GitHub account",
    "menu.githubAccountHelp": "Leave blank to use the account gh is signed in as. Phosphor never reads token files.",
    "menu.githubSave": "Save",
    "menu.githubCancel": "Cancel",
    "menu.githubCurrent": "Use current gh login",
    "menu.githubOther": "Other account…",
    "menu.repoRoots": "Local repo folders…",
    "menu.repoRootsReset": "Reset repo folders to defaults",
    "credit.usageReset": "Usage Reset",

    // Menu / settings
    "menu.hideHUD": "Hide HUD",
    "menu.showHUD": "Show HUD",
    "menu.refreshNow": "Refresh now",
    "menu.theme": "Theme",
    "menu.openThemes": "Open Themes Folder…",
    "menu.compact": "Compact",
    "menu.opacity": "Opacity",
    "menu.clickThrough": "Click-through (hold ⌥ to move · undo here)",
    "menu.language": "Language",
    "lang.english": "English",
    "lang.korean": "한국어",
    "lang.system": "System (macOS)",
    "menu.visibleServices": "Visible services",
    "menu.resetWindowSize": "Reset window size (auto-fit)",
    "menu.connect": "Connect {0}…",
    "menu.installedOnMac": "Installed on this Mac",
    "menu.notFound": "Not found",
    "menu.notInstalled": "not installed",
    "menu.rescan": "Rescan installed tools",
    "menu.moreProviders": "More Providers ({0} found of {1})",
    "menu.extraAccounts": "Extra Accounts ({0})",
    "menu.editAccounts": "Edit accounts.json…",
    "menu.showUnavailable": "Show not-connected providers",
    "menu.addCustom": "Add custom provider…",
    "menu.resetOrder": "Reset Order (drag ≡ on a row to reorder)",
    "menu.claudeResets": "Read Claude reset credits (uses your Claude login outside Claude Code)",
    "menu.downloadLogos": "Download Official Logos",
    "menu.removeLogos": "Remove Downloaded Logos",
    "menu.providers": "Providers",
    "menu.chart": "Usage chart (local logs)",
    "menu.devStats": "GitHub PRs & efficiency (gh, read-only)",
    "menu.showResetTicker": "Show reset ticker",
    "menu.includeRumors": "Include rumors",
    "menu.resetFeedURL": "Reset feed URL…",
    "menu.resetFeedTitle": "Reset feed URL",
    "menu.resetFeedHelp": "Leave blank to use the public status feeds. Paste a Cloudflare Worker /feed.json URL for posts and rumors.",
    "menu.iconColor": "Icon colour based on",
    "menu.iconPace": "Pace (fill the quota by reset)",
    "menu.iconUsage": "Usage percent",
    "ticker.rumor": "Rumor",
    "ticker.help": "Usage-limit reset news. Click to open the source.",
    "ticker.now": "now",
    "ticker.minutes": "{0}m",
    "ticker.hours": "{0}h",
    "ticker.days": "{0}d",
    "ticker.until": "until {0}",
    "menu.phoneSync": "Phone sync (same Wi-Fi)…",
    "phone.title": "Phone sync",
    "phone.enable": "Share on this Wi-Fi",
    "phone.help": "Same Wi-Fi only. The phone stores a pairing token, not your logins. Off until you turn this on.",
    "phone.newCode": "New code",
    "phone.forget": "Forget phones",
    "phone.off": "Off",
    "menu.saveReceipt": "Save Monthly Receipt (PNG, copied)",
    "menu.warnAt": "Warning at {0}%",
    "menu.criticalAt": "Critical at {0}%",
    "menu.windowReset": "Window reset (from ≥{0}%)",
    "menu.billDue": "Bill due ({0} days before)",
    "menu.billDueOne": "Bill due ({0} day before)",
    "menu.creditExpiry": "Reset credit expiring ({0} days before)",
    "menu.editAlerts": "Edit thresholds (alerts.json)…",
    "menu.notifications": "Notifications",
    "menu.billingStale": "⚠︎ Billing screens need refresh: {0}",
    "menu.calendarExport": "Calendar export ({0} events)…",
    "menu.refreshEvery": "Refresh every",
    "menu.every1": "1 min",
    "menu.every3": "3 min",
    "menu.every5": "5 min",
    "menu.every10": "10 min",
    "menu.launchAtLogin": "Launch at login",
    "menu.quit": "Quit Phosphor",
    "menu.hideProvider": "Hide — {0}",
]

private let ko: [String: String] = [
    "forecast.limit": "▲ 한도 {0} · {1} 후",
    "forecast.atReset": "리셋 시 ≈ {0}%",
    "forecast.rateOnly": "+{0}%/h",
    "forecast.steadyAtReset": "안정 · 리셋 시 ≈ {0}%",
    "forecast.steady": "안정",
    "forecast.measuring": "속도 측정 중",
    "forecast.limitReachedIn": "▲ 한도 도달 · {0} 후",
    "forecast.limitReached": "▲ 한도 도달",
    "forecast.noSession": "활성 세션 없음",
    "forecast.rate": "+{0}%/h",
    "forecast.rateIdle": "0%/h",
    "pace.ahead": "고른 속도보다 {0}%p 빨라 소진이 빠릅니다.",
    "pace.under": "고른 속도보다 {0}%p 여유가 있습니다.",
    "pace.on": "고른 속도와 비슷합니다.",
    "pace.help": "페이스 표시: 이 창 동안 고르게 쓰면 지금은 {0}%여야 합니다. 현재 {1}%. {2}",
    "sparkline.help": "최근 7일",
    "sparkline.access": "주간 추이",
    "raid.outBy": "{0}까지 소진",
    "log.runsDry": "{0} {1} 한도 도달 시각 {2}",
    "time.now": "지금",
    "time.daysHours": "{0}일 {1}시간",
    "time.hoursMinutes": "{0}시간 {1}분",
    "time.minutes": "{0}분",

    "stale.cached": "캐시 {0} · 토큰 갱신 대기 · 로컬 로그 유지",
    "stale.logs": "로컬 로그 · 토큰 갱신 대기 · 로컬 로그 유지",
    "stale.help": "토큰 갱신 대기 · 로컬 로그 유지. Claude Code가 다음에 실행될 때 토큰을 갱신합니다. Phosphor는 해당 키체인 항목을 쓰지 않습니다. 이 막대는 마지막 실시간 값 또는 로컬 로그 사용량입니다.",
    "status.signedIn": "로그인됨",
    "raid.signedIn": "로그인됨",

    "hide.action": "숨기기 — {0}",
    "hide.actionNamed": "숨기기 — {0}",
    "hide.button": "숨기기",
    "hide.help": "이 서비스를 숨깁니다 (숨긴 서비스 보기에서 다시 켤 수 있습니다)",
    "hidden.count": "숨긴 서비스 {0}",
    "hidden.help": "숨긴 서비스를 보고 다시 켭니다",
    "hidden.title": "표시할 서비스",
    "hidden.body": "숨긴 서비스는 HUD, 메뉴 막대 %, 월 합계에서 빠집니다. 여기에서 다시 켤 수 있습니다.",
    "hidden.badge": "숨김",
    "ollama.installed": "설치됨 · 디스크의 모델",
    "ollama.loaded": "실행 중 · 메모리에 로드됨",
    "logs.apiEquivalent": "로컬 로그 기준 API 환산",
    "logs.unpriced": "가격 없는 토큰 {0}",
    "logs.priceMissing": "가격표를 불러오지 못함 · 다시 시도 중",
    "logs.priceBanner": "가격표를 불러오지 못함 · 다시 시도 중",
    "logs.bundledPrices": "포함된 가격표 ({0})",
    "dev.thisWeek": "이번 주 PR {0}개",
    "dev.today": "오늘 {0}",
    "dev.thirty": "30일 PR {0}개 · 주평균 {1}",
    "dev.updated": "갱신 {0}",
    "dev.clickRefresh": "클릭하면 GitHub 수치를 다시 읽습니다",
    "dev.unknownAccount": "GitHub 계정 @{0}을 찾지 못했습니다",
    "dev.localRoots": "로컬 git 커밋 (내 이메일, 저장소 {0}개, GitHub와 중복 제거 안 함). 폴더: {1}. 7일 {2} · 30일 {3}",
    "menu.githubAccount": "GitHub 계정: @{0}…",
    "menu.githubAccountUnset": "GitHub 계정…",
    "menu.githubAccountTitle": "GitHub 계정",
    "menu.githubAccountHelp": "비워 두면 gh에 로그인된 계정을 씁니다. 토큰 파일은 읽지 않습니다.",
    "menu.githubSave": "저장",
    "menu.githubCancel": "취소",
    "menu.githubCurrent": "현재 gh 로그인 사용",
    "menu.githubOther": "다른 계정…",
    "menu.repoRoots": "로컬 저장소 폴더…",
    "menu.repoRootsReset": "저장소 폴더를 기본값으로",
    "credit.usageReset": "사용량 초기화",

    "menu.hideHUD": "HUD 숨기기",
    "menu.showHUD": "HUD 보기",
    "menu.refreshNow": "지금 새로고침",
    "menu.theme": "테마",
    "menu.openThemes": "테마 폴더 열기…",
    "menu.compact": "컴팩트",
    "menu.opacity": "불투명도",
    "menu.clickThrough": "클릭 통과 (이동은 ⌥, 해제는 여기)",
    "menu.language": "언어",
    "lang.english": "English",
    "lang.korean": "한국어",
    "lang.system": "시스템 (macOS)",
    "menu.visibleServices": "표시할 서비스",
    "menu.resetWindowSize": "창 크기 재설정 (자동 맞춤)",
    "menu.connect": "{0}에 연결…",
    "menu.installedOnMac": "이 Mac에 설치됨",
    "menu.notFound": "찾을 수 없음",
    "menu.notInstalled": "설치되지 않음",
    "menu.rescan": "설치된 도구 다시 검색",
    "menu.moreProviders": "다른 서비스 ({0} / {1}개 발견)",
    "menu.extraAccounts": "추가 계정 ({0})",
    "menu.editAccounts": "accounts.json 편집…",
    "menu.showUnavailable": "연결되지 않은 서비스 표시",
    "menu.addCustom": "사용자 지정 서비스 추가…",
    "menu.resetOrder": "순서 재설정 (≡를 끌어 재정렬)",
    "menu.claudeResets": "Claude 리셋 크레딧 읽기 (Claude Code 외부 로그인 사용)",
    "menu.downloadLogos": "공식 로고 다운로드",
    "menu.removeLogos": "받은 로고 삭제",
    "menu.providers": "서비스",
    "menu.chart": "사용량 차트 (로컬 로그)",
    "menu.devStats": "GitHub PR·효율 (gh, 읽기 전용)",
    "menu.showResetTicker": "리셋 소식 표시",
    "menu.includeRumors": "루머 포함",
    "menu.resetFeedURL": "리셋 피드 주소…",
    "menu.resetFeedTitle": "리셋 피드 주소",
    "menu.resetFeedHelp": "비워 두면 공개 상태 피드를 씁니다. 글과 루머는 Cloudflare Worker의 /feed.json 주소를 붙입니다.",
    "menu.iconColor": "아이콘 색 기준",
    "menu.iconPace": "페이스 (리셋 직전에 한도를 채움)",
    "menu.iconUsage": "사용량 %",
    "ticker.rumor": "루머",
    "ticker.help": "사용량 한도 리셋 소식. 클릭하면 출처가 열립니다.",
    "ticker.now": "방금",
    "ticker.minutes": "{0}분",
    "ticker.hours": "{0}시간",
    "ticker.days": "{0}일",
    "ticker.until": "{0} 후",
    "menu.phoneSync": "폰 동기화 (같은 Wi-Fi)…",
    "phone.title": "폰 동기화",
    "phone.enable": "이 Wi-Fi에서 공유",
    "phone.help": "같은 Wi-Fi에서만 연결됩니다. 폰에는 페어링 토큰만 저장되고, 로그인 정보는 가지 않습니다. 켜기 전에는 동작하지 않습니다.",
    "phone.newCode": "새 코드",
    "phone.forget": "폰 연결 해제",
    "phone.off": "꺼짐",
    "menu.saveReceipt": "월간 영수증 저장 (PNG, 복사됨)",
    "menu.warnAt": "경고 {0}%",
    "menu.criticalAt": "위험 {0}%",
    "menu.windowReset": "창 리셋 (≥{0}%에서)",
    "menu.billDue": "결제 예정 ({0}일 전)",
    "menu.billDueOne": "결제 예정 ({0}일 전)",
    "menu.creditExpiry": "리셋 크레딧 만료 ({0}일 전)",
    "menu.editAlerts": "임계값 편집 (alerts.json)…",
    "menu.notifications": "알림",
    "menu.billingStale": "⚠︎ 결제 화면을 다시 읽어야 합니다: {0}",
    "menu.calendarExport": "캘린더 보내기 ({0}개)…",
    "menu.refreshEvery": "새로고침 주기",
    "menu.every1": "1분",
    "menu.every3": "3분",
    "menu.every5": "5분",
    "menu.every10": "10분",
    "menu.launchAtLogin": "로그인 시 실행",
    "menu.quit": "Phosphor 종료",
    "menu.hideProvider": "숨기기 — {0}",
]
