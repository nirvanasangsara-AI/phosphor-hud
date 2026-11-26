import Foundation

/// A source produces snapshots for one or more providers.
/// Phosphor never writes or refreshes anyone's credentials: it only reads
/// tokens that the official CLIs already keep on disk / in the Keychain.
protocol UsageSource {
    func fetch() async -> [ProviderSnapshot]
}

extension UsageSource {
    func single(_ info: ProviderInfo, _ body: () async throws -> ([UsageWindow], String?)) async -> [ProviderSnapshot] {
        do {
            let (w, plan) = try await body()
            return [ProviderSnapshot(info: info, state: .ok(windows: w, plan: plan), updatedAt: Date())]
        } catch let e as ProviderError {
            return [ProviderSnapshot(info: info, state: e.state, updatedAt: Date())]
        } catch {
            return [ProviderSnapshot(info: info, state: .error(error.localizedDescription), updatedAt: Date())]
        }
    }
}

// MARK: - Shared plumbing

enum HTTP {
    static func json(_ req: URLRequest) async throws -> [String: Any] {
        var req = req
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ProviderError.parse("no response") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError.expired("login expired")
        }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse("not an object")
        }
        return obj
    }
}

enum Shell {
    /// Runs a process off the main thread with a hard timeout. Returns stdout.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20,
                    env extra: [String: String] = [:], cwd: URL? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                env.merge(extra) { _, new in new }
                p.environment = env
                if let cwd { p.currentDirectoryURL = cwd }
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(throwing: ProviderError.notConfigured("cannot run \(path)"))
                    return
                }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                if p.terminationStatus == 0 {
                    cont.resume(returning: String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    cont.resume(throwing: ProviderError.notConfigured("\(URL(fileURLWithPath: path).lastPathComponent) exited \(p.terminationStatus)"))
                }
            }
        }
    }

    static func which(_ name: String, extra: [String] = []) -> String? {
        let home = Paths.home.path
        let candidates = extra + ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
                                  "\(home)/.homebrew/bin/\(name)", "\(home)/.local/bin/\(name)",
                                  "\(home)/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

func readJSONFile(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func expandTilde(_ p: String) -> String { (p as NSString).expandingTildeInPath }

// MARK: - Claude (Claude Code OAuth)

actor ClaudeSource: UsageSource {
    let info: ProviderInfo
    /// A profile's own Keychain item and config dir (accounts.json); nil = every Claude Code login.
    private let service: String?
    private let configDir: URL?
    private var cached: (token: String, plan: String?, expires: Date?)?

    init(info: ProviderInfo = ProviderInfo.lookup("claude"), service: String? = nil, configDir: String? = nil) {
        self.info = info
        self.service = service
        self.configDir = configDir.map { URL(fileURLWithPath: $0) }
    }

    func fetch() async -> [ProviderSnapshot] {
        await single(info) { try await load() }
    }

    /// Marks the "token waiting for Claude Code to refresh it" state, so the store can fill in log usage.
    static let waitingMarker = "Waiting for Claude Code"
    static func waiting(since exp: Date) -> String {
        "\(waitingMarker) to refresh its token (expired \(Fmt.clock(exp))); live limits return next time you use Claude Code"
    }

    private func credentials() async throws -> (String, String?, Date?) {
        if let c = cached, (c.expires ?? .distantFuture) > Date() { return c }
        var blob: [String: Any]?
        // Claude Code has stored its login in several places over time: the file, the
        // "Claude Code-credentials" Keychain item, and newer per-config items with a hash suffix.
        // Take whichever holds a Claude login that expires last (i.e. the freshest one).
        var candidates: [[String: Any]] = []
        let dir = configDir ?? Paths.home.appendingPathComponent(".claude")
        if let f = readJSONFile(dir.appendingPathComponent(".credentials.json")) { candidates.append(f) }
        let services: [String]
        if let service { services = [service] } else { services = await Self.keychainServices() }
        for service in services {
            if let raw = try? await Shell.run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"]),
               let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] {
                candidates.append(obj)
            }
        }
        func expiry(_ b: [String: Any]) -> Double {
            num(((b["claudeAiOauth"] as? [String: Any]) ?? b)["expiresAt"]) ?? 0
        }
        blob = candidates.filter { (($0["claudeAiOauth"] as? [String: Any]) ?? $0)["accessToken"] is String }
            .max { expiry($0) < expiry($1) }
        guard let blob else { throw ProviderError.notConfigured("Claude Code not logged in") }
        let oauth = (blob["claudeAiOauth"] as? [String: Any]) ?? blob
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ProviderError.notConfigured("no Claude OAuth token")
        }
        let exp = Fmt.date(oauth["expiresAt"])
        let plan = (oauth["subscriptionType"] as? String)?.capitalized
        if let exp, exp < Date() {
            cached = nil
            // Claude Code's access tokens are short-lived (hours). Claude Code refreshes them itself,
            // but only while it runs. A past expiry with a refresh token beside it means "Claude Code
            // hasn't run lately", not "signed out". Phosphor never uses the refresh token: that would
            // rotate Claude Code's login behind its back. So it waits, and shows local log usage.
            if oauth["refreshToken"] is String {
                throw ProviderError.idle(Self.waiting(since: exp))
            }
            throw ProviderError.expired("login expired")
        }
        cached = (token, plan, exp)
        return (token, plan, exp)
    }

    /// Limit resets Claude has granted (e.g. a free full reset), only when the user turned this on.
    /// Not exposed by Claude Code; this asks the same usage endpoint for its reset-grant block,
    /// identifying honestly as Phosphor. Shape (community-documented):
    ///   {"cedar_ember":{"eligible":true,"grants":[{"resets_left":1,"paused":false,"usable_now":true,"ends_at":"…"}]}}
    func resetCredits() async throws -> [CreditInfo] {
        let (token, _, _) = try await credentials()
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("phosphor-hud/0.1", forHTTPHeaderField: "User-Agent")
        let obj = try await HTTP.json(req)
        guard let ember = obj["cedar_ember"] as? [String: Any] else { throw ProviderError.parse("not reported") }
        guard (ember["eligible"] as? Bool) == true else {
            throw ProviderError.parse((ember["ineligible_reason"] as? String).map { "not eligible: \($0)" } ?? "not eligible")
        }
        var out: [CreditInfo] = []
        for g in ember["grants"] as? [[String: Any]] ?? [] {
            guard (g["paused"] as? Bool) != true, let left = num(g["resets_left"]), left > 0 else { continue }
            let ends = Fmt.date(g["ends_at"])
            if let ends, ends < Date() { continue }
            out.append(CreditInfo(title: "Limit reset", amount: "×\(Int(left))", expires: ends))
        }
        return out
    }

    /// Keychain service names Claude Code uses ("Claude Code-credentials" and "…-<hash>").
    /// Reads attribute names only; secrets are fetched per item above.
    static func keychainServices() async -> [String] {
        let dump = (try? await Shell.run("/usr/bin/security", ["dump-keychain"], timeout: 10)) ?? ""
        var names: Set<String> = []
        for line in dump.split(separator: "\n") where line.contains("\"svce\"<blob>=\"Claude Code-credentials") {
            if let a = line.range(of: "=\""), let b = line.range(of: "\"", options: .backwards), a.upperBound < b.lowerBound {
                names.insert(String(line[a.upperBound..<b.lowerBound]))
            }
        }
        return names.isEmpty ? ["Claude Code-credentials"] : names.sorted()
    }

    private func load() async throws -> ([UsageWindow], String?) {
        let (token, plan, _) = try await credentials()
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("phosphor-hud/0.1", forHTTPHeaderField: "User-Agent")
        let obj: [String: Any]
        do { obj = try await HTTP.json(req) } catch ProviderError.expired(let m) {
            // A 401 on a token that hasn't expired yet usually means Claude Code just rotated it:
            // read the Keychain again and retry once before calling it a sign-in problem.
            cached = nil
            let (fresh, _, _) = try await credentials()
            guard fresh != token else { throw ProviderError.expired(m) }
            req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            obj = try await HTTP.json(req)
        }

        let windows = Self.windows(from: obj)
        if windows.isEmpty { throw ProviderError.parse("no windows") }
        return (windows, plan)
    }

    /// Every window in the response, labelled.
    /// - `five_hour` is null when no 5-hour session is running: show it as 0 %, not as a missing row.
    /// - `seven_day` is the all-models weekly limit.
    /// - Model-scoped weekly limits arrive in `limits[]` as `weekly_scoped` with `scope.model.display_name`;
    ///   older accounts may instead have `seven_day_opus` / `seven_day_sonnet`.
    static func windows(from obj: [String: Any]) -> [UsageWindow] {
        func window(_ key: String) -> [String: Any]? { obj[key] as? [String: Any] }
        var out: [UsageWindow] = []
        let five = window("five_hour")
        out.append(UsageWindow(label: "5H", usedPercent: five.flatMap { num($0["utilization"]) } ?? 0,
                               resetsAt: Fmt.date(five?["resets_at"]), windowSeconds: 18000))
        if let w = window("seven_day"), let u = num(w["utilization"]) {
            out.append(UsageWindow(label: "7D", usedPercent: u, resetsAt: Fmt.date(w["resets_at"]), windowSeconds: 604800))
        }
        for (key, label) in [("seven_day_opus", "7D OPUS"), ("seven_day_sonnet", "7D SONNET"),
                             ("seven_day_oauth_apps", "7D APPS"), ("seven_day_cowork", "7D COWORK")] {
            guard let w = window(key), let u = num(w["utilization"]) else { continue }
            out.append(UsageWindow(label: label, usedPercent: u, resetsAt: Fmt.date(w["resets_at"]), windowSeconds: 604800))
        }
        for l in obj["limits"] as? [[String: Any]] ?? [] {
            guard (l["kind"] as? String) == "weekly_scoped", let u = num(l["percent"]) else { continue }
            let scope = l["scope"] as? [String: Any]
            let model = ((scope?["model"] as? [String: Any])?["display_name"] as? String)
                ?? ((scope?["surface"] as? [String: Any])?["display_name"] as? String) ?? "scoped"
            let label = "7D \(model.uppercased())"
            guard !out.contains(where: { $0.label == label }) else { continue }
            out.append(UsageWindow(label: label, usedPercent: u, resetsAt: Fmt.date(l["resets_at"]), windowSeconds: 604800))
        }
        return out
    }
}

