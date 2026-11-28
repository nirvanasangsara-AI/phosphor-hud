import Foundation

/// A percentile table for public pull requests opened in one window.
/// Counts outside a published band do not get a rank. The app does not interpolate one.
public struct PRRankTable: Codable, Equatable, Sendable {
    public var window: String
    public var builtAt: String
    public var bundled: Bool
    public var source: String
    public var bands: [Band]
    public var nextTier: NextTier?

    public struct Band: Codable, Equatable, Sendable {
        public var countLow: Int
        public var countHigh: Int
        public var topPercentLow: Int
        public var topPercentHigh: Int
    }

    /// The next tighter tier, in public pull requests per week. Not a personal goal.
    public struct NextTier: Codable, Equatable, Sendable {
        public var topPercent: Int
        public var perWeekLow: Int
        public var perWeekHigh: Int
    }

    public struct Hit: Equatable, Sendable {
        public var topPercentLow: Int
        public var topPercentHigh: Int
        public var next: NextTier?
        public var builtAt: String
    }

    /// The band whose published count range contains `publicCount`, or nil.
    public func lookup(publicCount: Int) -> Hit? {
        guard let band = bands.first(where: { publicCount >= $0.countLow && publicCount <= $0.countHigh }) else {
            return nil
        }
        return Hit(topPercentLow: band.topPercentLow, topPercentHigh: band.topPercentHigh,
                   next: nextTier, builtAt: builtAt)
    }

    public static func decode(_ data: Data) -> PRRankTable? {
        try? JSONDecoder().decode(PRRankTable.self, from: data)
    }

    /// Shipped analysis, dated. 11 public pull requests opened in 7 days sits in the top 10–20%.
    /// The next published tier, top 5%, is 22–41 public pull requests per week.
    /// This is not a fit to a fresh GH Archive sample.
    public static let bundledJSON = """
    {"window":"7d","builtAt":"2026-11-28","bundled":true,"source":"Shipped analysis snapshot (2026-11-28). 11 public PRs opened in 7 days is the top 10–20%. Top 5% is 22–41 public PRs per week. The worker has not published a GH Archive sample yet.","bands":[{"countLow":11,"countHigh":11,"topPercentLow":10,"topPercentHigh":20}],"nextTier":{"topPercent":5,"perWeekLow":22,"perWeekHigh":41}}
    """

    public static var bundled: PRRankTable {
        decode(Data(bundledJSON.utf8))!
    }
}
