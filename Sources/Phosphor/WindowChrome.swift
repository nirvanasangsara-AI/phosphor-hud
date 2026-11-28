import AppKit
import CoreGraphics
import PhosphorCore

/// Edges and corners of the borderless HUD that start a resize drag.
enum ResizeEdge: CaseIterable {
    case n, s, e, w, ne, nw, se, sw

    var isNorth: Bool { self == .n || self == .ne || self == .nw }
    var isSouth: Bool { self == .s || self == .se || self == .sw }
    var isEast: Bool { self == .e || self == .ne || self == .se }
    var isWest: Bool { self == .w || self == .nw || self == .sw }

    var cursor: NSCursor {
        switch self {
        case .n, .s: return .resizeUpDown
        case .e, .w: return .resizeLeftRight
        case .ne, .sw, .nw, .se:
            if #available(macOS 15.0, *) {
                let pos: NSCursor.FrameResizePosition = (self == .ne || self == .sw) ? .topRight : .topLeft
                return NSCursor.frameResize(position: pos, directions: .all)
            }
            return .crosshair
        }
    }

    /// Window-local point, origin at the bottom-left of the window (AppKit).
    static func at(_ p: NSPoint, size: NSSize, grip: CGFloat = 9) -> ResizeEdge? {
        let x = p.x, y = p.y
        guard x >= -2, y >= -2, x <= size.width + 2, y <= size.height + 2 else { return nil }
        let left = x <= grip, right = x >= size.width - grip
        let bottom = y <= grip, top = y >= size.height - grip
        switch (top, bottom, left, right) {
        case (true, _, true, _): return .nw
        case (true, _, _, true): return .ne
        case (_, true, true, _): return .sw
        case (_, true, _, true): return .se
        case (true, _, _, _): return .n
        case (_, true, _, _): return .s
        case (_, _, true, _): return .w
        case (_, _, _, true): return .e
        default: return nil
        }
    }
}

final class HUDPanel: NSPanel {
    static let minWidth: CGFloat = 240
    static let minHeight: CGFloat = 140
    var onUserResize: ((CGSize) -> Void)?
    var lastRightClick: NSPoint?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        minSize = NSSize(width: Self.minWidth, height: Self.minHeight)
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown {
            lastRightClick = event.locationInWindow
        }
        if event.type == .mouseMoved || event.type == .leftMouseDragged {
            updateResizeCursor(at: event.locationInWindow)
        }
        if event.type == .leftMouseDown {
            let p = event.locationInWindow
            if MainActor.assumeIsolated({ ReorderModel.shared.isGrip(CGPoint(x: p.x, y: frame.height - p.y)) }) {
                super.sendEvent(event)
                return
            }
            if let edge = ResizeEdge.at(p, size: frame.size) {
                resize(from: event, edge: edge)
                return
            }
            let before = frame.origin
            dragWithSnap(from: event)
            if frame.origin == before,
               let up = NSEvent.mouseEvent(with: .leftMouseUp, location: event.locationInWindow,
                                           modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                           windowNumber: event.windowNumber, context: nil,
                                           eventNumber: event.eventNumber, clickCount: event.clickCount,
                                           pressure: 0) {
                super.sendEvent(event)
                super.sendEvent(up)
            }
            return
        }
        super.sendEvent(event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateResizeCursor(at: event.locationInWindow)
        super.mouseMoved(with: event)
    }

