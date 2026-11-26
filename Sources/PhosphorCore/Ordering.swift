import Foundation

/// Providers sold or metered by the same company, drawn as one group in the HUD.
/// The plan and monthly price belong to the group (one subscription), read from `billingProvider`.
public struct ProviderFamily: Sendable, Hashable {
    public let id: String
    public let name: String
    /// The row whose billing-screens.json entry holds the family's subscription (counted once).
    public let billingProvider: String
    /// Members in their default order.
    public let members: [String]
    public var key: String { "group:\(id)" }
}

public enum ProviderFamilies {
    public static let google = ProviderFamily(
        id: "google", name: "Google AI", billingProvider: "antigravity",
        members: ["antigravity", "gemini", "gemini-app", "google-ai-credits", "gemini-api", "vertex"])

    public static let all = [google]

    /// The family of a row id ("gemini", or a profile id like "gemini@work").
    public static func family(of id: String) -> ProviderFamily? {
        let base = String(id.split(separator: "@").first ?? Substring(id))
        return all.first { $0.members.contains(base) }
    }
}

/// Row order in the HUD: top-level units (a single row, or a whole family group) and, inside a group,
/// its members. A custom order (from dragging rows) wins; anything not in it keeps the default order
/// after the ones that are.
public enum RowOrdering {
    public static func unitKey(_ id: String) -> String { ProviderFamilies.family(of: id)?.key ?? id }

    public static func sort(_ ids: [String], defaultOrder: [String], custom: [String],
                            name: (String) -> String = { $0 }) -> [String] {
        func idx(_ list: [String], _ k: String) -> Int { list.firstIndex(of: k) ?? Int.max }
        func base(_ id: String) -> String { String(id.split(separator: "@").first ?? Substring(id)) }
        func unitDefault(_ unit: String) -> Int {
            if let f = ProviderFamilies.all.first(where: { $0.key == unit }) {
                return f.members.map { idx(defaultOrder, $0) }.min() ?? Int.max
            }
            return idx(defaultOrder, base(unit))
        }
        func memberDefault(_ id: String) -> Int { ProviderFamilies.family(of: id).map { idx($0.members, base(id)) } ?? 0 }
        return ids.sorted { a, b in
            let ua = unitKey(a), ub = unitKey(b)
            if ua != ub {
                let ka = (idx(custom, ua), unitDefault(ua), name(a)), kb = (idx(custom, ub), unitDefault(ub), name(b))
                if ka.0 != kb.0 { return ka.0 < kb.0 }
                if ka.1 != kb.1 { return ka.1 < kb.1 }
                return ka.2 != kb.2 ? ka.2 < kb.2 : ua < ub
            }
            let ma = (idx(custom, a), memberDefault(a)), mb = (idx(custom, b), memberDefault(b))
            if ma.0 != mb.0 { return ma.0 < mb.0 }
            if ma.1 != mb.1 { return ma.1 < mb.1 }
            return name(a) < name(b)
        }
    }

    /// Moves `key` within `keys` to `index` (clamped).
    public static func moved(_ keys: [String], key: String, to index: Int) -> [String] {
        var out = keys.filter { $0 != key }
        guard keys.contains(key) else { return keys }
        out.insert(key, at: max(0, min(index, out.count)))
        return out
    }

    /// Where a dragged item lands: the number of other items whose middle is above its new middle.
    public static func dropIndex(draggedMid: Double, otherMids: [Double]) -> Int {
        otherMids.filter { $0 < draggedMid }.count
    }

    /// Saves a scope's new order into the custom list, keeping other scopes' entries.
    public static func merge(custom: [String], scope newOrder: [String]) -> [String] {
        let s = Set(newOrder)
        return newOrder + custom.filter { !s.contains($0) }
    }
}
