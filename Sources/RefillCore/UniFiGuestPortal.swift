import Foundation

/// UniFi guest portals that log in without a password or a voucher: UniFi Network's hotspot portal set to no
/// authentication, terms or not.
///
/// Recorded from UniFi Network Application 10.0.162 (portal 3.0.16) in a container, not yet on a cafe's network: the
/// access point sends Apple's check page to `/guest/s/<site>/` on the controller, with `id`, the Mac's Wi-Fi hardware
/// address, and the access point, the time and the page asked for. Opening that address sets a cookie that carries
/// them, `hotspotconfig` says how the portal logs in, and its button posts an empty `login`, which answers whether the
/// Mac may pass. The controller can be on the Wi-Fi or on the internet.
public enum UniFiGuestPortal: PortalDriver {
    public static func entry(in probe: [Hop]) -> URL? {
        probe.compactMap(\.location).first(where: isPortal)
    }

    static func isPortal(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme) && url.user == nil && url.host != nil
            && url.path(percentEncoded: true).wholeMatch(of: /\/guest\/s\/[A-Za-z0-9_-]+\//) != nil
            && URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems?.contains { $0.name == "id" && $0.value?.isEmpty == false } == true
    }

    public static func prepare(from entry: URL, on network: LocalNetwork, client: PortalClient) async throws -> PortalSession {
        guard let host = entry.host, let portal = URL(string: entry.path(percentEncoded: true), relativeTo: entry)?.absoluteURL else {
            throw LoginError.unexpected("The login page did not start a session.")
        }
        let local = network.contains(host)
        // The portal keeps this visit's details in a cookie, set by the address the access point sent.
        if local { _ = try await client.getFromRouter(entry) } else { _ = try await client.get(entry) }
        let config: [String: Any]
        do {
            let data = try await client.fetch(portal.appending(path: "hotspotconfig"), local: local)
            config = try ((JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]])?.first ?? [:]
        } catch {
            throw LoginError.unexpected("Couldn't read the login page's settings.")
        }
        guard let auth = config["auth"] as? String else { throw LoginError.unexpected("Couldn't read the login page's settings.") }
        guard auth == "none" else { throw LoginError.unsupported("This login page asks for a password or a voucher.") }
        let ssid = URLComponents(url: entry, resolvingAgainstBaseURL: true)?.queryItems?.first { $0.name == "ssid" }?.value
        return PortalSession(
            profile: "unifi:" + (network.signature ?? host) + entry.path(percentEncoded: true),
            network: ssid.flatMap { $0.isEmpty ? nil : $0 } ?? "Wi-Fi",
            router: network.router,
            minutes: nil,
            details: ["portal": portal.absoluteString, "local": local ? "yes" : "no"]
        )
    }

    public static func login(_ session: PortalSession, client: PortalClient) async throws {
        guard let portal = session.details["portal"].flatMap(URL.init(string:)) else {
            throw LoginError.unexpected("The login page lost its session.")
        }
        try Task.checkCancellation()
        let data = try await client.fetch(portal.appending(path: "login"), method: "POST", local: session.details["local"] == "yes")
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let answer = (json?["data"] as? [[String: Any]])?.first
        guard (json?["meta"] as? [String: Any])?["rc"] as? String == "ok", answer?["authorized"] as? Bool == true else {
            throw LoginError.refused("The login page refused the login.")
        }
    }
}
