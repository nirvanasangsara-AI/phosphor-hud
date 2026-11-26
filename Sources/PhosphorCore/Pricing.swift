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
    public static let sourceURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
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
    public func price(for model: String) -> ModelPrice? {
        for key in Self.candidates(model) { if let p = prices[key] { return p } }
        return nil
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