// MARK: - Codex (ChatGPT plan via ~/.codex/auth.json)

struct CodexSource: UsageSource {
    var info = ProviderInfo.lookup("codex")
    /// A profile's CODEX_HOME (accounts.json); nil = $CODEX_HOME or ~/.codex.
    var home: String? = nil

    func fetch() async -> [ProviderSnapshot] {
        await single(info) {
            let dir = home.map { URL(fileURLWithPath: $0) }
                ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? Paths.home.appendingPathComponent(".codex")
            guard let auth = readJSONFile(dir.appendingPathComponent("auth.json")),
                  let tokens = auth["tokens"] as? [String: Any],
                  let token = tokens["access_token"] as? String else {
                throw ProviderError.notConfigured("Codex not logged in with ChatGPT")
            }
            var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let acct = tokens["account_id"] as? String {
                req.setValue(acct, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
            let obj = try await HTTP.json(req)
            let rl = obj["rate_limit"] as? [String: Any] ?? [:]
            var windows: [UsageWindow] = []
            for key in ["primary_window", "secondary_window"] {
                guard let w = rl[key] as? [String: Any], let u = num(w["used_percent"]) else { continue }
                let secs = num(w["limit_window_seconds"])
                var reset = Fmt.date(w["reset_at"])
                if reset == nil, let after = num(w["reset_after_seconds"]) { reset = Date().addingTimeInterval(after) }
                windows.append(UsageWindow(label: Fmt.windowLabel(seconds: secs), usedPercent: u,
                                           resetsAt: reset, windowSeconds: secs))
            }
            if windows.isEmpty { throw ProviderError.parse("no rate_limit windows") }
            // A null slot means that window isn't running right now; keep the 5H row as 0 %.
            if !windows.contains(where: { $0.label == "5H" }),
               rl["primary_window"] is NSNull || rl["secondary_window"] is NSNull {
                windows.insert(UsageWindow(label: "5H", usedPercent: 0, resetsAt: nil, windowSeconds: 18000), at: 0)
            }
            return (windows, (obj["plan_type"] as? String)?.capitalized)
        }
    }
}

/// Native readers by provider id (used by the store and by `Phosphor --check <id>`).
func nativeSource(_ id: String) -> UsageSource? {
    switch id {
    case "claude": return ClaudeSource()
    case "codex": return CodexSource()
    case "antigravity": return AntigravitySource()
    case "grok": return GrokSource()
    case "grokbot": return GrokBotSource()
    case "copilot": return CopilotSource()
    case "muse": return MuseSource()
    default: return nil
    }
}

// MARK: - Antigravity (Google; replaces Gemini CLI, whose individual Code Assist was retired)

/// `agy -p /usage --output-format json` (agy 1.1.11+) prints the quota report without a model
/// turn, using agy's own login. Phosphor never touches Google credentials. Shape:
///   {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[
///     {"name":"Gemini Models","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":1,
///       "reset_time":"2026-11-25T13:18:32Z"}, …]}, {"name":"Claude and GPT models", …}]}}}
struct AntigravitySource: UsageSource {
    let info = ProviderInfo.lookup("antigravity")

    static var workspace: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phosphor/agy")
    }

    func fetch() async -> [ProviderSnapshot] {
        await single(info) {
            guard let bin = Shell.which("agy") else { throw ProviderError.notConfigured("Antigravity CLI not installed") }
            try? FileManager.default.createDirectory(at: Self.workspace, withIntermediateDirectories: true)
            let raw: String
            do {
                raw = try await Shell.run(bin, ["-p", "/usage", "--output-format", "json"], timeout: 90,
                                          env: ["AGY_CLI_DISABLE_AUTO_UPDATE": "true"],   // literal "true" required
                                          cwd: Self.workspace)
            } catch {
                throw ProviderError.notConfigured("Antigravity not signed in")
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
                throw ProviderError.parse("agy usage report wasn't JSON")
            }
            guard (obj["status"] as? String) == "SUCCESS",
                  let groups = ((obj["command"] as? [String: Any])?["data"] as? [String: Any])?["groups"] as? [[String: Any]] else {
                let why = (obj["response"] as? String).map { String($0.prefix(60)) } ?? "no usage report"
                throw ProviderError.notConfigured("Antigravity: \(why)")
            }
            var windows: [UsageWindow] = []
            for (gi, group) in groups.enumerated() {
                // First group is Gemini models (plain labels); others get a short suffix.
                let name = (group["name"] as? String ?? "").lowercased()
                let suffix = gi == 0 || name.contains("gemini") ? "" : (name.contains("claude") || name.contains("gpt") ? " CL·GPT" : " \(gi + 1)")
                let buckets = (group["buckets"] as? [[String: Any]] ?? []).sorted {
                    ($0["window"] as? String == "5h" ? 0 : 1) < ($1["window"] as? String == "5h" ? 0 : 1)
                }
                for bucket in buckets {
                    guard let left = num(bucket["remaining_fraction"]) else { continue }
                    let w = bucket["window"] as? String ?? ""
                    let (label, secs): (String, Double?) = w == "5h" ? ("5H", 18000) : w == "weekly" ? ("7D", 604800)
                        : (w.uppercased(), nil)
                    var reset = Fmt.date(bucket["reset_time"])
                    if let r = reset, r.timeIntervalSince1970 < 86400 { reset = nil }   // 1970 = window not started
                    windows.append(UsageWindow(label: label + suffix, usedPercent: max(0, min(100, (1 - left) * 100)),
                                               resetsAt: reset, windowSeconds: secs))
                }
            }
            if windows.isEmpty { throw ProviderError.notConfigured("no Antigravity quota on this account") }
            return (windows, nil)
        }
    }
}

// MARK: - Grok (SuperGrok plan via ~/.grok/auth.json, written by `grok login`)

struct GrokSource: UsageSource {
    let info = ProviderInfo.lookup("grok")

