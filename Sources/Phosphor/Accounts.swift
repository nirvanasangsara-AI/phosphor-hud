import Foundation
import PhosphorCore

// MARK: - Plan, price, next bill and reset/refill credits, read from each service

/// One reset or refill credit the service says you hold.
struct CreditInfo: Hashable {
    let title: String        // "Full reset", "Extra usage credit"
    let amount: String       // "×1", "$1.00 of $1.00 left"
    let expires: Date?
}

/// What Phosphor could read about a subscription. Every value comes from the service itself
/// (its API or the official app's own local cache). A value it couldn't read carries the reason
/// instead, and is never guessed or typed in.
struct AccountInfo {
    var plan: String?
    var planNote: String?
    var monthlyPrice: Double?
    var currency = "USD"
    var priceNote: String?
    var nextBill: Date?
    var billNote: String?
    var credits: [CreditInfo] = []
    var creditsNote: String?
    var source: String
    /// Fields filled from the service's own settings/billing screen (see ScreenReadings), and when.
    var fromScreen: Set<String> = []
    /// The plan came from a settings screen listed in "override"; rows show it as their badge.
    var planOverridden = false
    var screenSource: String?
    var screenCheckedAt: Date?
    /// Why the billing-screen reading can't be trusted any more (next bill passed, > 30 days old).
    var staleReasons: [Staleness.Reason] = []
    var staleText: String? { Staleness.summary(staleReasons) }

    init(source: String) { self.source = source }
}

/// Values read from each service's own settings/billing screen (by an assistant navigating
/// there, the way a person would), saved to ~/.config/phosphor/billing-screens.json:
///   { "claude": { "checkedAt": "2026-11-26T08:10:00+09:00", "source": "https://claude.ai/settings/billing",
///       "plan": "Max 20x", "monthlyPrice": 290000, "currency": "KRW", "nextBill": "2026-12-27",
///       "credits": [ { "title": "Full reset", "amount": "×1", "expires": "2026-12-11T07:00:00+09:00" } ] } }
/// They only fill what the API or local cache couldn't read; the hover card shows where each came
/// from and when it was checked.
enum ScreenReadings {
    static var file: URL { Paths.config.appendingPathComponent("billing-screens.json") }

    static func all() -> [String: [String: Any]] {
        (readJSONFile(file) as? [String: [String: Any]]) ?? [:]
    }

    /// ISO date-time, or a plain "2026-12-27" (local midnight).
    static func date(_ v: Any?) -> Date? {
        if let s = v as? String, s.count == 10 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: s)
        }
        return Fmt.date(v)
    }

    static func merge(_ a: inout AccountInfo, _ r: [String: Any]?) {
        guard let r, let checked = date(r["checkedAt"]) else { return }
        var used = false
        // A field named in "override" replaces what the service's cache said (e.g. the plan
        // name a settings screen shows when the local cache still has an older label).
        let override = Set(r["override"] as? [String] ?? [])
        if a.plan == nil || override.contains("plan"), let plan = r["plan"] as? String, !plan.isEmpty {
            a.plan = plan; a.fromScreen.insert("plan"); used = true
            if override.contains("plan") { a.planOverridden = true }
        }
        if a.monthlyPrice == nil || override.contains("monthlyPrice"), let price = num(r["monthlyPrice"]) {
            a.monthlyPrice = price
            a.currency = (r["currency"] as? String ?? a.currency).uppercased()
            a.fromScreen.insert("price"); used = true
        }
        if a.nextBill == nil || override.contains("nextBill"), let bill = date(r["nextBill"]) {
            a.nextBill = bill; a.fromScreen.insert("bill"); used = true
        }
        let have = Set(a.credits.map(\.title))
        for c in r["credits"] as? [[String: Any]] ?? [] {
            guard let title = c["title"] as? String, !have.contains(title) else { continue }
            if let exp = date(c["expires"]), exp < Date() { continue }
            a.credits.append(CreditInfo(title: title, amount: c["amount"] as? String ?? "", expires: date(c["expires"])))
            a.fromScreen.insert("credits"); used = true
        }
        if used {
            a.screenSource = r["source"] as? String
            a.screenCheckedAt = checked
            // Only a date that came from the screen can go stale; one the service reports is live.
            a.staleReasons = Staleness.reasons(nextBill: a.fromScreen.contains("bill") ? a.nextBill : nil, checkedAt: checked)
        }
    }
}

