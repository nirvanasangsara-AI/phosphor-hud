import Foundation

public enum HealthLevel: Int, Sendable, Comparable, Codable {
    case operational = 0, maintenance, degraded, partialOutage, majorOutage
    public static func < (a: HealthLevel, b: HealthLevel) -> Bool { a.rawValue < b.rawValue }

    public init(statuspage s: String) {
        switch s.lowercased() {
        case "degraded_performance", "minor": self = .degraded
        case "partial_outage": self = .partialOutage
        case "major_outage", "major", "critical": self = .majorOutage
        case "under_maintenance", "maintenance": self = .maintenance
        default: self = .operational
        }
    }

    public var label: String {
        switch self {
        case .operational: return "Operational"
        case .maintenance: return "Maintenance"
        case .degraded: return "Degraded"
        case .partialOutage: return "Partial outage"
        case .majorOutage: return "Major outage"
        }
    }
}

/// One public status feed, normalised.
public struct FeedStatus: Sendable {
    public struct Incident: Sendable, Hashable {
        public var name: String
        public var level: HealthLevel
        public var components: [String]
    }
    public var components: [String: HealthLevel]
    public var incidents: [Incident]
}

public struct ProviderHealth: Sendable, Hashable {
    public var level: HealthLevel
    public var summary: String
    public var pageURL: String
}

public enum StatusFeeds {
    public static func url(_ f: StatusRef.Feed) -> URL {
        switch f {
        case .anthropic: return URL(string: "https://status.claude.com/api/v2/summary.json")!
        case .openai: return URL(string: "https://status.openai.com/api/v2/summary.json")!
        case .github: return URL(string: "https://www.githubstatus.com/api/v2/summary.json")!
        case .xai: return URL(string: "https://status.x.ai/api/compat/summary.json")!
        case .windsurf: return URL(string: "https://status.windsurf.com/api/v2/summary.json")!
        case .googleCloud: return URL(string: "https://status.cloud.google.com/incidents.json")!
        }
    }

    public static func page(_ f: StatusRef.Feed) -> String {
        switch f {
        case .anthropic: return "https://status.claude.com"
        case .openai: return "https://status.openai.com"
        case .github: return "https://www.githubstatus.com"
        case .xai: return "https://status.x.ai"
        case .windsurf: return "https://status.windsurf.com"
        case .googleCloud: return "https://status.cloud.google.com"
        }
    }

    /// Atlassian Statuspage `summary.json` (and compatible feeds).
    public static func parseStatuspage(_ data: Data) throws -> FeedStatus {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
        var comps: [String: HealthLevel] = [:]
        for c in o["components"] as? [[String: Any]] ?? [] {
            if let n = c["name"] as? String { comps[n] = HealthLevel(statuspage: (c["status"] as? String) ?? "") }
        }
        var incidents: [FeedStatus.Incident] = []
        for i in o["incidents"] as? [[String: Any]] ?? [] {
            let st = (i["status"] as? String) ?? ""
            if st == "resolved" || st == "postmortem" { continue }
            let names = (i["components"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            var level = HealthLevel(statuspage: (i["impact"] as? String) ?? "minor")
            if level == .operational { level = .degraded }
            incidents.append(.init(name: (i["name"] as? String) ?? "Incident", level: level, components: names))
        }
        return FeedStatus(components: comps, incidents: incidents)
    }

    /// Google Cloud `incidents.json`: open incidents (no `end`) only.
    public static func parseGoogleCloud(_ data: Data) throws -> FeedStatus {
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CocoaError(.coderReadCorrupt) }
        var incidents: [FeedStatus.Incident] = []
        for i in arr {
            if let end = i["end"] as? String, !end.isEmpty { continue }
            let products = (i["affected_products"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
            let level: HealthLevel
            switch ((i["severity"] as? String) ?? "").lowercased() {
            case "high": level = .majorOutage
            case "medium": level = .partialOutage
            default: level = .degraded
            }
            let name = (i["external_desc"] as? String)?.split(separator: "\n").first.map(String.init) ?? "Incident"
            incidents.append(.init(name: name, level: level, components: products))
        }
        return FeedStatus(components: [:], incidents: incidents)
    }

    public static func parse(_ data: Data, feed: StatusRef.Feed) throws -> FeedStatus {
        feed == .googleCloud ? try parseGoogleCloud(data) : try parseStatuspage(data)
    }

    /// How the parts of `feed` that matter to `ref` are doing; nil when all is well.
    public static func health(for ref: StatusRef, in feed: FeedStatus) -> ProviderHealth? {
        func matches(_ name: String) -> Bool {
            ref.components.contains { name.localizedCaseInsensitiveContains($0) }
        }
        var worst = HealthLevel.operational
        var notes: [String] = []
        for (name, level) in feed.components where matches(name) && level > .operational {
            worst = max(worst, level); notes.append("\(name): \(level.label)")
        }
        for inc in feed.incidents {
            let hit = inc.components.contains(where: matches)
                || ref.incidentKeywords.contains { inc.name.localizedCaseInsensitiveContains($0) }
            if hit { worst = max(worst, inc.level); notes.append(inc.name) }
        }
        guard worst > .operational else { return nil }
        return ProviderHealth(level: worst, summary: notes.prefix(3).joined(separator: " · "), pageURL: page(ref.feed))
    }
}
