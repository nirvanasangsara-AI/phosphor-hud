import AppKit
import CoreImage

/// Phosphor ships no third-party logos. With the user's OK (asked once on first launch, or via the
/// menu), it downloads each service's own icon from that service's website into
/// ~/.config/phosphor/icons. Files the user put there themselves are never overwritten, and only
/// files Phosphor downloaded are removed by "Remove Downloaded Logos".
enum Logos {
    struct Source {
        let page: String?          // read <link rel="apple-touch-icon|icon"> from this page…
        let direct: String?        // …or fetch this URL as is
        var knockout = false       // dark ink on a light disc → white ink on transparent
        var version = 1            // bump when the source changes so an old download is replaced
    }

    /// Apps whose own icon (read at runtime from the installed app, never bundled) is the
    /// provider's logo. Used before any downloaded file, so nothing needs fetching.
    static let localApps: [String: [String]] = [
        "grokbot": ["Grok Bot.app"],
        "antigravity": ["Antigravity.app"],
        "copilot": ["GitHub Copilot.app"],
        "muse": ["Muse Code.app", "Muse.app"],
    ]

    /// The installed app's icon for `id`, from /Applications or ~/Applications.
    static func localAppIcon(_ id: String) -> NSImage? {
        guard let names = localApps[id] else { return nil }
        let roots = ["/Applications", Paths.home.appendingPathComponent("Applications").path]
        for root in roots {
            for name in names {
                let path = (root as NSString).appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let icon = NSWorkspace.shared.icon(forFile: path)
                icon.size = NSSize(width: 256, height: 256)   // pick the large representation
                return icon
            }
        }
        return nil
    }

    static let sources: [String: Source] = [
        "claude": Source(page: nil, direct: "https://claude.com/icon.png"),
        "codex": Source(page: "https://chatgpt.com", direct: nil, knockout: true),
        "gemini": Source(page: "https://gemini.google.com", direct: nil),
        "antigravity": Source(page: "https://antigravity.google",
                              direct: "https://antigravity.google/assets/image/antigravity-logo.png", version: 2),
        "cursor": Source(page: "https://cursor.com", direct: nil),
        "perplexity": Source(page: "https://www.perplexity.ai", direct: nil),
        "grok": Source(page: "https://grok.com", direct: nil),
        // GitHub's own Copilot mark from its Primer Octicons set (the page icon is the plain Octocat).
        "copilot": Source(page: nil, direct: "https://raw.githubusercontent.com/primer/octicons/main/icons/copilot-48.svg",
                          knockout: true, version: 2),
        "muse": Source(page: "https://dev.meta.ai/products/muse-code", direct: nil, version: 2),
        "openrouter": Source(page: "https://openrouter.ai", direct: nil),
        "mistral": Source(page: "https://mistral.ai", direct: nil),
        "deepseek": Source(page: "https://www.deepseek.com", direct: nil),
    ]

    private static let manifest = Paths.config.appendingPathComponent("icons/.downloaded")
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Downloads what's missing. Returns the ids that now have a logo from this run.
    @discardableResult
    static func download(only ids: [String]? = nil) async -> [String] {
        let dir = Paths.config.appendingPathComponent("icons")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var got: [String] = []
        let done = downloadedVersions()
        await withTaskGroup(of: String?.self) { group in
            for (id, src) in sources where ids?.contains(id) ?? true {
                let dest = Paths.icon(for: id)
                // Never overwrite a file the user put there; replace our own download only when its
                // source has changed since (manifest line "id" = version 1, "id@2" = version 2…).
                if FileManager.default.fileExists(atPath: dest.path) {
                    guard let v = done[id], v < src.version else { continue }
                }
                group.addTask {
                    guard let png = try? await fetch(src) else { return nil }
                    return (try? png.write(to: dest, options: .atomic)) != nil ? id : nil
                }
            }
            for await id in group { if let id { got.append(id) } }
        }
        if !got.isEmpty {
            var all = done
            for id in got { all[id] = sources[id]?.version ?? 1 }
            let lines = all.keys.sorted().map { id in all[id]! > 1 ? "\(id)@\(all[id]!)" : id }
            try? lines.joined(separator: "\n").write(to: manifest, atomically: true, encoding: .utf8)
        }
        return got.sorted()
    }