    private func updateResizeCursor(at p: NSPoint) {
        if let edge = ResizeEdge.at(p, size: frame.size) {
            edge.cursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: Magnetic drag

    private func dragWithSnap(from start: NSEvent) {
        let grab = NSEvent.mouseLocation
        let origin0 = frame.origin
        let offset = NSPoint(x: grab.x - origin0.x, y: grab.y - origin0.y)
        while true {
            guard let ev = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                           until: .distantFuture, inMode: .eventTracking, dequeue: true)
            else { break }
            if ev.type == .leftMouseUp { break }
            let loc = NSEvent.mouseLocation
            var next = SnapRect(x: loc.x - offset.x, y: loc.y - offset.y,
                                width: frame.width, height: frame.height)
            let bypass = ev.modifierFlags.contains(.option)
            if !bypass, let vis = screenFor(frame: frame)?.visibleFrame {
                next = WindowSnap.snap(next,
                                       visibleScreen: SnapRect(x: vis.minX, y: vis.minY,
                                                               width: vis.width, height: vis.height),
                                       companions: CompanionWindows.frames(excluding: self),
                                       bypass: false)
            }
            setFrameOrigin(NSPoint(x: next.x, y: next.y))
            invalidateShadow()
        }
    }

    // MARK: Edge / corner resize

    private func resize(from start: NSEvent, edge: ResizeEdge) {
        let startFrame = frame
        let startMouse = NSEvent.mouseLocation
        let limits = screenFor(frame: startFrame)?.visibleFrame
        edge.cursor.push()
        defer { NSCursor.pop() }
        while true {
            guard let ev = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                           until: .distantFuture, inMode: .eventTracking, dequeue: true)
            else { break }
            if ev.type == .leftMouseUp { break }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - startMouse.x
            let dy = mouse.y - startMouse.y
            var f = startFrame
            if edge.isEast { f.size.width = startFrame.width + dx }
            if edge.isWest {
                f.size.width = startFrame.width - dx
                f.origin.x = startFrame.maxX - f.size.width
            }
            if edge.isNorth { f.size.height = startFrame.height + dy }
            if edge.isSouth {
                f.size.height = startFrame.height - dy
                f.origin.y = startFrame.maxY - f.size.height
            }
            f.size.width = max(minSize.width, f.size.width)
            f.size.height = max(minSize.height, f.size.height)
            if edge.isWest { f.origin.x = startFrame.maxX - f.size.width }
            if edge.isSouth { f.origin.y = startFrame.maxY - f.size.height }
            if let vis = limits {
                // Don't let the window be dragged larger than the visible screen.
                f.size.width = min(f.size.width, vis.width)
                f.size.height = min(f.size.height, vis.height)
                if edge.isWest { f.origin.x = startFrame.maxX - f.size.width }
                if edge.isSouth { f.origin.y = startFrame.maxY - f.size.height }
            }
            setFrame(f, display: true, animate: false)
            invalidateShadow()
        }
        onUserResize?(frame.size)
    }

    private func screenFor(frame: NSRect) -> NSScreen? {
        NSScreen.screens.max(by: { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area })
            ?? NSScreen.main
    }
}

private extension NSRect {
    var area: CGFloat { width * height }
}

/// Other on-screen floating HUD panels (일정, other Phosphor windows, similar floaters)
/// discovered via the window list. Images and window contents are never captured.
enum CompanionWindows {
    static func frames(excluding panel: NSWindow) -> [SnapRect] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let mine = CGWindowID(panel.windowNumber)
        let myPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let primaryH = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        let skipOwners: Set<String> = [
            "Window Server", "Dock", "Control Center", "Control Centre",
            "Notification Center", "Notification Centre", "System Settings",
            "Spotlight", "Item-0", "Wi-Fi", "Wallpaper", "WindowManager"
        ]
        var out: [SnapRect] = []
        for w in list {
            let number = w[kCGWindowNumber as String] as? CGWindowID ?? 0
            if number == mine { continue }
            if (w[kCGWindowOwnerPID as String] as? pid_t) == myPID { continue }
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            if alpha < 0.15 { continue }
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            if skipOwners.contains(owner) { continue }
            let name = (w[kCGWindowName as String] as? String) ?? ""
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard let b = w[kCGWindowBounds as String] as? [String: Double],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"]
            else { continue }
            if width < 80 || height < 60 { continue }
            if width > 1600 && height > 900 { continue }

            let named = owner.contains("일정") || name.contains("일정")
                || owner.localizedCaseInsensitiveContains("Iljeong")
                || owner.localizedCaseInsensitiveContains("Schedule")
                || owner.localizedCaseInsensitiveContains("Phosphor")
            let floatingHUD = (3...8).contains(layer) && width <= 720 && height <= 1100
            guard named || floatingHUD else { continue }

            // Quartz bounds are top-left origin; AppKit frames are bottom-left origin.
            let cocoaY = primaryH - y - height
            out.append(SnapRect(x: x, y: cocoaY, width: width, height: height))
        }
        return out
    }
}

extension HUDPanel {
    /// Provider row under a right-click, if any (window coords, top-left origin like SwiftUI global).
    func providerKey(at windowPoint: NSPoint) -> String? {
        let p = CGPoint(x: windowPoint.x, y: frame.height - windowPoint.y)
        return MainActor.assumeIsolated {
            ReorderModel.shared.frames.first { $0.value.insetBy(dx: -4, dy: -2).contains(p) }?.key
        }
    }
}
