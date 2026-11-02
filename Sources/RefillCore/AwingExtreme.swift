import Foundation

/// Awing Free Wi-Fi login pages (`*.awingconnect.vn`) on Extreme Networks Wi-Fi, as at Highlands Coffee.
///
/// The flow, as recorded on a real network: the Wi-Fi controller sends Apple's check page to Awing's `/login` with
/// `hs_server`, the controller's address on the Wi-Fi, and `Qv`, its own parameters for this visit. The page shows an
/// advert and then posts a hidden form with those two values to `http://<hs_server>:880/cgi-bin/hslogin.cgi`, which
/// lets the Mac through. Awing sends that form in its answer to `/Home/VerifyUrl`; reading it confirms the page still
/// logs in the way it was tested.
public enum AwingExtreme: PortalDriver {
    static func isPage(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme) && url.user == nil && url.port == nil
            && url.host?.wholeMatch(of: /[a-z0-9-]+\.awingconnect\.vn/) != nil
    }

    public static func entry(in probe: [Hop]) -> URL? {
        probe.compactMap(\.location).first { isPage($0) && $0.path == "/login" && value("hs_server", in: $0) != nil && value("Qv", in: $0) != nil }
    }

    public static func prepare(from entry: URL, on network: LocalNetwork, client: PortalClient) async throws -> PortalSession {
        guard let server = value("hs_server", in: entry), let qv = value("Qv", in: entry), let scheme = entry.scheme, let host = entry.host else {
            throw LoginError.unexpected("The login page did not start a session.")
        }
        // The form only ever goes to a device on the Mac's own network.
        guard network.contains(server) else { throw LoginError.unexpected("The login page pointed somewhere other than the router.") }

        let origin = "\(scheme)://\(host)"
        let context: [String: Any]
        do {
            // Awing reads which visit this is from the Referer, as the page's script sends it.
            let data = try await client.fetch(URL(string: origin + "/Home/VerifyUrl")!, method: "POST", referer: entry)
            context = try (JSONSerialization.jsonObject(with: data) as? [String: Any])?["captiveContext"] as? [String: Any] ?? [:]
        } catch {
            throw LoginError.unexpected("Couldn't read the login page's settings.")
        }
        guard let form = context["contentAuthenForm"] as? String, let place = (context["campaignData"] as? [String: Any])?["placeId"] as? Int else {
            throw LoginError.unexpected("Couldn't read the login page's settings.")
        }
        let workspace = context["workspace"] as? [String: Any]
        let customerData = workspace?["requiredCustomerData"]
        if (context["customerRequiredFields"] as? [Any])?.isEmpty == false || (customerData != nil && !(customerData is NSNull)) {
            throw LoginError.unsupported("This login page asks for your details.")
        }
        guard knowsForm(form) else { throw LoginError.unsupported("This login page isn't supported yet.") }

        return PortalSession(
            profile: "awing:\(place)",
            network: (workspace?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Wi-Fi",
            router: network.router,
            minutes: nil,
            details: ["server": server, "qv": qv, "origin": origin]
        )
    }

    public static func login(_ session: PortalSession, client: PortalClient) async throws {
        guard let server = session.details["server"], let qv = session.details["qv"], let origin = session.details["origin"] else {
            throw LoginError.unexpected("The login page lost its session.")
        }
        try Task.checkCancellation()
        let answer = try await client.postFormToRouter(
            ["f_flex": "", "f_flex_type": "log", "f_hs_server": server, "f_Qv": qv],
            to: URL(string: "http://\(server):880/cgi-bin/hslogin.cgi")!,
            origin: origin
        )
        if answer.body.contains("<TITLE>Authentication Error</TITLE>") { throw LoginError.refused("The login page refused the login.") }
        guard (200..<400).contains(answer.status) else { throw LoginError.unexpected("The router did not accept the login.") }
    }

    /// The hidden form and script exactly as Awing sent them on the tested network. Anything else, however small the
    /// change, is a page nobody has checked: even a line break changes what the script does.
    static let testedForm = #"""
        <form name="extreme" id="frmLogin" action="/cgi-bin/hslogin.cgi" method="POST" style="display: none;">
            <input name="f_flex" id="f_flex" type="hidden">
            <input name="f_flex_type" id="f_flex_type" type="hidden" value="log">
            <input name="f_hs_server" id="f_hs_server" type="hidden">
            <input name="f_Qv" id="f_Qv" type="hidden">
        </form>
        <script>
            // set params from URL to form
            var hs_server = "NONE";
            var port = 880;
            var postToUrl = "/cgi-bin/hslogin.cgi";
            hs_server = getQueryVariable("hs_server");
            Qv = getQueryVariable("Qv");
            postToUrl = ":" + port + postToUrl;
            document.getElementById("f_hs_server").value = hs_server;
            document.getElementById("f_Qv").value = Qv;
            document.getElementById("frmLogin").action = "http://" + hs_server + postToUrl;

            function getQueryVariable(variable) {
                var query = window.location.search.substring(1);
                var vars = query.split(/[?&]/);
                for (var i = 0; i < vars.length; i++) {
                    var pair = vars[i].split("=");
                    if (pair[0] == variable) {
                        if (pair[0] == "Qv") {
                            return vars[i].substr(3, vars[i].length);
                        }
                        return pair[1]; 
                    }
                }
                return "";
            }
            awingStateMachineContext.setAuthenType(awingConstants.AUTHEN_TYPE.IFRAME);
        </script>
        """#

    static func knowsForm(_ form: String) -> Bool {
        form.utf8.elementsEqual(testedForm.utf8)
    }

    /// A parameter exactly as it appears in the address: the page's own script copies it into the form undecoded.
    static func value(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedQueryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