enum Accounts {
    static func fetch(_ id: String, claude: ClaudeSource) async -> AccountInfo? {
        guard var a = await fetchService(id, claude: claude) else { return nil }
        ScreenReadings.merge(&a, ScreenReadings.all()[id])
        return a
    }

    static func fetchService(_ id: String, claude: ClaudeSource) async -> AccountInfo? {
        switch id {
        case "claude": return await claudeInfo(claude)
        case "codex": return await codexInfo()
        case "grok": return grokInfo()
        case "grokbot": return grokBotInfo()
        case "copilot": return await copilotInfo()
        case "antigravity": return antigravityInfo()
        case "muse": return await museInfo()
        default:
            // Catalog providers and extra accounts: the service gives Phosphor nothing about the
            // subscription, so anything shown comes from billing-screens.json under this id.
            let base = String(id.split(separator: "@").first ?? Substring(id))
            guard let spec = ProviderCatalog.spec(base),
                  spec.sources.contains(.billingScreen) || ScreenReadings.all()[id] != nil else { return nil }
            var a = AccountInfo(source: id.contains("@") ? "extra account (accounts.json)" : "\(spec.name): no account API")
            let hint = spec.billingURL.map { " · read it from \($0) into billing-screens.json" } ?? ""
            a.planNote = "Not reported" + hint
            a.priceNote = "Not reported"
            a.billNote = "Not reported"
            a.creditsNote = nil
            return a
        }
    }

    // MARK: Claude Code — Claude Code's own config cache (~/.claude.json, no secrets in it)

    static func claudeInfo(_ claude: ClaudeSource) async -> AccountInfo {
        var a = AccountInfo(source: "Claude Code's account cache (~/.claude.json)")
        let cfg = readJSONFile(Paths.home.appendingPathComponent(".claude.json")) ?? [:]
        let acct = cfg["oauthAccount"] as? [String: Any] ?? [:]
        if let type = acct["organizationType"] as? String {
            var plan = type.replacingOccurrences(of: "claude_", with: "").capitalized
            if let tier = acct["organizationRateLimitTier"] as? String,
               let m = tier.range(of: #"(\d+)x$"#, options: .regularExpression) {
                plan += " " + tier[m]
            }
            a.plan = plan
        } else {
            a.planNote = "Claude Code hasn't cached the plan"
        }
        let billing = acct["billingType"] as? String
        let viaApple = billing == "apple_subscription"
        a.priceNote = viaApple ? "Billed by Apple; Claude doesn't report the price"
                               : "Claude doesn't report the price to Claude Code"
        a.billNote = viaApple ? "Billed by Apple; Claude doesn't report the date"
                              : "Claude doesn't report the billing date to Claude Code"
        var notes: [String] = []
        if (acct["hasExtraUsageEnabled"] as? Bool) == false { notes.append("Extra usage is off") }
        if let passes = (cfg["passesEligibilityCache"] as? [String: Any])?.values
            .compactMap({ $0 as? [String: Any] }).first,
           let left = num(passes["remaining_passes"]), left > 0 {
            a.credits.append(CreditInfo(title: "Guest passes", amount: "×\(Int(left))", expires: nil))
        }
        if Prefs.shared.claudeResetCredits {
            do { a.credits += try await claude.resetCredits() }
            catch { notes.append("Reset credits: couldn't read (\(error.localizedDescription))") }
        } else {
            notes.append("Reset credits: off. Claude Code doesn't expose them; reading them uses your Claude login outside Claude Code (Providers menu)")
        }
        a.creditsNote = notes.isEmpty ? nil : notes.joined(separator: " · ")
        return a
    }

    // MARK: Codex — the ChatGPT account endpoints Codex's login already reaches

