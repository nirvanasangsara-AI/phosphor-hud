import Foundation

public struct ModelPrice: Codable, Sendable, Hashable {
    public var input: Double        // USD per token
    public var output: Double
    public var cacheRead: Double?
    public var cacheWrite: Double?
    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
}

/// API list prices, from LiteLLM's public `model_prices_and_context_window.json`.
/// Nothing is guessed: a model missing from the table has no price.
public struct PriceTable: Sendable {
    /// GitHub's raw host first, then jsDelivr. A TLS failure on one host must not empty the table.
    public static let sourceURLs: [URL] = [
        URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!,
        URL(string: "https://cdn.jsdelivr.net/gh/BerriAI/litellm@main/model_prices_and_context_window.json")!,
    ]
    public static let sourceURL = sourceURLs[0]
    public private(set) var prices: [String: ModelPrice]

    public init(prices: [String: ModelPrice] = [:]) { self.prices = prices }

    public init(litellmJSON data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        var out: [String: ModelPrice] = [:]
        for (k, v) in root where k != "sample_spec" {
            guard let d = v as? [String: Any],
                  let i = (d["input_cost_per_token"] as? NSNumber)?.doubleValue,
                  let o = (d["output_cost_per_token"] as? NSNumber)?.doubleValue else { continue }
            out[k.lowercased()] = ModelPrice(input: i, output: o,
                                             cacheRead: (d["cache_read_input_token_cost"] as? NSNumber)?.doubleValue,
                                             cacheWrite: (d["cache_creation_input_token_cost"] as? NSNumber)?.doubleValue)
        }
        self.prices = out
    }

    public var isEmpty: Bool { prices.isEmpty }

    /// Exact name first, then without a provider prefix, a date stamp, or a "[1m]"-style tag.
    /// If those miss, a suffix match finds official list prices stored under `openai.gpt-…`
    /// or `vendor/gpt-…` keys. Regional markups (azure/eu, …) are a last resort.
    public func price(for model: String) -> ModelPrice? {
        for key in Self.candidates(model) { if let p = prices[key] { return p } }
        return suffixMatch(model)
    }

    private func suffixMatch(_ model: String) -> ModelPrice? {
        let want = Self.candidates(model).first ?? model.lowercased()
        guard !want.isEmpty else { return nil }
        var best: (Int, ModelPrice)?
        for (k, p) in prices {
            let last = k.split(separator: "/").last.map(String.init) ?? k
            guard last == want || k.hasSuffix("." + want) || k.hasSuffix("/" + want) else { continue }
            let rank: Int
            if k == want || k == "openai/" + want { rank = 0 }
            else if k.hasPrefix("openai/") || k.hasPrefix("openai.") || k.hasPrefix("global.openai.") { rank = 1 }
            else if k.hasPrefix("azure/eu/") || k.hasPrefix("azure/apac/") || k.hasPrefix("azure/us/") { rank = 8 }
            else { rank = 4 }
            if best == nil || rank < best!.0 { best = (rank, p) }
        }
        return best?.1
    }

