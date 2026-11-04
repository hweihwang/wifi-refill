import Foundation

/// MikroTik HotSpot login pages (RouterOS) that offer a free trial, served by the router itself.
///
/// Checked against RouterOS 7.25.1 in a virtual machine, not yet on a cafe's network: the router answers Apple's check
/// page with a redirect to `/login` on its own address, with `dst`, the page that was asked for (as MikroTik documents).
/// When the network offers a trial, that page links to `/login` with the user name `T-` and the Mac's Wi-Fi hardware
/// address, filled in by the router; opening the link is all the page's "click here" does. Pages that only take a user
/// name and password are left to teaching.
public enum MikroTikHotspot: PortalDriver {
    public static func entry(in probe: [Hop]) -> URL? {
        probe.compactMap(\.location).first(where: isLogin)
    }

    static func isLogin(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme) && url.user == nil && url.host != nil && url.path == "/login"
            && URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems?.contains { $0.name == "dst" } == true
    }

    public static func prepare(from entry: URL, on network: LocalNetwork, client: PortalClient) async throws -> PortalSession {
        // A login page anywhere but on the Mac's own network is some other kind of page.
        guard let host = entry.host, await isOnNetwork(host, network) else { throw LoginError.unsupported("This login page isn't supported yet.") }
        let page = try await client.getFromRouter(entry)
        guard page.status == 200 else { throw LoginError.unexpected("Couldn't read the login page's settings.") }
        guard let trial = trialLink(in: page.body, from: entry) else {
            throw LoginError.unsupported("This login page asks for a user name and password.")
        }
        return PortalSession(
            profile: "mikrotik:" + (network.signature ?? host),
            network: LocalNetwork.ipv4(host) == nil ? host : "Wi-Fi",
            router: network.router,
            minutes: nil,
            details: ["trial": trial.absoluteString]
        )
    }

    public static func login(_ session: PortalSession, client: PortalClient) async throws {
        guard let trial = session.details["trial"].flatMap(URL.init(string:)) else {
            throw LoginError.unexpected("The login page lost its session.")
        }
        try Task.checkCancellation()
        let answer = try await client.getFromRouter(trial)
        // A refused trial, used up or not allowed for this Mac, shows the login page again with the reason.
        if answer.body.contains("username=T-") || answer.body.contains(#"name="login""#) {
            throw LoginError.refused("The login page refused the login.")
        }
        guard (200..<400).contains(answer.status) else { throw LoginError.unexpected("The router did not accept the login.") }
    }

    /// The page's free trial link, only when it leads to the same login address on the same device.
    static func trialLink(in body: String, from page: URL) -> URL? {
        for match in body.matches(of: /href\s*=\s*["']([^"']*username=T-[^"']*)["']/) {
            let text = String(match.1).replacingOccurrences(of: "&amp;", with: "&")
            guard let link = URL(string: text, relativeTo: page)?.absoluteURL,
                  link.scheme == page.scheme, link.host == page.host, link.port == page.port, link.path == "/login", link.user == nil,
                  URLComponents(url: link, resolvingAgainstBaseURL: true)?.queryItems?.first(where: { $0.name == "username" })?.value?.hasPrefix("T-") == true
            else { continue }
            return link
        }
        return nil
    }

    /// The router's address, or a name the network's own name server places on the Mac's network.
    static func isOnNetwork(_ host: String, _ network: LocalNetwork) async -> Bool {
        if LocalNetwork.ipv4(host) != nil { return network.contains(host) }
        let found = await Checkup.resolve(host, servers: Checkup.nameServers(of: network.interface), on: network)
        return found.address.map(network.contains) ?? false
    }
}