    func fetch() async -> [ProviderSnapshot] {
        await single(info) {
            guard let auth = readJSONFile(Paths.home.appendingPathComponent(".grok/auth.json")),
                  let entry = auth.values.compactMap({ $0 as? [String: Any] }).first(where: { $0["key"] is String }),
                  let token = entry["key"] as? String, !token.isEmpty else {
                throw ProviderError.notConfigured("Grok CLI not logged in")
            }
            if let exp = Fmt.date(entry["expires_at"]), exp < Date() {
                throw ProviderError.expired("login expired")
            }
            var req = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
            let obj = try await HTTP.json(req)
            let cfg = obj["config"] as? [String: Any] ?? obj
            var used = num(cfg["creditUsagePercent"])
            if used == nil, let u = num((cfg["onDemandUsed"] as? [String: Any])?["val"]),
               let cap = num((cfg["onDemandCap"] as? [String: Any])?["val"]), cap > 0 {
                used = u / cap * 100
            }
            let period = cfg["currentPeriod"] as? [String: Any]
            let end = Fmt.date(period?["end"]) ?? Fmt.date(cfg["billingPeriodEnd"])
            let start = Fmt.date(period?["start"]) ?? Fmt.date(cfg["billingPeriodStart"])
            // Early in a period Grok omits the percentage entirely: an active period with nothing
            // reported is 0 % used, not unknown.
            if used == nil, let start, let end, start <= Date(), Date() < end { used = 0 }
            guard let used else { throw ProviderError.parse("no credit usage in billing response") }
            let secs = (start != nil && end != nil) ? end!.timeIntervalSince(start!) : nil
            let window = UsageWindow(label: Fmt.windowLabel(seconds: secs), usedPercent: used, resetsAt: end, windowSeconds: secs)
            let plan = (obj["subscription_tier"] as? String ?? cfg["subscriptionTier"] as? String)?.capitalized
            return ([window], plan)
        }
    }
}

// MARK: - Muse Code (Meta) via `muse usage --json` (Muse CLI 1.4.13+)

/// The Muse CLI reads its own login (Keychain or file) and reports the allowance without a model
/// turn, so Phosphor never touches Muse's credentials. With a plan:
///   {"schemaVersion":1,"allowance":{"tier":"Muse Code Power Usage",
///     "window":{"usedPercent":25,"resetsAtMs":…},"weekly":{"usedPercent":75,"resetsAtMs":…}},"reason":null}
/// Signed in without a plan (e.g. the contributor model), Muse 1.4.25 reports nothing to count:
///   {"schemaVersion":1,"allowance":null,"reason":"no_allowance","hint":null}
/// Signed in is told apart from signed out by Muse's own login record (~/.config/muse/auth.json,
/// read for the provider entry only; the token itself lives in the Keychain and isn't touched).
struct MuseSource: UsageSource {
    let info = ProviderInfo.lookup("muse")

