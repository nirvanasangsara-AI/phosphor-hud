import Foundation

/// Usage-limit reset news: a worker feed, or the public status RSS feeds when that URL is unset.
public enum ResetFeed {
    public static let feedURLPlaceholder = "https://phosphor-reset-feed.<account>.workers.dev/feed.json"
    public static let refreshInterval: TimeInterval = 600
    public static let rotateInterval: TimeInterval = 6

    public static let statusFeedURLs: [URL] = [
        URL(string: "https://status.openai.com/history.rss")!,
        URL(string: "https://status.claude.com/history.rss")!,
        URL(string: "https://status.x.ai/feed.xml")!,
    ]

    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var source: String
        public var handle: String
        public var text: String
        public var url: String
        public var postedAt: Date
        public var kind: Kind
        public var expectedResetAt: Date?
        public var expiresAt: Date?
        public var confidence: Double?
        public var official: Bool
        public var product: String?

        public enum Kind: String, Codable, Sendable {
            case official, rumor, status
        }

        public var isRumor: Bool { kind == .rumor && !official }

        public init(id: String, source: String, handle: String, text: String, url: String, postedAt: Date,
                    kind: Kind, expectedResetAt: Date? = nil, expiresAt: Date? = nil, confidence: Double? = nil,
                    official: Bool, product: String? = nil) {
            self.id = id
            self.source = source
            self.handle = handle
            self.text = text
            self.url = url
            self.postedAt = postedAt
            self.kind = kind
            self.expectedResetAt = expectedResetAt
            self.expiresAt = expiresAt
            self.confidence = confidence
            self.official = official
            self.product = product
        }

        enum CodingKeys: String, CodingKey {
            case id, source, handle, text, url, kind, confidence, official, product
            case postedAt = "posted_at"
            case expectedResetAt = "expected_reset_at"
            case expiresAt = "expires_at"
        }
    }

    public static func parse(json data: Data, now: Date = Date()) throws -> [Item] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(raw) else {
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: raw)
            }
            return date
        }
        let items: [Item]
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            items = envelope.items
        } else {
            items = try decoder.decode([Item].self, from: data)
        }
        return filtered(droppingExpired(items, now: now), includeRumors: true)
    }

    public static func droppingExpired(_ items: [Item], now: Date = Date()) -> [Item] {
        items.filter { item in
            guard let expires = item.expiresAt else { return true }
            return expires > now
        }
    }

    /// What the ticker shows right now: expired lines are gone even if the last fetch is still cached.
    public static func display(_ items: [Item], includeRumors: Bool, now: Date = Date()) -> [Item] {
        filtered(droppingExpired(items, now: now), includeRumors: includeRumors)
    }

    /// Official and status items come first. Rumors are omitted when `includeRumors` is false.
    public static func filtered(_ items: [Item], includeRumors: Bool) -> [Item] {
        items.filter { includeRumors || !$0.isRumor }
            .sorted { a, b in
                if a.isRumor != b.isRumor { return !a.isRumor && b.isRumor }
                return a.postedAt > b.postedAt
            }
    }

    public static func parseRSS(_ data: Data, source: URL, now: Date = Date()) -> [Item] {
        let parser = RSSParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        let product = productName(for: source)
        let handle = statusHandle(for: source)
        return parser.items.compactMap { raw in
            let title = plain(raw.title)
            guard !title.isEmpty else { return nil }
            let posted = parseDate(raw.pubDate) ?? now
            let link = raw.link.isEmpty ? source.absoluteString : raw.link
            let id = "status:" + (raw.guid.isEmpty ? link : raw.guid)
            return Item(id: id, source: "status", handle: handle, text: title, url: link,
                        postedAt: posted, kind: .status, expiresAt: posted.addingTimeInterval(48 * 3600),
                        confidence: 1, official: true, product: product)
        }
    }

    public static func mergeStatus(_ batches: [[Item]], now: Date = Date()) -> [Item] {
        var byID: [String: Item] = [:]
        for item in batches.flatMap({ $0 }) {
            if let existing = byID[item.id], existing.official && !item.official { continue }
            byID[item.id] = item
        }
        return filtered(droppingExpired(Array(byID.values), now: now), includeRumors: true)
    }

    static func parseDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return rfc.date(from: text)
    }

    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func productName(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("openai") { return "codex" }
        if host.contains("claude") { return "claude" }
        if host.contains("x.ai") { return "grok" }
        return "status"
    }

    private static func statusHandle(for url: URL) -> String {
        switch productName(for: url) {
        case "codex": return "OpenAI"
        case "claude": return "Claude"
        case "grok": return "xAI"
        default: return "status"
        }
    }

    private struct Envelope: Decodable {
        var items: [Item]
    }
}

private final class RSSParser: NSObject, XMLParserDelegate {
    struct Raw {
        var title = ""
        var link = ""
        var guid = ""
        var pubDate = ""
    }

    var items: [Raw] = []
    private var current: Raw?
    private var capture: String?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let element = elementName.lowercased()
        if element == "item" || element == "entry" { current = Raw() }
        guard current != nil else { return }
        if element == "link", let href = attributeDict["href"], !href.isEmpty, current?.link.isEmpty == true {
            current?.link = href
        }
        if ["title", "link", "guid", "id", "pubdate", "published", "updated"].contains(element) {
            capture = element
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = elementName.lowercased()
        if let capture, capture == element {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch capture {
            case "title": current?.title = value
            case "link": if current?.link.isEmpty == true { current?.link = value }
            case "guid", "id": current?.guid = value
            case "pubdate", "published", "updated": if current?.pubDate.isEmpty == true { current?.pubDate = value }
            default: break
            }
            self.capture = nil
        }
        if element == "item" || element == "entry", let current {
            items.append(current)
            self.current = nil
        }
    }
}