    /// Ids Phosphor downloaded, with the source version each came from.
    static func downloadedVersions() -> [String: Int] {
        let lines = (try? String(contentsOf: manifest, encoding: .utf8))?.split(separator: "\n") ?? []
        var out: [String: Int] = [:]
        for line in lines {
            let parts = line.split(separator: "@", maxSplits: 1)
            guard let id = parts.first, !id.isEmpty else { continue }
            out[String(id)] = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        }
        return out
    }

    /// Removes only the files Phosphor downloaded.
    static func removeDownloaded() {
        for id in downloadedVersions().keys { try? FileManager.default.removeItem(at: Paths.icon(for: id)) }
        try? FileManager.default.removeItem(at: manifest)
    }

    static var hasDownloaded: Bool { FileManager.default.fileExists(atPath: manifest.path) }

    // MARK: Fetching

    private static func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private static func fetch(_ src: Source) async throws -> Data {
        var candidates: [URL] = []
        if let d = src.direct, let u = URL(string: d) { candidates.append(u) }
        if let p = src.page, let page = URL(string: p) {
            if let html = String(data: try await get(page), encoding: .utf8) { candidates += iconLinks(html, base: page) }
            candidates.append(page.appending(path: "apple-touch-icon.png"))
        }
        for url in candidates {
            guard let data = try? await get(url), let img = NSImage(data: data),
                  let cg = raster(img),
                  cg.width >= 64 else { continue }   // favicon.ico-sized marks look mushy in the HUD
            return try png(CIImage(cgImage: cg), knockout: src.knockout)
        }
        throw URLError(.cannotDecodeContentData)
    }

    /// Bitmap of the image; vector images (SVG) are drawn at 256 px so they stay crisp.
    private static func raster(_ img: NSImage) -> CGImage? {
        let isVector = img.representations.contains { $0.pixelsWide == 0 || !($0 is NSBitmapImageRep) }
        if isVector {
            var rect = NSRect(x: 0, y: 0, width: 256, height: 256 * img.size.height / max(img.size.width, 1))
            return img.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform.identity])
                .flatMap { $0.width >= 64 ? $0 : nil } ?? drawn(img, rect.size)
        }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func drawn(_ img: NSImage, _ size: NSSize) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Icon <link>s in the page, largest PNG first (SVG/ICO last: NSImage handles PNG best).
    static func iconLinks(_ html: String, base: URL) -> [URL] {
        let tag = try! NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive])
        func attr(_ name: String, _ s: String) -> String? {
            let re = try! NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive])
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range(at: 1), in: s) else { return nil }
            return String(s[r])
        }
        var found: [(URL, Int)] = []
        for m in tag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range, in: html) else { continue }
            let t = String(html[r])
            guard let rel = attr("rel", t)?.lowercased(), rel.contains("icon"),
                  let href = attr("href", t), let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            let size = attr("sizes", t).flatMap { Int($0.lowercased().split(separator: "x").first ?? "") } ?? 0
            let ext = url.pathExtension.lowercased()
            let score = (ext == "png" ? 10_000 : 0) + (rel.contains("apple-touch") ? 1_000 : 0) + size
            found.append((url, score))
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private static func png(_ image: CIImage, knockout: Bool) throws -> Data {
        var img = image
        if knockout {
            let white = CIImage(color: .white).cropped(to: img.extent)
            img = img.composited(over: white)                 // transparent corners → white
                .applyingFilter("CIColorInvert")              // ink → white, disc → black
                .applyingFilter("CIMaskToAlpha")              // luminance → alpha
        }
        let ctx = CIContext()
        guard let data = ctx.pngRepresentation(of: img, format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw URLError(.cannotDecodeContentData)
        }
        return data
    }
}
