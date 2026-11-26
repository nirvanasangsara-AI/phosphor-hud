import Foundation
import PhosphorCore

/// Readers for catalog providers beyond the native ones. Each is honest about what it can see:
/// a provider with no usage API shows as "installed" with whatever its billing screen said.
enum ExtraSources {
    static func source(for spec: ProviderSpec, evidence: String?, logs: UsageLogs.Snapshot) -> UsageSource {
        switch spec.id {
        case "ollama": return OllamaSource(spec: spec)
        case "lmstudio": return LMStudioSource(spec: spec)
        case "openrouter": return OpenRouterSource(spec: spec)
        case "openai-api": return OpenAICostSource(spec: spec)
        case "anthropic-api": return AnthropicCostSource(spec: spec)
        case "gemini-api": return GeminiAPISource(spec: spec)
        case "vertex": return VertexSource(spec: spec)
        default:
            if spec.sources.contains(.localLogs) { return LogUsageSource(spec: spec, evidence: evidence, logs: logs) }
            return InstalledSource(spec: spec, evidence: evidence)
        }
    }

    static func info(_ spec: ProviderSpec) -> ProviderInfo { ProviderInfo.lookup(spec.id) }
}

/// No public usage API: show that it's installed; plan/price/next bill come from billing-screens.json.
struct InstalledSource: UsageSource {
    let spec: ProviderSpec
    let evidence: String?
    func fetch() async -> [ProviderSnapshot] {
        let msg: String
        switch evidence {
        case "billing-screens.json"?: msg = "No usage API · plan/price from its billing screen (hover)"
        case let e?: msg = "Installed (\(e)) · no usage API — hover for billing screen"
        case nil: msg = spec.screenOnly ? "Web only · read \(spec.billingURL ?? "its settings page") into billing-screens.json"
                                        : "Turned on · not found on this Mac"
        }
        let state: ProviderState = evidence == nil && !spec.screenOnly ? .unavailable(msg) : .idle(msg, plan: nil)
        return [ProviderSnapshot(info: ExtraSources.info(spec), state: state, updatedAt: Date())]
    }
}

/// Token counts from the tool's own session logs (Gemini CLI, Cline, Roo Code).
struct LogUsageSource: UsageSource {
    let spec: ProviderSpec
    let evidence: String?
    let logs: UsageLogs.Snapshot
    func fetch() async -> [ProviderSnapshot] {
        let info = ExtraSources.info(spec)
        guard let week = logs.week[spec.id], week.tokens > 0 else {
            let why = logs.scannedAt == nil ? "Scanning local logs…" : "Installed · no token usage in its logs (35 days)"
            return [ProviderSnapshot(info: info, state: evidence == nil ? .unavailable(why) : .idle(why, plan: nil), updatedAt: Date())]
        }
        var w = [UsageWindow.meter("TODAY", used: Double(logs.today[spec.id]?.tokens ?? 0), unit: "tokens"),
                 UsageWindow.meter("7D", used: Double(week.tokens), unit: "tokens")]
        if week.cost > 0 { w.append(.meter("7D EST", used: week.cost, unit: "usd")) }
        return [ProviderSnapshot(info: info, state: .ok(windows: w, plan: "local logs"), updatedAt: Date())]
    }
}

// MARK: - Google

/// Gemini API (AI Studio key). Google offers no usage or billing endpoint for API keys, so this only
/// confirms the key works; spend and free/paid tier are on aistudio.google.com/usage.
struct GeminiAPISource: UsageSource {
    let spec: ProviderSpec
    func fetch() async -> [ProviderSnapshot] {
        await single(ExtraSources.info(spec)) {
            guard let key = await APIKeys.key(spec) else { throw ProviderError.notConfigured(APIKeys.howTo(spec)) }
            var r = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!)
            r.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let obj = try await HTTP.json(r)
            let n = (obj["models"] as? [Any])?.count ?? 0
            throw ProviderError.idle("Key works (\(n) models) · Google reports usage only in AI Studio (aistudio.google.com/usage)")
        }
    }
}

/// Vertex AI through gcloud's own configuration. Spend needs a Cloud Billing BigQuery export,
/// so this reports whether gcloud is set up, never a guessed number.
struct VertexSource: UsageSource {
    let spec: ProviderSpec
    func fetch() async -> [ProviderSnapshot] {
        await single(ExtraSources.info(spec)) {
            guard let bin = Shell.which("gcloud", extra: ["/opt/homebrew/share/google-cloud-sdk/bin/gcloud",
                                                         "\(Paths.home.path)/google-cloud-sdk/bin/gcloud"]) else {
                throw ProviderError.notConfigured("gcloud not installed")
            }
            guard let project = try? await Shell.run(bin, ["config", "get-value", "project"], timeout: 15) else {
                throw ProviderError.idle("gcloud found but not working (reinstall the Cloud SDK)")
            }
            if project.isEmpty || project == "(unset)" { throw ProviderError.idle("gcloud works · no project set") }
            throw ProviderError.idle("gcloud project set · Vertex spend is only in Cloud Billing (BigQuery export)")
        }
    }
}

// MARK: - Local model servers (free; shows what's installed and loaded)

