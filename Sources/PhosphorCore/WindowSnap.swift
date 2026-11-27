import Foundation

/// Axis-aligned rectangle in AppKit coordinates (origin at the bottom-left, y up).
public struct SnapRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func offset(dx: Double, dy: Double) -> SnapRect {
        SnapRect(x: x + dx, y: y + dy, width: width, height: height)
    }
}

public struct SnapConfig: Equatable, Sendable {
    public var threshold: Double
    public var gap: Double
    public init(threshold: Double = 14, gap: Double = 4) {
        self.threshold = threshold
        self.gap = gap
    }
}

/// Magnetic snapping of a floating HUD to the screen's visible frame and companion windows.
public enum WindowSnap {
    /// If `bypass` is true (Option held), `frame` is returned unchanged.
    public static func snap(_ frame: SnapRect,
                            visibleScreen: SnapRect,
                            companions: [SnapRect],
                            config: SnapConfig = SnapConfig(),
                            bypass: Bool = false) -> SnapRect {
        if bypass { return frame }
        var dx: Double?
        var dy: Double?
        func consider(_ delta: Double, into axis: inout Double?) {
            guard abs(delta) <= config.threshold else { return }
            if axis == nil || abs(delta) < abs(axis!) { axis = delta }
        }

        let g = config.gap
        consider(visibleScreen.minX + g - frame.minX, into: &dx)
        consider(visibleScreen.maxX - g - frame.maxX, into: &dx)
        consider(visibleScreen.minY + g - frame.minY, into: &dy)
        consider(visibleScreen.maxY - g - frame.maxY, into: &dy)

        for c in companions {
            // Adjacent edges: left-to-right, right-to-left, bottom-to-top, top-to-bottom.
            consider(c.maxX + g - frame.minX, into: &dx)
            consider(c.minX - g - frame.maxX, into: &dx)
            consider(c.maxY + g - frame.minY, into: &dy)
            consider(c.minY - g - frame.maxY, into: &dy)
            // Alignment: left-to-left, right-to-right, bottom-to-bottom, top-to-top.
            consider(c.minX - frame.minX, into: &dx)
            consider(c.maxX - frame.maxX, into: &dx)
            consider(c.minY - frame.minY, into: &dy)
            consider(c.maxY - frame.maxY, into: &dy)
        }

        return frame.offset(dx: dx ?? 0, dy: dy ?? 0)
    }
}
