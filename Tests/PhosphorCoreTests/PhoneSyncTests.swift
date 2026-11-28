import Foundation
import Testing
@testable import PhosphorCore

@Suite struct PhoneSyncTests {
    @Test func healthHasNoUsage() {
        var session = SyncSession(code: "482913", codeUntil: 100)
        let (status, body) = PhoneSyncProtocol.handle(method: "GET", path: "/v1/health", authorization: nil,
                                                      body: Data(), now: 1, session: &session,
                                                      snapshot: Data("secret-usage".utf8), issueToken: { "t" })
        #expect(status == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("phosphor"))
        #expect(!String(decoding: body, as: UTF8.self).contains("secret"))
    }

    @Test func badCodeIsRefusedAndGoodCodeWorksOnce() {
        var session = SyncSession(code: "482913", codeUntil: 100)
        let bad = PhoneSyncProtocol.handle(method: "POST", path: "/v1/pair", authorization: nil,
                                           body: Data(#"{"code":"000000"}"#.utf8), now: 10, session: &session,
                                           snapshot: Data(), issueToken: { "nope" })
        #expect(bad.status == 401)
        #expect(session.tokens.isEmpty)
        let ok = PhoneSyncProtocol.handle(method: "POST", path: "/v1/pair", authorization: nil,
                                          body: Data(#"{"code":"482913"}"#.utf8), now: 10, session: &session,
                                          snapshot: Data(#"{"rows":[]}"#.utf8), issueToken: { "phone-token" })
        #expect(ok.status == 200)
        #expect(String(decoding: ok.json, as: UTF8.self).contains("phone-token"))
        #expect(session.code.isEmpty)
        let again = PhoneSyncProtocol.handle(method: "POST", path: "/v1/pair", authorization: nil,
                                             body: Data(#"{"code":"482913"}"#.utf8), now: 11, session: &session,
                                             snapshot: Data(), issueToken: { "other" })
        #expect(again.status == 401)
        let snap = PhoneSyncProtocol.handle(method: "GET", path: "/v1/snapshot", authorization: "Bearer phone-token",
                                            body: Data(), now: 12, session: &session,
                                            snapshot: Data(#"{"hostName":"Demo"}"#.utf8), issueToken: { "x" })
        #expect(snap.status == 200)
        #expect(String(decoding: snap.json, as: UTF8.self).contains("Demo"))
        let denied = PhoneSyncProtocol.handle(method: "GET", path: "/v1/snapshot", authorization: nil,
                                              body: Data(), now: 12, session: &session,
                                              snapshot: Data(#"{"hostName":"Demo"}"#.utf8), issueToken: { "x" })
        #expect(denied.status == 401)
    }

    @Test func parserWaitsForTheBody() {
        let partial = Data("POST /v1/pair HTTP/1.1\r\nContent-Length: 16\r\n\r\n".utf8)
        if case .needMore = PhoneSyncProtocol.read(partial) {} else { Issue.record("should wait") }
        let full = Data("POST /v1/pair HTTP/1.1\r\nContent-Length: 16\r\n\r\n{\"code\":\"482913\"}".utf8)
        guard case .ready(let req) = PhoneSyncProtocol.read(full) else {
            Issue.record("should parse"); return
        }
        #expect(req.method == "POST")
        #expect(req.path == "/v1/pair")
        #expect(req.body.count == 16)
    }

    @Test func demoSnapshotFileDecodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/sync/sample-snapshot.json")
        let snap = try JSONDecoder().decode(PhoneSnapshot.self, from: Data(contentsOf: url))
        #expect(snap.hostName == "Demo")
        #expect(snap.rows[0].windows[0].usedPercent == 62)
    }
}