struct OllamaSource: UsageSource {
    let spec: ProviderSpec
    func fetch() async -> [ProviderSnapshot] {
        await single(ExtraSources.info(spec)) {
            let base = ProcessInfo.processInfo.environment["OLLAMA_HOST"].map { $0.hasPrefix("http") ? $0 : "http://\($0)" }
                ?? "http://127.0.0.1:11434"
            let tags: [String: Any]
            do { tags = try await HTTP.json(URLRequest(url: URL(string: base + "/api/tags")!)) }
            catch { throw ProviderError.idle("Installed · server not running") }
            let ps = (try? await HTTP.json(URLRequest(url: URL(string: base + "/api/ps")!))) ?? [:]
            let models = (tags["models"] as? [Any])?.count ?? 0
            let loaded = (ps["models"] as? [[String: Any]]) ?? []
            let vram = loaded.compactMap { num($0["size_vram"]) }.reduce(0, +)
            var w: [UsageWindow] = [.meter("MODELS", used: Double(models), unit: "installed"),
                                    .meter("LOADED", used: Double(loaded.count), unit: "running")]
            if vram > 0 { w.append(.meter("VRAM", used: vram / 1_073_741_824, unit: "GB")) }
            return (w, "Local · free")
        }
    }
}

struct LMStudioSource: UsageSource {
    let spec: ProviderSpec
    func fetch() async -> [ProviderSnapshot] {
        await single(ExtraSources.info(spec)) {
            let obj: [String: Any]
            do { obj = try await HTTP.json(URLRequest(url: URL(string: "http://127.0.0.1:1234/v1/models")!)) }
            catch { throw ProviderError.idle("Installed · server not running") }
            let n = (obj["data"] as? [Any])?.count ?? 0
            return ([.meter("MODELS", used: Double(n), unit: "available")], "Local · free")
        }
    }
}

// MARK: - API keys you give Phosphor

/// OpenRouter: `GET /api/v1/key` (limit, usage) and `/api/v1/credits` (balance).
struct OpenRouterSource: UsageSource {
    let spec: ProviderSpec
    func fetch() async -> [ProviderSnapshot] {
        await single(ExtraSources.info(spec)) {
            guard let key = await APIKeys.key(spec) else { throw ProviderError.notConfigured(APIKeys.howTo(spec)) }
            func get(_ path: String) async throws -> [String: Any] {
                var r = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/" + path)!)
                r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                return (try await HTTP.json(r))["data"] as? [String: Any] ?? [:]
            }
            var w: [UsageWindow] = []
            if let c = try? await get("credits"), let total = num(c["total_credits"]), let used = num(c["total_usage"]) {
                w.append(.balance("CREDIT", left: total - used, total: total, unit: "usd"))
            }
            let k = try await get("key")
            if let limit = num(k["limit"]), limit > 0, let left = num(k["limit_remaining"]) {
                w.append(.balance("KEY", left: left, total: limit, unit: "usd"))
            }
            if let daily = num(k["usage_daily"]) { w.append(.meter("1D", used: daily, unit: "usd")) }
            if let monthly = num(k["usage_monthly"]) { w.append(.meter("30D", used: monthly, unit: "usd")) }
            else if let usage = num(k["usage"]) { w.append(.meter("ALL", used: usage, unit: "usd")) }
            if w.isEmpty { throw ProviderError.idle("Key works · nothing to report") }
            return (w, (k["is_free_tier"] as? Bool) == true ? "Free tier" : "Pay as you go")
        }
    }
}

enum MonthRange {
    static var start: Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    }
}

/// OpenAI organisation costs (`/v1/organization/costs`), with an Admin key only.
struct OpenAICostSource: UsageSource {
    let spec: ProviderSpec
    func fetch() async -> [ProviderSnapshot] {
        await single(ExtraSources.info(spec)) {
            guard let key = await APIKeys.key(spec) else { throw ProviderError.notConfigured(APIKeys.howTo(spec)) }
            var total = 0.0, page: String?, pages = 0
            repeat {
                var c = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
                c.queryItems = [.init(name: "start_time", value: String(Int(MonthRange.start.timeIntervalSince1970))),
                                .init(name: "bucket_width", value: "1d"), .init(name: "limit", value: "31")]
                if let page { c.queryItems?.append(.init(name: "page", value: page)) }
                var r = URLRequest(url: c.url!)
                r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                let obj = try await HTTP.json(r)
                for b in obj["data"] as? [[String: Any]] ?? [] {
                    for res in b["results"] as? [[String: Any]] ?? [] {
                        total += num((res["amount"] as? [String: Any])?["value"]) ?? 0
                    }
                }
                page = (obj["has_more"] as? Bool) == true ? obj["next_page"] as? String : nil
                pages += 1
            } while page != nil && pages < 5
            return ([.meter("MONTH", used: total, unit: "usd")], "API · this month")
        }
    }
}

/// Anthropic organisation cost report (`/v1/organizations/cost_report`), with an Admin key only.
/// Amounts arrive as decimal strings in cents.
struct AnthropicCostSource: UsageSource {
    let spec: ProviderSpec
    func fetch() async -> [ProviderSnapshot] {
        await single(ExtraSources.info(spec)) {
            guard let key = await APIKeys.key(spec) else { throw ProviderError.notConfigured(APIKeys.howTo(spec)) }
            let iso = ISO8601DateFormatter()
            var cents = 0.0, page: String?, pages = 0
            repeat {
                var c = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
                c.queryItems = [.init(name: "starting_at", value: iso.string(from: MonthRange.start)),
                                .init(name: "limit", value: "31")]
                if let page { c.queryItems?.append(.init(name: "page", value: page)) }
                var r = URLRequest(url: c.url!)
                r.setValue(key, forHTTPHeaderField: "x-api-key")
                r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                let obj = try await HTTP.json(r)
                for b in obj["data"] as? [[String: Any]] ?? [] {
                    for res in b["results"] as? [[String: Any]] ?? [] { cents += num(res["amount"]) ?? 0 }
                }
                page = (obj["has_more"] as? Bool) == true ? obj["next_page"] as? String : nil
                pages += 1
            } while page != nil && pages < 5
            return ([.meter("MONTH", used: cents / 100, unit: "usd")], "API · this month")
        }
    }
}
