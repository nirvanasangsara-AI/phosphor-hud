import Foundation
import PhosphorCore

/// App-side lookup using the user's language preference. Views that call this must also
/// observe `Prefs.shared` (or the relevant `@Published` property) so a language change redraws.
enum T {
    static var language: AppLanguage { Prefs.shared.appLanguage }

    static func t(_ key: String, _ args: String...) -> String {
        L10n.text(key, language: language, args)
    }

    static func clock(_ date: Date, now: Date = Date()) -> String {
        L10n.clock(date, now: now, language: language)
    }

    static func countdown(to date: Date?, now: Date = Date()) -> String {
        L10n.countdown(to: date, now: now, language: language)
    }

    static func detail(_ raw: String) -> String {
        L10n.displayDetail(raw, language: language)
    }

    static func stale(_ raw: String, now: Date = Date()) -> String {
        L10n.staleText(raw, now: now, language: language)
    }

    static func credit(_ raw: String) -> String {
        L10n.creditTitle(raw, language: language)
    }
}