    static var signedIn: Bool {
        if ProcessInfo.processInfo.environment["META_API_KEY"]?.isEmpty == false { return true }
        let url = Paths.home.appendingPathComponent(".config/muse/auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let providers = obj["providers"] as? [String: Any] else { return false }
        return providers["meta"] is [String: Any]
    }

    func fetch() async -> [ProviderSnapshot] {
        await single(info) {
            guard let bin = Shell.which("muse") else { throw ProviderError.notConfigured("Muse Code not connected") }
            let raw = try await Shell.run(bin, ["usage", "--json"], timeout: 25)
            guard let data = raw.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw ProviderError.parse("`muse usage --json` did not print JSON (needs Muse CLI 1.4.13+)")
            }
            guard let allowance = obj["allowance"] as? [String: Any] else {
                // No % allowance. A balance or a usage count, if Muse reports one, is still worth showing.
                let extra = Self.balanceOrMeter(obj)
                if !extra.isEmpty { return (extra, nil) }
                let reason = obj["reason"] as? String ?? "no allowance"
                if reason == "api_key" {
                    throw ProviderError.idle("Signed in with an API key · no usage data")
                }
                if Self.signedIn {
                    throw ProviderError.idle("Signed in · no usage data yet")
                }
                if reason == "no_allowance" || reason.contains("login") {
                    throw ProviderError.notConfigured("Muse Code not signed in")
                }
                throw ProviderError.parse("Muse: \(reason.replacingOccurrences(of: "_", with: " "))")
            }
            var windows: [UsageWindow] = []
            for (key, label, secs) in [("window", "5H", 18000.0), ("weekly", "7D", 604800.0)] {
                let w = allowance[key] as? [String: Any]
                // An idle 5-hour window can be missing: show it as 0%, like Claude's.
                guard let u = w.flatMap({ num($0["usedPercent"]) }) ?? (key == "window" ? 0 : nil) else { continue }
                let reset = (w?["resetsAtMs"]).flatMap(num).map { Date(timeIntervalSince1970: $0 / 1000) }
                windows.append(UsageWindow(label: label, usedPercent: u, resetsAt: reset, windowSeconds: secs))
            }
            windows += Self.balanceOrMeter(obj)
            let plan = (allowance["tier"] as? String).map {
                $0.replacingOccurrences(of: "Muse Code ", with: "").replacingOccurrences(of: " Usage", with: "")
            }
            return (windows, plan)
        }
    }

