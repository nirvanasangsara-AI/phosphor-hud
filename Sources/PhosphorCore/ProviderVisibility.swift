import Foundation

/// Which provider (or Google-AI family member) rows should appear in the HUD,
/// menu-bar summary, and cost totals. Hidden ids stay persisted until shown again.
public enum ProviderVisibility {
    public static func visible<T>(ids: [T], hidden: Set<T>) -> [T] where T: Hashable {
        ids.filter { !hidden.contains($0) }
    }

    public static func hiding<T>(_ id: T, in hidden: Set<T>) -> Set<T> where T: Hashable {
        hidden.union([id])
    }

    public static func showing<T>(_ id: T, in hidden: Set<T>) -> Set<T> where T: Hashable {
        var next = hidden
        next.remove(id)
        return next
    }

    /// Family members can be hidden one-by-one; a group with no remaining members disappears.
    public static func visibleMembers(of members: [String], hidden: Set<String>) -> [String] {
        visible(ids: members, hidden: hidden)
    }
}
