import Foundation

/// Compact trend samples for the HUD sparkline. Pure math so it can be unit-tested.
public enum SparklineSeries {
    /// A weekly (or similarly long) usage row that should show a sparkline.
    public static func isWeekly(label: String, windowSeconds: TimeInterval?) -> Bool {
        let u = label.uppercased()
        if u.contains("7D") || u.contains("WEEK") || u.contains("주간") || u.contains("WEEKLY") { return true }
        if let w = windowSeconds, w >= 6 * 86_400 && w <= 8 * 86_400 { return true }
        return false
    }

    /// Keep at most `cap` points, always preserving the first and last sample.
    public static func downsample(_ values: [Double], cap: Int = 28) -> [Double] {
        guard cap > 2, values.count > cap else { return values }
        var out: [Double] = [values[0]]
        let last = values.count - 1
        for i in 1..<cap - 1 {
            let idx = Int(round(Double(i) * Double(last) / Double(cap - 1)))
            out.append(values[min(last, max(1, idx))])
        }
        out.append(values[last])
        return out
    }

    /// Map values into 0...1 for drawing. A single sample or a constant series becomes a flat
    /// mid-line so the sparkline still reads as "present, no movement yet".
    public static func normalize(_ values: [Double]) -> [Double] {
        let pts = downsample(values)
        guard let lo = pts.min(), let hi = pts.max() else { return [] }
        if pts.count == 1 || hi - lo < 1e-9 {
            return pts.map { _ in 0.5 }
        }
        return pts.map { ($0 - lo) / (hi - lo) }
    }
}