    /// `balance` → what's left (with a bar if Muse also says the total); otherwise `usage` → a meter.
    /// Neither is in Muse 1.4.25's output; read them if a later version adds them.
    static func balanceOrMeter(_ obj: [String: Any]) -> [UsageWindow] {
        if let b = obj["balance"] as? [String: Any],
           let left = num(b["remaining"]) ?? num(b["left"]) ?? num(b["balance"]) {
            return [.balance("BAL", left: left, total: num(b["total"]) ?? num(b["limit"]),
                             unit: b["unit"] as? String ?? "credits", resetsAt: Fmt.date(b["resetsAt"] ?? b["resetsAtMs"]))]
        }
        if let u = obj["usage"] as? [String: Any],
           let used = num(u["tokens"]) ?? num(u["used"]) {
            let secs = num(u["windowSeconds"]) ?? 604800
            return [.meter(Fmt.windowLabel(seconds: secs), used: used, unit: u["unit"] as? String ?? "tokens",
                           resetsAt: Fmt.date(u["resetsAt"] ?? u["resetsAtMs"]), windowSeconds: secs)]
        }
        return []
    }
}

// MARK: - GitHub Copilot (quota via the GitHub CLI's login: `gh auth login`)

struct CopilotSource: UsageSource {
    let info = ProviderInfo.lookup("copilot")

