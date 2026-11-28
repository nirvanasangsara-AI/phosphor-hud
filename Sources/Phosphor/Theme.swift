import SwiftUI

// Themes are plain JSON (schema: docs/THEMES.md). The five built-ins below use the
// same schema as user themes in ~/.config/phosphor/themes/*.json.

enum BarStyle: String, Codable { case capsule, blocks, segments, hairline, health }
enum Layout: String, Codable { case list, raid }
enum Backdrop { case material(Double), solid(Color), clear(Double) }   // material: dark shade on top of the blur

/// Decoded, fully-resolved theme. Every field is filled: missing keys inherit from
/// `extends` (or Clean), so the views never deal with optionals.
struct Theme: Identifiable {
    let id: String
    let name: String
    let layout: Layout
    let design: Font.Design
    let bar: BarStyle
    let fg, dim, track, danger, warn: Color
    let border: Color?
    let hpHigh, hpMid, hpLow, mana: Color
    let backdrop: Backdrop
    let monochrome, uppercase: Bool
    let glow: Bool
    let glowRadius: CGFloat
    let scanlines, vignette, rain, cursor: Bool
    let corner, borderWidth, width, compactWidth: CGFloat
    let header: String
    let prompt: String?   // little geek prefix in front of provider names

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: design)
    }

    func tint(_ info: ProviderInfo) -> Color { monochrome ? fg : info.color }

    func name(_ s: String) -> String { uppercase ? s.uppercased() : s }

    func headerText(online: Int) -> String {
        header.replacingOccurrences(of: "{online}", with: "\(online)")
              .replacingOccurrences(of: "{version}", with: Phosphor.version)
    }
}

enum Phosphor {
    /// Marketing version stamped into the app from the repo VERSION file.
    /// `scripts/build-app.sh` writes it to CFBundleShortVersionString.
    static var version: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "dev" : trimmed
    }
}

// MARK: - JSON schema

private struct Spec: Decodable {
    struct Colors: Decodable {
        let fg, dim, track, danger: String
        let warn, border: String?
        let hpHigh, hpMid, hpLow, mana: String
    }
    struct BackdropSpec: Decodable {
        let type: String             // material | solid | clear
        let color: String?
        let opacity: Double?
    }
    struct Effects: Decodable {
        let glow, scanlines, vignette, rain, cursor: Bool
        let glowRadius: Double
    }
    let id: String
    let name: String
    let layout: Layout
    let font: String
    let bar: BarStyle
    let colors: Colors
    let backdrop: BackdropSpec
    let effects: Effects
    let monochrome, uppercase: Bool
    let corner, borderWidth, width, compactWidth: Double
    let header: String
    let prompt: String?

    var theme: Theme {
        let design: Font.Design = ["rounded": .rounded, "monospaced": .monospaced, "serif": .serif][font] ?? .default
        let bd: Backdrop
        switch backdrop.type {
        case "solid": bd = .solid(Color(hex: backdrop.color ?? "#000000"))
        case "clear": bd = .clear(backdrop.opacity ?? 0.35)
        default: bd = .material(backdrop.opacity ?? 0)
        }
        return Theme(id: id, name: name, layout: layout, design: design, bar: bar,
                     fg: Color(hex: colors.fg), dim: Color(hex: colors.dim), track: Color(hex: colors.track),
                     danger: Color(hex: colors.danger), warn: Color(hex: colors.warn ?? colors.danger),
                     border: colors.border.map { Color(hex: $0) },
                     hpHigh: Color(hex: colors.hpHigh), hpMid: Color(hex: colors.hpMid),
                     hpLow: Color(hex: colors.hpLow), mana: Color(hex: colors.mana),
                     backdrop: bd, monochrome: monochrome, uppercase: uppercase,
                     glow: effects.glow, glowRadius: effects.glowRadius,
                     scanlines: effects.scanlines, vignette: effects.vignette, rain: effects.rain,
                     cursor: effects.cursor, corner: corner, borderWidth: borderWidth,
                     width: width, compactWidth: compactWidth, header: header, prompt: prompt)
    }
}

// MARK: - Registry

@MainActor
final class ThemeRegistry: ObservableObject {
    static let shared = ThemeRegistry()

    @Published private(set) var themes: [Theme] = []
    @Published private(set) var problems: [String] = []   // "file.json: why", shown in the menu

    static var userDir: URL { Paths.config.appendingPathComponent("themes") }

    private init() { reload() }

    func theme(_ id: String) -> Theme {
        themes.first { $0.id == id } ?? themes[0]
    }

    func reload() {
        var raw: [(id: String, dict: [String: Any])] = []
        var problems: [String] = []
        for json in BuiltinThemes.all {
            if let d = Self.object(Data(json.utf8)), let id = d["id"] as? String { raw.append((id, d)) }
        }
        let builtinCount = raw.count
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.userDir, includingPropertiesForKeys: nil)) ?? []
        for f in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: f), var d = Self.object(data) else {
                problems.append("\(f.lastPathComponent): not a JSON object"); continue
            }
            if d["id"] == nil { d["id"] = f.deletingPathExtension().lastPathComponent }
            if d["name"] == nil { d["name"] = d["id"] }
            let id = d["id"] as! String
            if let i = raw.firstIndex(where: { $0.id == id }) { raw[i] = (id, d) } else { raw.append((id, d)) }
        }

        var out: [Theme] = []
        let base = raw[0].dict   // Clean: defaults for anything a theme leaves out
        for (n, entry) in raw.enumerated() {
            var merged = base
            if let parent = entry.dict["extends"] as? String {
                if let p = raw.first(where: { $0.id == parent }), p.id != entry.id {
                    merged = Self.merge(base, p.dict)
                } else {
                    problems.append("\(entry.id): unknown theme in \"extends\": \(parent)")
                }
            }
            merged = Self.merge(merged, entry.dict)
            do {
                let data = try JSONSerialization.data(withJSONObject: merged)
                out.append(try JSONDecoder().decode(Spec.self, from: data).theme)
            } catch {
                problems.append("\(entry.id): \(Self.describe(error))")
                if n < builtinCount { assertionFailure("built-in theme \(entry.id) is invalid") }
            }
        }
        themes = out
        self.problems = problems
        for p in problems { NSLog("Phosphor theme: %@", p) }
    }

    /// Writes the built-ins to a folder, as a starting point for your own themes.
    static func export(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for json in BuiltinThemes.all {
            guard let d = object(Data(json.utf8)), let id = d["id"] as? String else { continue }
            let pretty = try JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys])
            try pretty.write(to: dir.appendingPathComponent("\(id).json"))
        }
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Deep merge: nested objects ("colors", "effects", "backdrop") merge key by key.
    private static func merge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        var out = a
        for (k, v) in b where k != "extends" {
            if let av = a[k] as? [String: Any], let bv = v as? [String: Any] {
                out[k] = merge(av, bv)
            } else {
                out[k] = v
            }
        }
        return out
    }

    private static func describe(_ e: Error) -> String {
        switch e as? DecodingError {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
            return "\(c.codingPath.map(\.stringValue).joined(separator: ".")): \(c.debugDescription)"
        case .keyNotFound(let k, _): return "missing \"\(k.stringValue)\""
        default: return e.localizedDescription
        }
    }
}
