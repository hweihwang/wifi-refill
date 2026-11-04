import Foundation
import Testing
@testable import RefillCore

/// MikroTik HotSpot. In NetworkTests, so these share FakeNetwork one test at a time.
extension NetworkTests {
    @Test func mikroTikOpensTheFreeTrial() async throws {
        FakeNetwork.serve(MikroTikFixture.routes())
        let session = try await prepare(on: MikroTikFixture.network)
        #expect(session.profile == "mikrotik:10.5.50.1")
        #expect(session.network == "Wi-Fi")
        #expect(session.details["trial"] == "http://10.5.50.1/login?\(MikroTikFixture.trialQuery)")

        try await MikroTikHotspot.login(session, client: client)
        #expect(FakeNetwork.visited == ["captive.apple.com/hotspot-detect.html", "10.5.50.1/login", "10.5.50.1/login"])
        #expect(FakeNetwork.hosts == ["captive.apple.com", "10.5.50.1"])
    }

    @Test func mikroTikTellsCafesApartByTheirRouter() async throws {
        FakeNetwork.serve(MikroTikFixture.routes())
        var network = MikroTikFixture.network
        network.signature = "10.5.50.1/02:00:00:00:00:09"
        #expect(try await prepare(on: network).profile == "mikrotik:10.5.50.1/02:00:00:00:00:09")
    }

    @Test(arguments: ["10.5.51.1", "192.168.88.1", "203.0.113.9"])
    func mikroTikOnlyTalksToItsOwnNetwork(host: String) async throws {
        FakeNetwork.serve(MikroTikFixture.routes(login: "http://\(host)/login?\(MikroTikFixture.dst)"))
        await #expect(throws: LoginError.unsupported("This login page isn't supported yet.")) { try await prepare(on: MikroTikFixture.network) }
        #expect(FakeNetwork.hosts == ["captive.apple.com"])
    }

    @Test(arguments: [
        "http://203.0.113.9/login?\(MikroTikFixture.dst)&amp;username=T-02%3A00%3A00%3A00%3A00%3A01",
        "http://10.5.50.1:8080/login?\(MikroTikFixture.dst)&amp;username=T-02%3A00%3A00%3A00%3A00%3A01",
        "http://10.5.50.1/status?\(MikroTikFixture.dst)&amp;username=T-02%3A00%3A00%3A00%3A00%3A01",
        "http://10.5.50.1/login?\(MikroTikFixture.dst)&amp;username=admin&amp;note=username=T-",
    ])
    func mikroTikFollowsOnlyATrialLinkToItsOwnLogin(trial: String) async throws {
        FakeNetwork.serve(MikroTikFixture.routes(page: MikroTikFixture.page(trial: trial)))
        await #expect(throws: LoginError.unsupported("This login page asks for a user name and password.")) { try await prepare(on: MikroTikFixture.network) }
    }

    @Test func mikroTikLeavesPasswordPagesToTeaching() async throws {
        FakeNetwork.serve(MikroTikFixture.routes(page: MikroTikFixture.page(trial: nil)))
        await #expect(throws: LoginError.unsupported("This login page asks for a user name and password.")) { try await prepare(on: MikroTikFixture.network) }
    }

    @Test func mikroTikReportsARefusedTrial() async throws {
        FakeNetwork.serve(MikroTikFixture.routes(answer: .init(body: MikroTikFixture.refused)))
        let session = try await prepare(on: MikroTikFixture.network)
        await #expect(throws: LoginError.refused("The login page refused the login.")) { try await MikroTikHotspot.login(session, client: client) }
    }

    @Test(arguments: [
        "http://10.5.50.1/login",
        "http://10.5.50.1/hotspot/login?\(MikroTikFixture.dst)",
        "ftp://10.5.50.1/login?\(MikroTikFixture.dst)",
    ])
    func mikroTikRecognisesOnlyALoginWithItsDestination(login: String) async throws {
        FakeNetwork.serve(MikroTikFixture.routes(login: login))
        guard case .portal(let probe) = await client.probe() else { Issue.record("expected a login page"); return }
        #expect(Drivers.recognize(probe) == nil)
    }
}