    func fetch() async -> [ProviderSnapshot] {
        await single(info) {
            guard let gh = Shell.which("gh"),
                  let token = try? await Shell.run(gh, ["auth", "token"], timeout: 10)
                      .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                throw ProviderError.notConfigured("GitHub CLI not logged in")
            }
            var req = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
            req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("phosphor-hud", forHTTPHeaderField: "User-Agent")
            let obj = try await HTTP.json(req)
            let snaps = obj["quota_snapshots"] as? [String: Any] ?? [:]
            let reset = Fmt.date(obj["quota_reset_date_utc"]) ?? Fmt.date(obj["quota_reset_date"])
            var windows: [UsageWindow] = []
            for (key, label) in [("premium_interactions", "PREMIUM"), ("chat", "CHAT"), ("completions", "COMPL")] {
                guard let q = snaps[key] as? [String: Any], (q["unlimited"] as? Bool) != true,
                      let entitled = num(q["entitlement"]), entitled > 0,      // 0 = not part of this plan
                      let left = num(q["percent_remaining"]) else { continue }
                windows.append(UsageWindow(label: label, usedPercent: max(0, 100 - left), resetsAt: reset,
                                           windowSeconds: 30 * 86400))
            }
            if windows.isEmpty { throw ProviderError.notConfigured("no Copilot plan on this GitHub account") }
            let plan = ((obj["access_type_sku"] as? String)?.hasPrefix("free") == true) ? "Free"
                : (obj["copilot_plan"] as? String).map { $0 == "individual" ? "Individual" : $0.capitalized }
            return (windows, plan)
        }
    }
}

