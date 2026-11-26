import SwiftUI
import AppKit
import PhosphorCore

/// HUD rows as drawn: single providers, or one family (Google AI) as a group.
enum HUDSegment: Identifiable {
    case single(ProviderSnapshot)
    case group(ProviderFamily, [ProviderSnapshot])

    var id: String {
        switch self {
        case .single(let s): return s.id
        case .group(let f, _): return f.key
        }
    }

    /// Items arrive already sorted (family members adjacent), so consecutive members form a group.
    static func build(_ items: [ProviderSnapshot]) -> [HUDSegment] {
        var out: [HUDSegment] = []
        for s in items {
            if let f = ProviderFamilies.family(of: s.id) {
                if case .group(let g, let members)? = out.last, g == f { out[out.count - 1] = .group(f, members + [s]) }
                else { out.append(.group(f, [s])) }
            } else {
                out.append(.single(s))
            }
        }
        return out
    }
}

// MARK: - Drag to reorder

/// Where rows and grips are on screen, and what is being dragged. Frames are in window coordinates
/// (SwiftUI's global space, top-left origin), which the panel uses to tell a grip drag from a window drag.
@MainActor
final class ReorderModel: ObservableObject {
    static let shared = ReorderModel()
    var frames: [String: CGRect] = [:]
    var grips: [String: CGRect] = [:]
    @Published var dragging: String?
    @Published var offset: CGFloat = 0

    func isGrip(_ p: CGPoint) -> Bool { grips.values.contains { $0.insetBy(dx: -3, dy: -3).contains(p) } }

    func finish(_ key: String, scope: [String], store: UsageStore) {
        defer { dragging = nil; offset = 0 }
        guard let f = frames[key], scope.count > 1 else { return }
        let others = scope.filter { $0 != key }
        let mids = others.compactMap { frames[$0]?.midY }.map(Double.init)
        guard mids.count == others.count else { return }
        let index = RowOrdering.dropIndex(draggedMid: Double(f.midY + offset), otherMids: mids)
        let order = RowOrdering.moved(scope, key: key, to: index)
        if order != scope { store.saveOrder(scope: order) }
    }
}

/// Makes a row (or group) draggable by a small grip in the left margin.
struct Reorderable: ViewModifier {
    let key: String
    let scope: [String]
    let store: UsageStore
    let theme: Theme
    @ObservedObject var model = ReorderModel.shared
    @StateObject private var hover = HoverFlag()

    func body(content: Content) -> some View {
        let active = model.dragging == key
        // The grip stays clickable everywhere but only shows on hover, so the HUD reads clean.
        let gripOpacity = active ? 0.9 : (hover.on && model.dragging == nil ? 0.45 : 0)
        content
            .onHover { hover.on = $0 }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.frames[key] = $0 }
            .overlay(alignment: .topLeading) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(theme.dim.opacity(gripOpacity))
                    .animation(.easeOut(duration: 0.15), value: gripOpacity)
                    .frame(width: 10, height: 16)
                    .contentShape(Rectangle())
                    // Sit in the left margin. An alignment guide (not .offset) so the reported frame,
                    // which the panel hit-tests, matches where the grip is drawn.
                    .alignmentGuide(.leading) { _ in 12 }
                    .alignmentGuide(.top) { _ in -1 }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.grips[key] = $0 }
                    .onDisappear { model.grips[key] = nil }
                    .gesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .global)
                            .onChanged { v in model.dragging = key; model.offset = v.translation.height }
                            .onEnded { _ in model.finish(key, scope: scope, store: store) }
                    )
                    .help("Drag to reorder")
            }
            .offset(y: active ? model.offset : 0)
            .zIndex(active ? 1 : 0)
            .shadow(color: .black.opacity(active ? 0.5 : 0), radius: 6)
    }
}

final class HoverFlag: ObservableObject { @Published var on = false }

extension View {
    func reorderable(_ key: String, scope: [String], store: UsageStore, theme: Theme) -> some View {
        modifier(Reorderable(key: key, scope: scope, store: store, theme: theme))
    }
}

// MARK: - Google AI group

struct FamilyGroupView: View {
    let family: ProviderFamily
    let members: [ProviderSnapshot]
    let theme: Theme
    let compact: Bool
    let now: Date
    let labelWidth: CGFloat
    @ObservedObject var store: UsageStore
    @ObservedObject var prefs = Prefs.shared

    private var collapsed: Bool { prefs.collapsedGroups.contains(family.id) }
    private var account: AccountInfo? { store.accounts[family.billingProvider] }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            header
            if collapsed {
                Text(theme.name(members.map(summary).joined(separator: " · ")))
                    .font(theme.font(9)).foregroundStyle(theme.dim).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let scope = members.map(\.id)
                ForEach(members) { s in
                    ProviderRow(snap: s, theme: theme, compact: compact, now: now, labelWidth: labelWidth,
                                connect: Connect.supported.contains(s.id) ? { store.connect(s.id) } : nil,
                                note: store.connectNotes[s.id], account: store.accounts[s.id],
                                health: store.status.health[s.id], logged: nil)
                        .reorderable(s.id, scope: scope, store: store, theme: theme)
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(theme.dim.opacity(0.25)).frame(width: 1)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                if collapsed { prefs.collapsedGroups.remove(family.id) } else { prefs.collapsedGroups.insert(family.id) }
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(theme.dim)
                    .frame(width: 12, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expand Google AI" : "Collapse Google AI")
            Text(theme.name(family.name)).font(theme.font(compact ? 11 : 13, .bold)).foregroundStyle(theme.fg)
            if let plan = account?.plan {
                Text(theme.name(plan)).font(theme.font(10)).foregroundStyle(theme.dim).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let a = account, let p = a.monthlyPrice {
                Text(Fmt.money(p, a.currency) + theme.name("/mo")).font(theme.font(10, .semibold)).monospacedDigit()
                    .foregroundStyle(theme.fg)
                    .help("One Google AI subscription for every surface below; counted once in the monthly total. "
                          + "Each surface still has its own separate meter at Google.")
            }
        }
    }

    private func summary(_ s: ProviderSnapshot) -> String {
        let short = s.info.name.replacingOccurrences(of: " (gcloud)", with: "")
        if let w = s.gauges.max(by: { $0.usedPercent < $1.usedPercent }) { return "\(short) \(Int(w.usedPercent.rounded()))%" }
        if let w = s.windows.first, let t = w.amountText { return "\(short) \(t)" }
        return "\(short) –"
    }
}
