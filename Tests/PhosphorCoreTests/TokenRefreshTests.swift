import Foundation
import Testing
@testable import PhosphorCore

@Suite struct TokenRefreshTests {
    @Test func jwtExpiryReadsExpClaim() {
        let jwt = fakeJWT(exp: 1_700_000_000)
        #expect(TokenRefresh.jwtExpiry(jwt) == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(TokenRefresh.jwtExpiry("not-a-jwt") == nil)
        #expect(TokenRefresh.jwtExpiry("aaa") == nil)
    }

    @Test func needsRefreshUsesLeewayAndIgnoresMissingExpiry() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(TokenRefresh.needsRefresh(expiry: nil, now: now) == false)
        #expect(TokenRefresh.needsRefresh(expiry: now.addingTimeInterval(600), now: now) == false)
        #expect(TokenRefresh.needsRefresh(expiry: now.addingTimeInterval(300), now: now) == true)
        #expect(TokenRefresh.needsRefresh(expiry: now.addingTimeInterval(-1), now: now) == true)
        #expect(TokenRefresh.needsRefresh(expiry: now.addingTimeInterval(301), now: now, leeway: 60) == false)
    }

    @Test func classifyRevokedTokensAsPermanentAndServerErrorsAsTransient() {
        #expect(TokenRefresh.classify(status: 200) == .success)
        #expect(TokenRefresh.classify(status: 201, body: "{}") == .success)
        #expect(TokenRefresh.classify(status: 401, body: #"{"error":"invalid_grant"}"#) == .permanent)
        #expect(TokenRefresh.classify(status: 403) == .permanent)
        #expect(TokenRefresh.classify(status: 400, body: "refresh_token_expired") == .permanent)
        #expect(TokenRefresh.classify(status: 400, body: "refresh_token_reused") == .permanent)
        #expect(TokenRefresh.classify(status: 400, body: "REFRESH_TOKEN_INVALIDATED") == .permanent)
        #expect(TokenRefresh.classify(status: 400, body: "invalid_grant") == .permanent)
        #expect(TokenRefresh.classify(status: 400, body: "invalid_request") == .transient)
        #expect(TokenRefresh.classify(status: 429) == .transient)
        #expect(TokenRefresh.classify(status: 500) == .transient)
        #expect(TokenRefresh.classify(status: 0, body: "network down") == .transient)
    }

    @Test func cooldownStartsImmediatelyThenBacksOffAndHoldsRevokedTokens() {
        #expect(TokenRefresh.Cooldown.delay(after: 0) == 0)
        #expect(TokenRefresh.Cooldown.delay(after: 1) == 60)
        #expect(TokenRefresh.Cooldown.delay(after: 2) == 300)
        #expect(TokenRefresh.Cooldown.delay(after: 3) == 900)
        #expect(TokenRefresh.Cooldown.delay(after: 4) == 3600)
        #expect(TokenRefresh.Cooldown.delay(after: 99) == 3600)

        var c = TokenRefresh.Cooldown()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(c.canAttempt(at: t0))

        c.recordTransient(at: t0)
        #expect(c.canAttempt(at: t0.addingTimeInterval(59)) == false)
        #expect(c.canAttempt(at: t0.addingTimeInterval(60)))

        c.recordPermanent(at: t0.addingTimeInterval(60), hold: 6 * 3600)
        #expect(c.canAttempt(at: t0.addingTimeInterval(60 + 3600)) == false)
        #expect(c.canAttempt(at: t0.addingTimeInterval(60 + 6 * 3600)))

        c.recordSuccess(at: t0.addingTimeInterval(7 * 3600))
        #expect(c.consecutiveFailures == 0)
        #expect(c.permanentUntil == nil)
        #expect(c.canAttempt(at: t0.addingTimeInterval(7 * 3600)))
    }

    @Test func applyingCodexRefreshKeepsUnknownFieldsAndSkipsEmptyRefresh() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let auth: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": "old-access",
                "refresh_token": "keep-me",
                "account_id": "acct-1",
                "extra_token_field": "stay",
            ],
            "last_refresh": "old",
            "custom_top": true,
        ]
        let updated = TokenRefresh.applyingCodexRefresh(auth, response: [
            "access_token": "new-access",
            "id_token": "new-id",
            "refresh_token": "",
            "expires_in": 3600,
        ], at: now)
        let tokens = updated?["tokens"] as? [String: Any]
        #expect(tokens?["access_token"] as? String == "new-access")
        #expect(tokens?["id_token"] as? String == "new-id")
        #expect(tokens?["refresh_token"] as? String == "keep-me")
        #expect(tokens?["account_id"] as? String == "acct-1")
        #expect(tokens?["extra_token_field"] as? String == "stay")
        #expect(updated?["auth_mode"] as? String == "chatgpt")
        #expect(updated?["custom_top"] as? Bool == true)
        #expect(updated?["last_refresh"] as? String == TokenRefresh.iso(now))
        #expect(TokenRefresh.applyingCodexRefresh(auth, response: ["token_type": "Bearer"]) == nil)
    }

    @Test func applyingGrokRefreshUpdatesKeyAndExpiryWithoutDroppingFields() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = "https://auth.x.ai::example-client-id"
        let auth: [String: Any] = [
            key: [
                "key": "old-key",
                "refresh_token": "keep-rt",
                "expires_at": "2020-01-01T00:00:00Z",
                "oidc_client_id": "example-client-id",
                "note": "preserve-me",
            ],
            "other": ["key": "untouched"],
        ]
        let updated = TokenRefresh.applyingGrokRefresh(auth, entryKey: key, response: [
            "access_token": "new-key",
            "expires_in": 120,
        ], at: now)
        let entry = updated?[key] as? [String: Any]
        #expect(entry?["key"] as? String == "new-key")
        #expect(entry?["refresh_token"] as? String == "keep-rt")
        #expect(entry?["note"] as? String == "preserve-me")
        #expect(entry?["oidc_client_id"] as? String == "example-client-id")
        #expect((updated?["other"] as? [String: Any])?["key"] as? String == "untouched")
        let exp = TokenRefresh.parseISO(entry?["expires_at"] as? String ?? "")
        #expect(exp == now.addingTimeInterval(120))

        let rotated = TokenRefresh.applyingGrokRefresh(auth, entryKey: key, response: [
            "access_token": "newer",
            "refresh_token": "new-rt",
            "expires_in": 60,
        ], at: now)
        #expect((rotated?[key] as? [String: Any])?["refresh_token"] as? String == "new-rt")
        #expect(TokenRefresh.applyingGrokRefresh(auth, entryKey: "missing", response: ["access_token": "x"]) == nil)
    }

    @Test func grokClientIDComesFromEntryOrIssuerMapKey() {
        #expect(TokenRefresh.grokClientID(entryKey: "plain", entry: ["oidc_client_id": "from-field"]) == "from-field")
        #expect(TokenRefresh.grokClientID(entryKey: "https://auth.x.ai::from-map", entry: [:]) == "from-map")
        #expect(TokenRefresh.grokClientID(entryKey: "plain", entry: [:]) == nil)
        #expect(TokenRefresh.grokClientID(entryKey: "https://auth.x.ai::", entry: [:]) == nil)
        let auth: [String: Any] = ["https://auth.x.ai::example-client-id": ["key": "tok"]]
        #expect(TokenRefresh.grokEntry(in: auth)?.key == "https://auth.x.ai::example-client-id")
    }

    @Test func parseISOHandlesFractionalAndPlainInstants() {
        #expect(TokenRefresh.parseISO("2026-11-27T01:48:33Z") != nil)
        #expect(TokenRefresh.parseISO("2026-11-27T01:48:33.376413+00:00") != nil)
        #expect(TokenRefresh.parseISO("2026-11-27T01:48:33+00:00") != nil)
        #expect(TokenRefresh.parseISO("not-a-date") == nil)
        let grok = TokenRefresh.grokExpiry(["expires_at": "2026-11-27T01:48:33.376413+00:00"])
        #expect(grok != nil)
    }

    @Test func officialEndpointsAndPublicCodexClientStayStable() {
        #expect(TokenRefresh.codexURL.absoluteString == "https://auth.openai.com/oauth/token")
        #expect(TokenRefresh.grokURL.absoluteString == "https://auth.x.ai/oauth2/token")
        #expect(TokenRefresh.codexClientID == "app_EMoamEEZ73f0CkXaXp7hrann")
    }
}

private func fakeJWT(exp: Int) -> String {
    func b64(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
    return "\(b64(["alg": "none", "typ": "JWT"])).\(b64(["exp": exp])).sig"
}
