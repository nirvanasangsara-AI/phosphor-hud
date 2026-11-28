import Foundation

/// How the HUD folds. New installs use double-click. The header pin selects `.pin`
/// and restores `remembered` (never `.pin`) when it is clicked again.
public enum CollapseMode: String, Codable, Sendable, CaseIterable, Equatable {
    case pin
    case doubleClick
    case auto

    public static let newInstall = CollapseMode.doubleClick
}

/// Pure fold state. The app waits `Collapse.hoverLeaveDelay` after `armed` becomes true,
/// then sends `.delayElapsed`. A click in auto mode holds the panel open until the pointer leaves.
public struct CollapseState: Equatable, Sendable {
    public var mode: CollapseMode
    /// Mode restored by the header pin. Never `.pin`.
    public var remembered: CollapseMode
    public var expanded: Bool
    /// Auto mode: a click on the strip holds the panel open until the pointer leaves.
    public var held: Bool
    /// Auto mode: the pointer left an unheld panel and the collapse delay is running.
    public var armed: Bool

    public var pinned: Bool { mode == .pin }

    public init(mode: CollapseMode, remembered: CollapseMode, expanded: Bool, held: Bool, armed: Bool) {
        self.mode = mode
        self.remembered = remembered == .pin ? .doubleClick : remembered
        self.expanded = expanded
        self.held = held
        self.armed = armed
    }

    public static let fresh = CollapseState(
        mode: .doubleClick, remembered: .doubleClick, expanded: true, held: false, armed: false)

    /// `expanded` is kept only for double-click. Pin is always open. Auto starts folded.
    public static func restored(mode rawMode: String?, remembered rawRemembered: String?, expanded: Bool?) -> CollapseState {
        let mode = rawMode.flatMap(CollapseMode.init(rawValue:)) ?? .doubleClick
        let remembered = rawRemembered.flatMap(CollapseMode.init(rawValue:)).flatMap { $0 == .pin ? nil : $0 }
            ?? .doubleClick
        switch mode {
        case .pin:
            return CollapseState(mode: .pin, remembered: remembered, expanded: true, held: false, armed: false)
        case .auto:
            return CollapseState(mode: .auto, remembered: .auto, expanded: false, held: false, armed: false)
        case .doubleClick:
            return CollapseState(mode: .doubleClick, remembered: .doubleClick, expanded: expanded ?? true,
                                 held: false, armed: false)
        }
    }
}

public enum CollapseEvent: Equatable, Sendable {
    case choose(CollapseMode)
    case togglePin
    case doubleClick
    case pointerEntered
    case pointerExited
    case delayElapsed
    case clickStrip
}

public enum Collapse {
    /// How long the pointer must stay outside an auto-collapsed HUD before it folds.
    public static let hoverLeaveDelay: TimeInterval = 0.8

    public static func reduce(_ state: CollapseState, _ event: CollapseEvent) -> CollapseState {
        switch event {
        case .choose(let mode):
            return apply(state, mode)
        case .togglePin:
            if state.mode == .pin {
                let back = state.remembered == .pin ? CollapseMode.doubleClick : state.remembered
                return apply(state, back)
            }
            var next = state
            next.remembered = state.mode
            return apply(next, .pin)
        case .doubleClick:
            guard state.mode == .doubleClick else { return state }
            var next = state
            next.expanded.toggle()
            next.held = false
            next.armed = false
            return next
        case .pointerEntered:
            guard state.mode == .auto else { return state }
            var next = state
            next.expanded = true
            next.armed = false
            return next
        case .pointerExited:
            guard state.mode == .auto, state.expanded else { return state }
            var next = state
            if state.held {
                next.expanded = false
                next.held = false
                next.armed = false
            } else {
                next.armed = true
            }
            return next
        case .delayElapsed:
            guard state.mode == .auto, state.armed, !state.held else { return state }
            var next = state
            next.expanded = false
            next.armed = false
            return next
        case .clickStrip:
            guard state.mode == .auto, state.expanded else { return state }
            var next = state
            next.held = true
            next.armed = false
            return next
        }
    }

    /// Enter `mode`. Double-click stays as it is when it is already the mode, and opens when switching in.
    /// Auto always starts folded. Pin always opens and keeps the previous non-pin mode.
    private static func apply(_ state: CollapseState, _ mode: CollapseMode) -> CollapseState {
        var next = state
        switch mode {
        case .pin:
            if next.mode != .pin { next.remembered = next.mode }
            next.mode = .pin
            next.expanded = true
            next.held = false
            next.armed = false
        case .doubleClick:
            let switching = next.mode != .doubleClick
            next.mode = .doubleClick
            next.remembered = .doubleClick
            if switching { next.expanded = true }
            next.held = false
            next.armed = false
        case .auto:
            next.mode = .auto
            next.remembered = .auto
            next.expanded = false
            next.held = false
            next.armed = false
        }
        return next
    }
}
