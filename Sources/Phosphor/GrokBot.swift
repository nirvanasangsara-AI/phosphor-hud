import Foundation

// MARK: - Grok Bot (the Grok Bot desktop app's own plan, separate from SuperGrok / Grok CLI)

/// The Grok Bot desktop app keeps its last plan-usage reading in a small JSON file it writes
/// itself, under ~/Library/Application Support/Grok Bot/sand-client-persistence/. File names are
/// the base32 of a key such as `sand.client.slice.account.<account>.weekly-usage.cache`. Shape:
///   {"schemaVersion":3,"value":{"kind":"present","reading":{"usage":{"percentUsed":10.7,
///     "nextResetMs":…,"onDemand":{"usedCents":0,"limitCents":100},"grokPlanLabel":"Grok Bot Plan",
///     "isSandTrial":false,"isTeamSeat":false},"readAtMs":…},"expiresAtMs":…}}
/// Phosphor only reads that file. It never opens the app's cookies, session or secrets files and
/// makes no network request: the numbers are as fresh as the app's last refresh (the app must
/// have run recently).
struct GrokBotSource: UsageSource {
    let info = ProviderInfo.lookup("grokbot")

    static var folder: URL {
        Paths.home.appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence")
    }

    static let usageSuffix = ".weekly-usage.cache"
    static let accountSlotKey = "sand.client.slice.client-meta.account-slot"

    func fetch() async -> [ProviderSnapshot] {
        await single(info) {
            let (windows, plan) = try Self.read()
            return (windows, plan)
        }
    }

    /// The usage cache for the account the app is signed in to now, or the newest one.
    static func usageFile() -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
        var keyed: [(key: String, url: URL)] = []
        for name in names where name.hasSuffix(".blob") {
            guard let key = Base32.decode(String(name.dropLast(5))) else { continue }
            keyed.append((key, folder.appendingPathComponent(name)))
        }
        let usage = keyed.filter { $0.key.hasSuffix(usageSuffix) }
        guard !usage.isEmpty else { return nil }
        if let slot = keyed.first(where: { $0.key == accountSlotKey }),
           let account = readJSONFile(slot.url)?["value"] as? String,
           let encoded = account.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))),
           let match = usage.first(where: { $0.key.contains(".\(encoded).") || $0.key.contains(".\(account).") }) {
            return match.url
        }
        func mtime(_ u: URL) -> Date {
            ((try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date) ?? .distantPast
        }
        return usage.map(\.url).max { mtime($0) < mtime($1) }
    }

    static func read(now: Date = Date()) throws -> ([UsageWindow], String?) {
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw ProviderError.notConfigured("Grok Bot app not installed")
        }
        guard let file = usageFile(), let obj = readJSONFile(file) else {
            throw ProviderError.notConfigured("Open Grok Bot once to load its usage")
        }
        return try parse(obj, now: now)
    }

    static func parse(_ obj: [String: Any], now: Date = Date()) throws -> ([UsageWindow], String?) {
        let value = obj["value"] as? [String: Any] ?? [:]
        guard (value["kind"] as? String) == "present",
              let reading = value["reading"] as? [String: Any],
              let usage = reading["usage"] as? [String: Any] else {
            throw ProviderError.idle("Open Grok Bot to load usage")
        }
        let plan = planLabel(usage)
        guard let used = num(usage["percentUsed"]) else {
            throw ProviderError.idle("Grok Bot reported no usage yet")
        }
        let reset = Fmt.date(usage["nextResetMs"])
        if let reset, reset < now {
            // The reading belongs to the previous period; the app refreshes it next time it runs.
            return ([UsageWindow(label: "7D", usedPercent: 0, resetsAt: nil, windowSeconds: 604800)], plan)
        }
        var windows = [UsageWindow(label: "7D", usedPercent: min(100, max(0, used)), resetsAt: reset,
                                   windowSeconds: 604800)]
        if let od = usage["onDemand"] as? [String: Any],
           let limit = num(od["limitCents"]), limit > 0 {
            let spent = num(od["usedCents"]) ?? 0
            windows.append(.balance("EXTRA", left: max(0, limit - spent) / 100, total: limit / 100,
                                    unit: "USD", resetsAt: reset))
        }
        return (windows, plan)
    }

    /// "Grok Bot Plan" → nil (the row already says Grok Bot), "Grok Bot Pro Plan" → "Pro".
    static func planLabel(_ usage: [String: Any]) -> String? {
        var parts: [String] = []
        if var label = usage["grokPlanLabel"] as? String {
            for cut in ["Grok Bot", "Plan"] { label = label.replacingOccurrences(of: cut, with: "") }
            label = label.trimmingCharacters(in: .whitespaces)
            if !label.isEmpty { parts.append(label) }
        }
        if (usage["isSandTrial"] as? Bool) == true { parts.append("Trial") }
        if (usage["isTeamSeat"] as? Bool) == true { parts.append("Team") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// RFC 4648 base32 (case-insensitive, padding optional) → UTF-8 string.
enum Base32 {
    static func decode(_ s: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var map: [Character: UInt32] = [:]
        for (i, c) in alphabet.enumerated() { map[c] = UInt32(i) }
        var buffer: UInt32 = 0, bits = 0
        var out: [UInt8] = []
        for ch in s.uppercased() where ch != "=" {
            guard let v = map[ch] else { return nil }
            buffer = (buffer << 5) | v
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return String(bytes: out, encoding: .utf8)
    }
}
