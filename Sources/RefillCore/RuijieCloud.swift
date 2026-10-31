import Foundation

/// Ruijie Cloud (Reyee) login pages with a "One-click Login" button, served from portal-*.ruijienetworks.com.
///
/// The flow, as recorded on a real network: the router redirects Apple's check page to `/auth/wifidogAuth/login/`,
/// which sends the browser on by script to `/api/auth/wifidog`, which redirects to the login page with a
/// `sessionId`. The button posts that session to `/api/auth/direct/` and opens the `logonUrl` it gets back, an
/// address on the router that lets the Mac through.
public enum RuijieCloud: PortalDriver {
    static func isPortal(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.host?.wholeMatch(of: /portal-[a-z0-9-]+\.ruijienetworks\.com/) != nil
    }

    public static func entry(in probe: [Hop]) -> URL? {
        probe.compactMap(\.location).first(where: isPortal)
    }

    public static func prepare(from entry: URL, router: String, client: PortalClient) async throws -> PortalSession {
        // Stay on Ruijie's portal hosts, and stop at the address that carries the session: the page itself is not needed.
        let hops = try await client.get(entry) { isPortal($0) && !$0.absoluteString.contains("sessionId=") }
        let params = parameters(of: [entry] + hops.compactMap(\.location))

        guard let sessionId = params["sessionId"], let host = entry.host else {
            throw LoginError.unexpected("The login page did not start a session.")
        }
        // IS_EG names the gateway type. Only cloud one-click (0) has been checked on a real network.
        if let type = params["IS_EG"], type != "0" { throw LoginError.unsupported("This Ruijie gateway type (\(type)) isn't supported yet.") }
        guard params["gw_address"] == router, let port = params["gw_port"] else {
            throw LoginError.unexpected("The login page named a different router.")
        }
        guard let theme = params["RES"]?.split(separator: "/").last,
              let data = try? await client.fetch(URL(string: "https://\(host)/download/static/maccauth/expand/res/\(theme)/config.json")!),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oneClick = settings["oneclick"] as? [String: Any]
        else { throw LoginError.unsupported("This login page has no One-click Login.") }

        let minutes = oneClick["oneclick_validity"].flatMap { Int("\($0)") }.map { min(max($0, 5), 24 * 60) }
        let device = params["gw_sn"] ?? params["gw_id"] ?? "\(router):\(port)"
        return PortalSession(
            profile: "ruijie:\(device)",
            network: params["ssid"] ?? "Wi-Fi",
            router: router,
            minutes: minutes,
            details: ["host": host, "sessionId": sessionId]
        )
    }

    public static func login(_ session: PortalSession, client: PortalClient) async throws {
        guard let host = session.details["host"], let sessionId = session.details["sessionId"] else {
            throw LoginError.unexpected("The login page lost its session.")
        }
        let reply = try await client.postJSON(["phoneNumber": "", "sessionId": sessionId], to: URL(string: "https://\(host)/api/auth/direct/?lang=en_US")!)
        let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
        guard let logon = ((json?["result"] as? [String: Any])?["logonUrl"] as? String).flatMap(URL.init(string:)) else {
            throw LoginError.refused(json?["message"] as? String ?? "The login page refused the login.")
        }
        // The token only ever goes to the router that sent the Mac here.
        guard logon.scheme == "http", logon.host == session.router, logon.path.hasPrefix("/wifidog/auth") else {
            throw LoginError.unexpected("The login page pointed somewhere other than the router.")
        }
        _ = try await client.getFromRouter(logon)
    }

    /// Query parameters across the redirect chain; later addresses win.
    static func parameters(of urls: [URL]) -> [String: String] {
        var result: [String: String] = [:]
        for url in urls {
            for item in URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? [] {
                if let value = item.value { result[item.name] = value }
            }
        }
        return result
    }
}