// MARK: - Custom providers (~/.config/phosphor/providers.json)

/// Anything Phosphor doesn't read natively can be added with a tiny script. Each entry:
///   { "id": "perplexity", "name": "Perplexity", "color": "#20B8CD",
///     "command": "~/.config/phosphor/scripts/perplexity.sh" }
/// The command must print:
///   { "plan": "Pro", "windows": [ { "label": "1D", "used": 42,
///     "resetsAt": "2026-11-25T00:00:00Z", "windowSeconds": 86400 } ] }
/// A window can also be { "kind": "balance", "left": 1200, "total": 5000, "unit": "credits" }
/// (total optional) or { "kind": "meter", "used": 820000, "unit": "tokens", "windowSeconds": 604800 }.
struct CustomSource: UsageSource {
    func fetch() async -> [ProviderSnapshot] {
        guard let data = try? Data(contentsOf: Paths.customProviders),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        var out: [ProviderSnapshot] = []
        for entry in list {
            guard let id = entry["id"] as? String, let cmd = entry["command"] as? String else { continue }
            let info = ProviderInfo.lookup(id, name: entry["name"] as? String, colorHex: entry["color"] as? String)
            out += await single(info) {
                let raw = try await Shell.run("/bin/sh", ["-c", expandTilde(cmd)], timeout: 30)
                guard let d = raw.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                    throw ProviderError.parse("command did not print JSON")
                }
                let ws = (obj["windows"] as? [[String: Any]] ?? []).compactMap { w -> UsageWindow? in
                    let secs = num(w["windowSeconds"])
                    let label = (w["label"] as? String) ?? Fmt.windowLabel(seconds: secs)
                    let reset = Fmt.date(w["resetsAt"]), unit = w["unit"] as? String ?? ""
                    switch w["kind"] as? String ?? "quota" {
                    case "balance":
                        guard let left = num(w["left"]) else { return nil }
                        return .balance(label, left: left, total: num(w["total"]), unit: unit,
                                        resetsAt: reset, windowSeconds: secs)
                    case "meter":
                        guard let used = num(w["used"]) else { return nil }
                        return .meter(label, used: used, unit: unit, resetsAt: reset, windowSeconds: secs)
                    default:
                        guard let u = num(w["used"]) else { return nil }
                        return UsageWindow(label: label, usedPercent: u, resetsAt: reset, windowSeconds: secs)
                    }
                }
                if ws.isEmpty { throw ProviderError.parse("no windows") }
                return (ws, obj["plan"] as? String)
            }
        }
        return out
    }
}

// MARK: - Demo data (`Phosphor --demo`) for screenshots and theme previews

/// Fake but plausible numbers. Each refresh advances a tick so the demo looks alive:
/// Grok climbs to 99%, then its window resets (Raid Frames shows the revive).
@MainActor
final class DemoSource {
    private var tick = 0