    static func codexInfo() async -> AccountInfo {
        var a = AccountInfo(source: "ChatGPT account (Codex login)")
        let home = Paths.home.appendingPathComponent(".codex")
        let creds: AuthRefresh.Access
        do { creds = try await AuthRefresh.shared.codexAccess(home: home) }
        catch {
            a.planNote = "Codex not logged in with ChatGPT"
            return a
        }
        let account = creds.accountID
        func get(_ path: String) async throws -> [String: Any] {
            func request(_ access: AuthRefresh.Access) -> URLRequest {
                var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/" + path)!)
                req.setValue("Bearer \(access.token)", forHTTPHeaderField: "Authorization")
                if let account = access.accountID { req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
                req.setValue("phosphor-hud/0.2", forHTTPHeaderField: "User-Agent")
                return req
            }
            do { return try await HTTP.json(request(creds)) }
            catch ProviderError.expired {
                let fresh = try await AuthRefresh.shared.codexAccess(home: home, force: true)
                return try await HTTP.json(request(fresh))
            }
        }
        var planKey: String?
        do {
            let sub = try await get("subscriptions?account_id=\(account ?? "")")
            let ent = sub["entitlement"] as? [String: Any] ?? [:]
            let planType = sub["plan_type"] as? String
            let subPlan = ent["subscription_plan"] as? String
            planKey = subPlan.map { $0.hasPrefix("chatgpt") ? String($0.dropFirst(7)) : $0 } ?? planType
            a.plan = planType.map { "ChatGPT \($0.capitalized)" } ?? subPlan
            a.currency = (ent["billing_currency"] as? String ?? sub["billing_currency"] as? String ?? "USD").uppercased()
            let willRenew = (sub["will_renew"] as? Bool) ?? true
            if let cancels = Fmt.date(ent["cancels_at"]) {
                a.billNote = "Cancels \(Fmt.shortDate(cancels)); no next bill"
            } else if willRenew, let renews = Fmt.date(ent["renews_at"]) ?? Fmt.date(sub["active_until"]) {
                a.nextBill = renews
            } else {
                a.billNote = "Not set to renew"
            }
            let period = (ent["billing_period"] as? String) ?? (sub["billing_period"] as? String)
            let discounted = ent["discount"] is [String: Any] || !((ent["applied_discounts"] as? [Any]) ?? []).isEmpty
            if (ent["is_active_subscription_gratis"] as? Bool) == true {
                a.monthlyPrice = 0
            } else if let key = planKey {
                let prices = try await get("checkout_pricing_config/configs/\(a.currency)")
                let cfg = (prices["currency_config"] as? [String: Any])?[key] as? [String: Any]
                if period == "monthly", let m = cfg?["month"] as? [String: Any], let amt = num(m["amount"]) {
                    if discounted { a.priceNote = "A discount applies; ChatGPT doesn't report the discounted price" }
                    else { a.monthlyPrice = amt }
                } else {
                    a.priceNote = "ChatGPT lists no monthly price for this plan (\(period ?? "unknown period"))"
                }
            }
        } catch {
            a.planNote = a.planNote ?? "Couldn't read the subscription (\(error.localizedDescription))"
            a.priceNote = a.priceNote ?? "Couldn't read"
            a.billNote = a.billNote ?? "Couldn't read"
        }
        do {
            let r = try await get("wham/rate-limit-reset-credits")
            for c in r["credits"] as? [[String: Any]] ?? [] where (c["status"] as? String) == "available" {
                a.credits.append(CreditInfo(title: c["title"] as? String ?? "Reset", amount: "×1",
                                            expires: Fmt.date(c["expires_at"])))
            }
            if a.credits.isEmpty { a.creditsNote = "No reset credits" }
        } catch {
            a.creditsNote = "Reset credits: couldn't read (\(error.localizedDescription))"
        }
        if let usage = try? await get("wham/usage"),
           let credits = usage["credits"] as? [String: Any], (credits["has_credits"] as? Bool) == true,
           let bal = num(credits["balance"]), bal > 0 {
            a.credits.append(CreditInfo(title: "Usage credits", amount: "\(Fmt.compact(bal)) left", expires: nil))
        }
        return a
    }

    // MARK: Grok CLI

    static func grokInfo() -> AccountInfo {
        var a = AccountInfo(source: "Grok CLI billing")
        a.planNote = "Shown on the row when the Grok CLI login is valid"
        a.priceNote = "Grok CLI doesn't report the price"
        a.billNote = "Grok CLI doesn't report the billing date"
        a.creditsNote = "Grok CLI doesn't report reset credits"
        return a
    }

    // MARK: Grok Bot — the app's own usage cache

    static func grokBotInfo() -> AccountInfo {
        var a = AccountInfo(source: "Grok Bot app's usage cache")
        guard let file = GrokBotSource.usageFile(), let obj = readJSONFile(file),
              let usage = ((obj["value"] as? [String: Any])?["reading"] as? [String: Any])?["usage"] as? [String: Any] else {
            a.planNote = "Open Grok Bot once to load it"
            return a
        }
        a.plan = (usage["grokPlanLabel"] as? String) ?? "Grok Bot"
        if (usage["isSandTrial"] as? Bool) == true { a.plan! += " (trial)" }
        a.priceNote = "The Grok Bot app doesn't keep the price on this Mac"
        a.billNote = "The Grok Bot app doesn't keep the billing date on this Mac"
        if let od = usage["onDemand"] as? [String: Any], let limit = num(od["limitCents"]), limit > 0 {
            let used = num(od["usedCents"]) ?? 0
            a.credits.append(CreditInfo(title: "Extra usage credit",
                                        amount: "\(Fmt.amount(max(0, limit - used) / 100, "USD")) of \(Fmt.amount(limit / 100, "USD")) left",
                                        expires: nil))
        } else {
            a.creditsNote = "No extra credit"
        }
        return a
    }

    // MARK: Copilot — copilot_internal/user (the GitHub CLI login)

    static func copilotInfo() async -> AccountInfo {
        var a = AccountInfo(source: "GitHub Copilot account")
        guard let gh = Shell.which("gh"),
              let token = try? await Shell.run(gh, ["auth", "token"], timeout: 10)
                  .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            a.planNote = "GitHub CLI not logged in"
            return a
        }
        var req = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("phosphor-hud", forHTTPHeaderField: "User-Agent")
        guard let obj = try? await HTTP.json(req) else { a.planNote = "Couldn't read"; return a }
        let sku = obj["access_type_sku"] as? String ?? ""
        let free = sku.hasPrefix("free")
        a.plan = free ? "Copilot Free" : (sku.isEmpty ? (obj["copilot_plan"] as? String)?.capitalized : sku)
        if free {
            a.monthlyPrice = 0
            a.billNote = "Free plan, no bill"
        } else {
            a.priceNote = "GitHub doesn't report the price here"
            a.billNote = "GitHub doesn't report the billing date here"
        }
        if let premium = (obj["quota_snapshots"] as? [String: Any])?["premium_interactions"] as? [String: Any],
           let ent = num(premium["entitlement"]), ent > 0 {
            let left = num(premium["remaining"]) ?? 0
            a.credits.append(CreditInfo(title: "Premium requests", amount: "\(Int(left)) of \(Int(ent)) left",
                                        expires: Fmt.date(obj["quota_reset_date_utc"])))
        } else {
            a.creditsNote = "No premium requests on this plan"
        }
        return a
    }

