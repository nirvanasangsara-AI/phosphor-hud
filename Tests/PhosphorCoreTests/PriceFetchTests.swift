import Foundation
import Testing
@testable import PhosphorCore

private let priced = Data(#"{"gpt":{"input_cost_per_token":0.000001,"output_cost_per_token":0.000002}}"#.utf8)

private struct ScriptedPriceLoader: PriceURLLoading {
    var steps: [String: Result<PriceHTTPResponse, Error>]
    func load(url: URL, timeout: TimeInterval) async throws -> PriceHTTPResponse {
        if timeout != PriceRefresh.timeout { throw URLError(.timedOut) }
        switch steps[url.host ?? ""] {
        case .success(let response): return response
        case .failure(let error): throw error
        case nil: throw URLError(.cannotConnectToHost)
        }
    }
}

@Suite struct PriceFetchTests {
    @Test func sourceOrderIsGitHubThenJsDelivr() {
        #expect(PriceTable.sourceURLs.map(\.host) == ["raw.githubusercontent.com", "cdn.jsdelivr.net"])
        #expect(PriceRefresh.timeout == 20)
        #expect(PriceRefresh.retryDelay == 120)
    }

    @Test func networkErrorFallsThroughToSecondHost() async {
        let loader = ScriptedPriceLoader(steps: [
            "raw.githubusercontent.com": .failure(URLError(.secureConnectionFailed)),
            "cdn.jsdelivr.net": .success(PriceHTTPResponse(status: 200, data: priced)),
        ])
        let got = await PriceFetcher.fetch(loader: loader)
        #expect(got?.host == "cdn.jsdelivr.net")
        #expect(try! PriceTable(litellmJSON: got!.data).price(for: "gpt") != nil)
    }

    @Test func non200AndParseFailureFallThrough() async {
        let loader = ScriptedPriceLoader(steps: [
            "raw.githubusercontent.com": .success(PriceHTTPResponse(status: 500, data: priced)),
            "cdn.jsdelivr.net": .success(PriceHTTPResponse(status: 200, data: Data("not-json".utf8))),
        ])
        #expect(await PriceFetcher.fetch(loader: loader) == nil)

        let parsed = ScriptedPriceLoader(steps: [
            "raw.githubusercontent.com": .success(PriceHTTPResponse(status: 200, data: Data("{}".utf8))),
            "cdn.jsdelivr.net": .success(PriceHTTPResponse(status: 200, data: priced)),
        ])
        #expect(await PriceFetcher.fetch(loader: parsed)?.host == "cdn.jsdelivr.net")
    }

    @Test func cacheWinsUntilItFailsToParse() {
        let bundle = Data(#"{"_phosphor_bundled":"2026-11-28","mini":{"input_cost_per_token":1e-6,"output_cost_per_token":2e-6}}"#.utf8)
        let cache = priced
        let fresh = PriceLoading.choose(cache: cache, bundle: bundle)
        #expect(fresh.origin == "cache")
        #expect(fresh.table.price(for: "gpt") != nil)
        #expect(fresh.bundledOn == nil)

        let broken = PriceLoading.choose(cache: Data("nope".utf8), bundle: bundle)
        #expect(broken.origin == "bundle")
        #expect(broken.bundledOn == "2026-11-28")
        #expect(broken.table.price(for: "mini") != nil)

        let missing = PriceLoading.choose(cache: nil, bundle: nil)
        #expect(missing.origin == "none" && missing.table.isEmpty)
    }

    @Test func atomicStoreReloadsTheCache() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("phosphor-prices-\(UUID().uuidString)")
        let cache = dir.appendingPathComponent("litellm-prices.json")
        let bundle = Data(#"{"_phosphor_bundled":"2026-01-01","bundled":{"input_cost_per_token":1,"output_cost_per_token":1}}"#.utf8)
        let loaded = try PriceCache.storeAndReload(data: priced, cache: cache, bundle: bundle)
        #expect(loaded.origin == "cache")
        #expect(loaded.table.price(for: "gpt") != nil)
        let again = try PriceCache.storeAndReload(data: Data("garbage".utf8), cache: cache, bundle: bundle)
        #expect(again.origin == "bundle")
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func freshCacheSkipsFetchUntilForced() {
        let now = Date()
        #expect(!PriceRefresh.shouldFetch(cachedAt: now, ready: true, origin: "cache", now: now))
        #expect(PriceRefresh.shouldFetch(cachedAt: now.addingTimeInterval(-90_000), ready: true, origin: "cache", now: now))
        #expect(PriceRefresh.shouldFetch(cachedAt: now, ready: true, origin: "bundle", now: now))
        #expect(PriceRefresh.shouldFetch(cachedAt: now, ready: false, origin: "cache", now: now))
        #expect(PriceRefresh.shouldFetch(cachedAt: now, ready: true, origin: "cache", now: now, force: true))
    }

    @Test func bundledFileStaysUnderAMegabyte() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("packaging/litellm-prices.min.json")
        let data = try Data(contentsOf: url)
        #expect(data.count < 1_000_000)
        let table = try PriceTable(litellmJSON: data)
        #expect(!table.isEmpty)
        #expect(PriceLoading.bundledDate(data) != nil)
        #expect(table.price(for: "gpt-4o") != nil || table.prices.count > 100)
    }
}