    private struct Row { let id: String; let plan: String; let windows: [(String, Double, Double, Double, Double)] }
    // (label, used %, resets in s, window s, burn rate %/h)
    private let rows: [Row] = [
        Row(id: "claude", plan: "Max", windows: [("5H", 62, 6000, 18000, 28), ("7D", 41, 300000, 604800, 0.5)]),
        Row(id: "codex", plan: "Pro", windows: [("5H", 18, 14000, 18000, 6), ("7D", 77, 90000, 604800, 1.5)]),
        Row(id: "antigravity", plan: "Pro", windows: [("5H", 35, 9000, 18000, 4), ("7D", 8, 400000, 604800, 0.2)]),
        Row(id: "gemini", plan: "", windows: [("1D", 23, 40000, 86400, 1.4)]),
        Row(id: "copilot", plan: "Pro", windows: [("PREMIUM", 54, 1_200_000, 2_592_000, 0.1), ("CHAT", 12, 1_200_000, 2_592_000, 0)]),
        Row(id: "grok", plan: "SuperGrok", windows: [("2H", 93, 1500, 7200, 9)]),
        Row(id: "grokbot", plan: "Pro", windows: [("7D", 23, 150000, 604800, 0.8)]),
    ]

    /// Made-up plans and list prices for the demo's hover cards and monthly total.
    static func accounts(now: Date = Date()) -> [String: AccountInfo] {
        func a(_ plan: String, _ price: Double, billIn days: Double) -> AccountInfo {
            var x = AccountInfo(source: "demo data")
            x.plan = plan; x.monthlyPrice = price; x.currency = "USD"; x.nextBill = now.addingTimeInterval(days * 86_400)
            return x
        }
        var claude = a("Max 5x", 100, billIn: 12)
        claude.credits = [CreditInfo(title: "Full reset", amount: "×1", expires: now.addingTimeInterval(9 * 86_400))]
        return ["claude": claude, "codex": a("Pro", 200, billIn: 20), "antigravity": a("Google AI Pro", 19.99, billIn: 4),
                "copilot": a("Pro", 10, billIn: 17), "grok": a("SuperGrok", 30, billIn: 8), "grokbot": a("Pro", 20, billIn: 25)]
    }

    /// Grok's cycle: 93 → 96 → 99 → reset (2) → 5 → …
    private static let grokCycle: [(used: Double, resetIn: Double)] = [(93, 1500), (96, 900), (99, 300), (2, 7150), (5, 6900)]

    func fetch(now: Date = Date()) -> (snapshots: [ProviderSnapshot], samples: [UsageSample]) {
        defer { tick += 1 }
        var snaps: [ProviderSnapshot] = []
        var samples: [UsageSample] = []
        for row in rows {
            var ws: [UsageWindow] = []
            for (label, used0, resetIn0, win, rate) in row.windows {
                var used = used0, resetIn = resetIn0
                if row.id == "grok" {
                    let g = Self.grokCycle[tick % Self.grokCycle.count]
                    used = g.used; resetIn = g.resetIn
                }
                let reset = now.addingTimeInterval(resetIn)
                ws.append(UsageWindow(label: label, usedPercent: used, resetsAt: reset, windowSeconds: win))
                // An hour of synthetic history at this window's burn rate.
                for k in stride(from: 60, through: 0, by: -5) {
                    let t = now.addingTimeInterval(-Double(k) * 60)
                    let u = max(0, used - rate * Double(k) / 60)
                    if row.id == "grok", used < 50, Double(k) > (7200 - resetIn) / 60 { continue }
                    samples.append(UsageSample(t: t.timeIntervalSince1970, p: row.id, w: label, u: u,
                                               r: reset.timeIntervalSince1970))
                }
            }
            snaps.append(ProviderSnapshot(info: .lookup(row.id), state: .ok(windows: ws, plan: row.plan), updatedAt: now))
        }
        return (snaps, samples)
    }
}