    // MARK: Antigravity / Muse

    static func antigravityInfo() -> AccountInfo {
        var a = AccountInfo(source: "agy /usage")
        a.planNote = "agy reports limits only, not the plan"
        a.priceNote = "Not reported by agy"
        a.billNote = "Not reported by agy"
        a.creditsNote = "Not reported by agy. agy /usage is Antigravity's own quota only: Gemini app (web) chat, "
            + "image and Veo quotas, Google AI credits (Flow/Whisk), Gemini CLI and the AI Studio API are tracked "
            + "separately (Providers → More Providers)"
        return a
    }

    static func museInfo() async -> AccountInfo {
        var a = AccountInfo(source: "muse usage --json")
        guard let bin = Shell.which("muse"),
              let raw = try? await Shell.run(bin, ["usage", "--json"], timeout: 25),
              let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
            a.planNote = "Muse CLI not available"
            return a
        }
        if let allowance = obj["allowance"] as? [String: Any] {
            a.plan = allowance["tier"] as? String
            a.priceNote = "Muse doesn't report the price"
            a.billNote = "Muse doesn't report the billing date"
        } else {
            a.plan = "No subscription"
            a.priceNote = "No subscription"
            a.billNote = "No subscription"
        }
        a.creditsNote = "Muse doesn't report reset credits"
        return a
    }
}

extension Fmt {
    /// "$200", "$19.99", "₩290,000": whole amounts without decimals, other currencies by code.
    static func money(_ v: Double, _ currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.locale = Locale(identifier: currency == "KRW" ? "ko_KR" : "en_US")
        f.maximumFractionDigits = v.rounded() == v ? 0 : 2
        f.minimumFractionDigits = f.maximumFractionDigits
        return f.string(from: NSNumber(value: v)) ?? "\(v) \(currency)"
    }

    static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm"
        return f.string(from: d)
    }
}
