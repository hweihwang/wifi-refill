import Foundation
import Testing
@testable import RefillCore

/// Tests that share FakeNetwork's recorded responses, so they run one at a time.
@Suite(.serialized) struct NetworkTests {
    let client = FakeNetwork.client()
    let allowedHosts: Set<String> = ["captive.apple.com", RuijieFixture.portal, "192.168.110.1"]

    func prepare(router: String = "192.168.110.1") async throws -> PortalSession {
        guard case .portal(let probe) = await client.probe() else { throw LoginError.unexpected("no login page") }
        let (driver, entry) = try #require(Drivers.recognize(probe))
        return try await driver.prepare(from: entry, router: router, client: client)
    }

    @Test func logsInThroughTheRecordedFlow() async throws {
        FakeNetwork.serve(RuijieFixture.routes())
        let session = try await prepare()
        #expect(session.profile == "ruijie:H1UC00TEST001")
        #expect(session.network == "Cafe Guest")
        #expect(session.minutes == 60)

        try await RuijieCloud.login(session, client: client)
        #expect(FakeNetwork.posted(to: "/api/auth/direct/") == ["phoneNumber": "", "sessionId": RuijieFixture.sessionId])
        #expect(FakeNetwork.visited.last == "192.168.110.1/wifidog/auth")
        #expect(!FakeNetwork.visited.contains { $0.hasSuffix("index.html") }, "the login page itself is never needed")
        #expect(FakeNetwork.hosts.isSubset(of: allowedHosts))
    }

    @Test func refusesALoginPageThatNamesAnotherRouter() async throws {
        FakeNetwork.serve(RuijieFixture.routes())
        await #expect(throws: LoginError.unexpected("The login page named a different router.")) {
            try await prepare(router: "192.168.1.1")
        }
        #expect(FakeNetwork.posted(to: "/api/auth/direct/") == nil)
    }

    @Test func neverSendsTheTokenAnywhereButTheRouter() async throws {
        FakeNetwork.serve(RuijieFixture.routes(direct: #"{"success":true,"result":{"logonUrl":"http://10.0.0.5/wifidog/auth?token=secret"}}"#))
        let session = try await prepare()
        await #expect(throws: LoginError.unexpected("The login page pointed somewhere other than the router.")) {
            try await RuijieCloud.login(session, client: client)
        }
        #expect(!FakeNetwork.hosts.contains("10.0.0.5"))
    }

    @Test func staysOnRuijiesPortalHosts() async throws {
        FakeNetwork.serve(RuijieFixture.routes(scriptTarget: "https://collector.example/steal?sessionId=x"))
        await #expect(throws: LoginError.self) { try await prepare() }
        #expect(!FakeNetwork.hosts.contains("collector.example"))
        #expect(FakeNetwork.hosts.isSubset(of: allowedHosts))
    }

    @Test func stopsAtGatewayTypesNobodyHasChecked() async throws {
        FakeNetwork.serve(RuijieFixture.routes(isEG: "2"))
        await #expect(throws: LoginError.unsupported("This Ruijie gateway type (2) isn't supported yet.")) { try await prepare() }
        #expect(FakeNetwork.posted(to: "/api/auth/direct/") == nil)
    }

    @Test func stopsWhenThePageHasNoOneClickLogin() async throws {
        FakeNetwork.serve(RuijieFixture.routes(settings: #"{"post_url":"https://www.google.com/","custom_html":{"login_options":["voucher"]}}"#))
        await #expect(throws: LoginError.unsupported("This login page has no One-click Login.")) { try await prepare() }
        #expect(FakeNetwork.posted(to: "/api/auth/direct/") == nil)
    }

    @Test func passesOnTheLoginPagesRefusal() async throws {
        FakeNetwork.serve(RuijieFixture.routes(direct: #"{"success":false,"timestamp":1793430692273,"message":"Session timed out","object":null}"#))
        let session = try await prepare()
        await #expect(throws: LoginError.refused("Session timed out")) { try await RuijieCloud.login(session, client: client) }
    }

    @Test func keepsTheSessionLengthSensible() async throws {
        FakeNetwork.serve(RuijieFixture.routes(settings: #"{"oneclick":{"oneclick_validity":"100000"}}"#))
        #expect(try await prepare().minutes == 24 * 60)
    }

    @Test func seesAppleSuccessPageAsOnline() async {
        FakeNetwork.serve(["captive.apple.com/hotspot-detect.html": .init(body: "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>")])
        #expect(await client.probe() == .online)
    }

    @Test func seesNoAnswerAsOffline() async {
        FakeNetwork.serve([:])
        #expect(await client.probe() == .offline)
    }

    @Test func leavesUnknownLoginPagesAlone() async throws {
        FakeNetwork.serve(["captive.apple.com/hotspot-detect.html": .init(status: 302, location: "http://login.hotel.example/portal?mac=02:00:00:00:00:01")])
        guard case .portal(let probe) = await client.probe() else { Issue.record("expected a login page"); return }
        #expect(Drivers.recognize(probe) == nil)
        #expect(FakeNetwork.hosts == ["captive.apple.com"], "the probe never follows a redirect")
    }

    @Test func refusesAddressesWithCredentials() async {
        FakeNetwork.serve([:])
        await #expect(throws: RequestError.refusedAddress) { try await client.get(URL(string: "https://user:pass@\(RuijieFixture.portal)/")!) }
    }
}

struct ScriptRedirectTests {
    let page = URL(string: "https://portal-as.ruijienetworks.com/auth/wifidogAuth/login/?a=1")!

    @Test func readsRelativeScriptRedirects() {
        let url = PortalClient.scriptRedirect(in: "<script>self.location.href='/api/auth/wifidog?stage=portal&x=1'</script>", from: page)
        #expect(url?.absoluteURL.absoluteString == "https://portal-as.ruijienetworks.com/api/auth/wifidog?stage=portal&x=1")
    }

    @Test func readsMetaRefresh() {
        let url = PortalClient.scriptRedirect(in: #"<meta http-equiv="refresh" content="0;url=https://login.example/p?a=1&amp;b=2">"#, from: page)
        #expect(url?.absoluteURL.absoluteString == "https://login.example/p?a=1&b=2")
    }

    @Test func ignoresPagesWithoutRedirects() {
        #expect(PortalClient.scriptRedirect(in: "<script>window.location.href=t.succUrl</script>", from: page) == nil)
    }
}
