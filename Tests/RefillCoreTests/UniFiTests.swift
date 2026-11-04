import Foundation
import Testing
@testable import RefillCore

/// UniFi guest portals. In NetworkTests, so these share FakeNetwork one test at a time.
extension NetworkTests {
    @Test func uniFiLogsInThroughTheRecordedFlow() async throws {
        FakeNetwork.serve(UniFiFixture.routes())
        let session = try await prepare(on: UniFiFixture.network)
        #expect(session.profile == "unifi:192.168.1.2/guest/s/default/")
        #expect(session.network == "Cafe Guest")
        #expect(session.details["local"] == "yes")

        try await UniFiGuestPortal.login(session, client: client)
        #expect(FakeNetwork.visited == [
            "captive.apple.com/hotspot-detect.html", "192.168.1.2/guest/s/default/",
            "192.168.1.2/guest/s/default/hotspotconfig", "192.168.1.2/guest/s/default/login",
        ])
        #expect(FakeNetwork.body(postedTo: "/guest/s/default/login") == Data(), "the portal's button posts nothing")
        #expect(FakeNetwork.hosts == ["captive.apple.com", "192.168.1.2"])
    }

    @Test func uniFiReachesAControllerOnTheInternet() async throws {
        let entry = UniFiFixture.entry.replacingOccurrences(of: "192.168.1.2", with: "unifi.example.net")
        FakeNetwork.serve(UniFiFixture.routes(entry: entry, host: "unifi.example.net"))
        let session = try await prepare(on: UniFiFixture.network)
        #expect(session.details["local"] == "no")
        try await UniFiGuestPortal.login(session, client: client)
        #expect(FakeNetwork.hosts == ["captive.apple.com", "unifi.example.net"])
    }

    @Test(arguments: ["password", "voucher", "radius", "custom", "facebook"])
    func uniFiLeavesOtherWaysToTeaching(auth: String) async throws {
        FakeNetwork.serve(UniFiFixture.routes(config: UniFiFixture.config.replacingOccurrences(of: #""auth":"none""#, with: #""auth":"\#(auth)""#)))
        await #expect(throws: LoginError.unsupported("This login page asks for a password or a voucher.")) { try await prepare(on: UniFiFixture.network) }
        #expect(!FakeNetwork.visited.contains("192.168.1.2/guest/s/default/login"))
    }

    @Test func uniFiReportsARefusal() async throws {
        FakeNetwork.serve(UniFiFixture.routes(answer: UniFiFixture.refused))
        let session = try await prepare(on: UniFiFixture.network)
        await #expect(throws: LoginError.refused("The login page refused the login.")) { try await UniFiGuestPortal.login(session, client: client) }
    }

    @Test func uniFiStopsWhenTheSettingsDoNotRead() async throws {
        FakeNetwork.serve(UniFiFixture.routes(config: "<html>Not Found</html>"))
        await #expect(throws: LoginError.unexpected("Couldn't read the login page's settings.")) { try await prepare(on: UniFiFixture.network) }
    }

    @Test(arguments: [
        "http://192.168.1.2:8880/guest/s/default/?ap=02:00:00:00:00:02&t=1762300000",
        "http://192.168.1.2:8880/guest/default/?id=02:00:00:00:00:01",
        "http://192.168.1.2:8880/guest/s/default/../../login?id=02:00:00:00:00:01",
        "http://user@192.168.1.2:8880/guest/s/default/?id=02:00:00:00:00:01",
    ])
    func uniFiRecognisesOnlyAGuestPortalVisit(entry: String) async throws {
        FakeNetwork.serve(UniFiFixture.routes(entry: entry))
        guard case .portal(let probe) = await client.probe() else { Issue.record("expected a login page"); return }
        #expect(Drivers.recognize(probe) == nil)
    }
}
