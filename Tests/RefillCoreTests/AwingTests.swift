import Foundation
import Testing
@testable import RefillCore

/// Awing on Extreme Networks. In NetworkTests, so these share FakeNetwork one test at a time.
extension NetworkTests {
    var awingHosts: Set<String> { ["captive.apple.com", AwingFixture.page, AwingFixture.controller] }

    func awingSession() async throws -> PortalSession {
        try await prepare(on: AwingFixture.network)
    }

    @Test func awingLogsInThroughTheRecordedFlow() async throws {
        FakeNetwork.serve(AwingFixture.routes())
        let session = try await awingSession()
        #expect(session.profile == "awing:10001")
        #expect(session.network == "Highlands Coffee")
        #expect(session.minutes == nil)

        try await AwingExtreme.login(session, client: client)
        let form = FakeNetwork.body(postedTo: "/cgi-bin/hslogin.cgi").map { String(decoding: $0, as: UTF8.self) }
        let qv = "it_qpmjdz%3DDbqujwf.ID%40bbb_qpmjdz%3D%40dmjfou_njou%3D211111112%40dmjfou_nbd%3D13.11.11.11.11.12%40ttje%3DIjhimboet%21Dpggff%40bq_nbd%3D13.11.11.11.11.13"
        #expect(form == "f_flex=&f_flex_type=log&f_hs_server=10.29.64.2&f_Qv=\(qv)", "the form exactly as Safari posts it")
        #expect(FakeNetwork.visited == ["captive.apple.com/hotspot-detect.html", "v1.awingconnect.vn/Home/VerifyUrl", "10.29.64.2/cgi-bin/hslogin.cgi"])
        #expect(FakeNetwork.hosts.isSubset(of: awingHosts))
    }

    @Test(arguments: ["10.29.68.2", "192.168.1.2", "203.0.113.9", "collector.example", "10.29.64.2.collector.example"])
    func awingSendsTheFormOnlyToTheMacsOwnNetwork(server: String) async throws {
        FakeNetwork.serve(AwingFixture.routes(login: AwingFixture.login.replacingOccurrences(of: "hs_server=10.29.64.2", with: "hs_server=\(server)")))
        await #expect(throws: LoginError.unexpected("The login page pointed somewhere other than the router.")) { try await awingSession() }
        #expect(FakeNetwork.hosts == ["captive.apple.com"])
    }

    @Test(arguments: [
        "http://v1.awingconnect.vn.collector.example/login?hs_server=10.29.64.2&Qv=x",
        "http://v1.awingconnect.vn:8080/login?hs_server=10.29.64.2&Qv=x",
        "http://v1.awingconnect.vn/login?client_mac=02-00-00-00-00-01&ap_mac=02-00-00-00-00-02",
        "http://v1.awingconnect.vn/preview/page?hs_server=10.29.64.2&Qv=x",
    ])
    func awingRecognisesOnlyItsOwnLoginAddress(login: String) async throws {
        FakeNetwork.serve(AwingFixture.routes(login: login))
        guard case .portal(let probe) = await client.probe() else { Issue.record("expected a login page"); return }
        #expect(Drivers.recognize(probe) == nil)
    }