    static func candidates(_ model: String) -> [String] {
        var m = model.lowercased().trimmingCharacters(in: .whitespaces)
        var out = [m]
        if let r = m.range(of: #"\[[^\]]*\]$"#, options: .regularExpression) { m.removeSubrange(r); out.append(m) }
        if let slash = m.lastIndex(of: "/") { m = String(m[m.index(after: slash)...]); out.append(m) }
        for pattern in [#"[-@]\d{8}$"#, #"-\d{4}-\d{2}-\d{2}$"#, #"-latest$"#] {
            if let r = m.range(of: pattern, options: .regularExpression) { m.removeSubrange(r); out.append(m) }
        }
        out += ["anthropic/\(m)", "openai/\(m)", "gemini/\(m)"]
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// API-equivalent cost in USD; the tool's own logged cost wins; nil when the model has no price.
    public func cost(_ u: TokenUsage, model: String) -> Double? {
        if let c = u.loggedCost { return c }
        guard let p = price(for: model) else { return nil }
        return Double(u.input) * p.input + Double(u.output) * p.output
            + Double(u.cacheRead) * (p.cacheRead ?? p.input) + Double(u.cacheWrite) * (p.cacheWrite ?? p.input)
    }
}

/// How often a downloaded table is trusted, and how soon a failed download is tried again.
public enum PriceRefresh {
    public static let timeout: TimeInterval = 20
    public static let retryDelay: TimeInterval = 120
    public static let cacheFresh: TimeInterval = 86_400

    /// A fresh cache skips the network. A bundle, a parse failure, or an empty table does not.
    public static func shouldFetch(cachedAt: Date?, ready: Bool, origin: String, now: Date = Date(), force: Bool = false) -> Bool {
        if force { return true }
        guard ready, origin == "cache", let cachedAt else { return true }
        return now.timeIntervalSince(cachedAt) >= cacheFresh
    }
}

public struct PriceHTTPResponse: Sendable {
    public var status: Int
    public var data: Data
    public init(status: Int, data: Data) {
        self.status = status
        self.data = data
    }
}

/// URL loading is injected so tests can fail the first host without touching the network.
public protocol PriceURLLoading: Sendable {
    func load(url: URL, timeout: TimeInterval) async throws -> PriceHTTPResponse
}

public struct URLSessionPriceLoader: PriceURLLoading {
    public init() {}
    public func load(url: URL, timeout: TimeInterval) async throws -> PriceHTTPResponse {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let (data, resp) = try await URLSession.shared.data(for: req)
        return PriceHTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }
}

public struct PriceFetchResult: Sendable, Equatable {
    public var data: Data
    public var host: String
    public init(data: Data, host: String) {
        self.data = data
        self.host = host
    }
}

public enum PriceFetcher {
    /// Tries each URL. A thrown error, a non-200, or a body that is not a price table falls through.
    public static func fetch(urls: [URL] = PriceTable.sourceURLs,
                              loader: any PriceURLLoading,
                              timeout: TimeInterval = PriceRefresh.timeout) async -> PriceFetchResult? {
        for url in urls {
            let response: PriceHTTPResponse
            do { response = try await loader.load(url: url, timeout: timeout) } catch { continue }
            guard response.status == 200 else { continue }
            guard let table = try? PriceTable(litellmJSON: response.data), !table.isEmpty else { continue }
            return PriceFetchResult(data: response.data, host: url.host ?? url.absoluteString)
        }
        return nil
    }
}

public enum PriceLoading {
    public struct Outcome: Sendable {
        public var table: PriceTable
        public var origin: String
        public var bundledOn: String?
        public init(table: PriceTable, origin: String, bundledOn: String?) {
            self.table = table
            self.origin = origin
            self.bundledOn = bundledOn
        }
    }

    /// Date stamped into a bundled file by `scripts/update-bundled-prices.sh`. Absent on a raw download.
    public static func bundledDate(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["_phosphor_bundled"] as? String
    }

    /// Cache first. A cache that fails to parse falls through to the bundle.
    /// A missing bundle is origin `none`, not an error (`swift run` has no app resources).
    public static func choose(cache: Data?, bundle: Data?) -> Outcome {
        if let cache, let table = try? PriceTable(litellmJSON: cache), !table.isEmpty {
            return Outcome(table: table, origin: "cache", bundledOn: nil)
        }
        if let bundle, let table = try? PriceTable(litellmJSON: bundle), !table.isEmpty {
            return Outcome(table: table, origin: "bundle", bundledOn: bundledDate(bundle))
        }
        return Outcome(table: PriceTable(), origin: "none", bundledOn: nil)
    }
}

public enum PriceCache {
    /// Writes the downloaded body atomically, then reads it back so a torn write cannot become the table.
    public static func storeAndReload(data: Data, cache: URL, bundle: Data?) throws -> PriceLoading.Outcome {
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cache, options: .atomic)
        let read = try Data(contentsOf: cache)
        return PriceLoading.choose(cache: read, bundle: bundle)
    }
}
