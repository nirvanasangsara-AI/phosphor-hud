import Foundation

/// How the menu-bar monitor and the main gauges are coloured.
///
/// Pace is the default. Filling the quota just before the window resets is the goal, so a high
/// percent is not treated as bad by itself. The colour is the projection of where usage will be
/// when the window resets:
/// - green when that projection is about 85–110% (on track to use the limit, not waste it)
/// - yellow when it is under 85% (quota likely left unused)
/// - red when it is over 110%, or the fitted burn rate hits the cap before reset
///
/// While a slope is still measuring, the projection is current usage divided by the fraction of
/// the window that has elapsed (a straight line to the reset). The first 5% of a window stays
/// neutral so one early reading does not paint the icon red.
///
/// Usage mode ignores the clock: green under 50%, yellow from 50% through 80%, red above 80%.
public enum IconColor {
    public enum Mode: String, Sendable, Equatable, CaseIterable {
        case pace
        case usage
    }

    public enum Band: String, Sendable, Equatable {
        case green, yellow, red, neutral
    }

    public static let paceGreenLow = 85.0
    public static let paceGreenHigh = 110.0
    public static let usageYellow = 50.0
    public static let usageRed = 80.0
    /// Skip the elapsed-time estimate until the window is at least this far along.
    public static let minElapsedFraction = 0.05

    public static func band(mode: Mode, usedPercent: Double, elapsedFraction: Double?, forecast: Forecast?) -> Band {
        switch mode {
        case .usage: return usage(usedPercent)
        case .pace: return pace(usedPercent: usedPercent, elapsedFraction: elapsedFraction, forecast: forecast)
        }
    }

    public static func usage(_ usedPercent: Double) -> Band {
        if usedPercent > usageRed { return .red }
        if usedPercent >= usageYellow { return .yellow }
        return .green
    }

    public static func pace(usedPercent: Double, elapsedFraction: Double?, forecast: Forecast?) -> Band {
        if let forecast {
            switch forecast.kind {
            case .limitReached:
                return .red
            case .noSession:
                return .neutral
            case .rate:
                let exhausts = forecast.beforeReset && forecast.hitsLimitAt != nil
                return classifyPace(projectedAtReset: forecast.atReset, exhaustsBeforeReset: exhausts)
            case .steady:
                return classifyPace(projectedAtReset: forecast.atReset ?? usedPercent, exhaustsBeforeReset: false)
            case .measuring:
                break
            }
        }
        guard let elapsed = elapsedFraction, elapsed >= minElapsedFraction else { return .neutral }
        return classifyPace(projectedAtReset: usedPercent / elapsed, exhaustsBeforeReset: false)
    }

    /// `projectedAtReset` is the percent the window is heading for at reset (100 = exactly full).
    public static func classifyPace(projectedAtReset: Double?, exhaustsBeforeReset: Bool) -> Band {
        if exhaustsBeforeReset { return .red }
        guard let projected = projectedAtReset else { return .neutral }
        if projected > paceGreenHigh { return .red }
        if projected >= paceGreenLow { return .green }
        return .yellow
    }
}