    @Test(arguments: [
        ("</form>", #"<input name="f_pass" type="password"></form>"#),
        ("</form>", #"<textarea name="phone"></textarea></form>"#),
        (#"name="f_Qv" id="f_Qv" type="hidden""#, #"name="f_Qv" id="f_Qv" type="password""#),
        (#"method="POST""#, #"method="GET""#),
        (#"action="/cgi-bin/hslogin.cgi""#, #"action="/cgi-bin/ext_approval.cgi"><!-- action="/cgi-bin/hslogin.cgi" -->"#),
        ("var port = 880;", "var port = 8080; // var port = 880;"),
        ("<script>", #"<form id="other"></form><script>"#),
        (#"method="POST""#, #"_method="POST""#),
        ("var port = 880;", "/*\nvar port = 880;\n*/\nvar port = 8080;"),
        ("var port = 880;", "var port = 880;\nport = 8080;"),
        ("<form", String(repeating: "<form ", count: 10_000) + "<form"),
        ("return pair[1];", "return\npair[1];"),
        ("// set params from URL to form\n", "// set params from URL to form "),
    ])
    func awingStopsWhenTheFormChanges(change: (String, String)) async throws {
        let verify = AwingFixture.verify(changing: {
            let form = $0["contentAuthenForm"] as! String
            #expect(form.contains(change.0))
            $0["contentAuthenForm"] = form.replacingOccurrences(of: change.0, with: change.1)
        })
        FakeNetwork.serve(AwingFixture.routes(verify: verify))
        await #expect(throws: LoginError.unsupported("This login page isn't supported yet.")) { try await awingSession() }
        #expect(!FakeNetwork.hosts.contains(AwingFixture.controller))
    }

    @Test func awingStopsWhenThePageAsksForDetails() async throws {
        let fields = AwingFixture.verify(changing: { $0["customerRequiredFields"] = [1] })
        let workspace = AwingFixture.verify(changing: {
            var workspace = $0["workspace"] as! [String: Any]
            workspace["requiredCustomerData"] = ["phone"]
            $0["workspace"] = workspace
        })
        for verify in [fields, workspace] {
            FakeNetwork.serve(AwingFixture.routes(verify: verify))
            await #expect(throws: LoginError.unsupported("This login page asks for your details.")) { try await awingSession() }
        }
    }

    @Test func awingRetriesWhenThePageDoesNotAnswer() async throws {
        for routes in [AwingFixture.routes(verify: nil), AwingFixture.routes(verifyStatus: 500), AwingFixture.routes(verify: "<html>busy</html>")] {
            FakeNetwork.serve(routes)
            await #expect(throws: LoginError.unexpected("Couldn't read the login page's settings.")) { try await awingSession() }
            #expect(!FakeNetwork.hosts.contains(AwingFixture.controller))
        }
    }

    @Test func awingPassesOnTheControllersRefusal() async throws {
        let refusal = "\n<HTML><TITLE>Authentication Error</TITLE>\n<BODY><P>The server could not fulfill your request.<BR>Please refresh to try login again.\n</BODY></HTML>\n"
        FakeNetwork.serve(AwingFixture.routes(controller: .init(status: 200, body: refusal)))
        let session = try await awingSession()
        await #expect(throws: LoginError.refused("The login page refused the login.")) { try await AwingExtreme.login(session, client: client) }
    }

    @Test func awingCancelledLoginNeverReachesTheController() async throws {
        FakeNetwork.serve(AwingFixture.routes())
        let session = try await awingSession()
        let client = client
        let login = Task { try await AwingExtreme.login(session, client: client) }
        login.cancel()
        await #expect(throws: (any Error).self) { try await login.value }
        #expect(!FakeNetwork.hosts.contains(AwingFixture.controller))
    }
}

struct LocalNetworkTests {
    let network = AwingFixture.network

    @Test func containsAddressesInItsSubnet() {
        #expect(network.contains("10.29.64.2"))
        #expect(network.contains("10.29.67.254"))
        #expect(!network.contains("10.29.68.1"))
        #expect(!network.contains("10.29.64"))
        #expect(!network.contains("10.29.64.2.example"))
        #expect(!network.contains("+10.29.64.2"))
        #expect(!network.contains("10.29.64.256"))
    }

    /// The services as macOS listed them at the cafe with Tailscale's exit node on: the tunnel first, then the Wi-Fi.
    @Test func looksBelowAVPNThatCarriesAllTraffic() {
        let tailscale: [String: Any] = ["InterfaceName": "utun7", "Router": "100.108.159.107", "Addresses": ["100.108.159.107"], "SubnetMasks": ["255.255.255.255"]]
        let tun: [String: Any] = ["InterfaceName": "tun0", "Router": "10.8.0.1", "Addresses": ["10.8.0.2"], "SubnetMasks": ["255.255.255.0"]]
        let wifi: [String: Any] = ["InterfaceName": "en0", "Router": "10.29.64.1", "Addresses": ["10.29.64.96"], "SubnetMasks": ["255.255.252.0"]]
        let hardware: Set = ["en0", "en1", "en4"]
        #expect(Gateway.pick(from: [tailscale, tun, [:], wifi], wifiOrEthernet: hardware) == network)
        #expect(Gateway.pick(from: [tailscale, tun], wifiOrEthernet: hardware) == nil)
    }
}
