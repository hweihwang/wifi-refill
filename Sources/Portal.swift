import Foundation

/// Talks to Ruijie Cloud captive portals that offer "One-click Login".
struct Portal {
    enum Probe { case online, ruijie(String), otherPortal, offline }

    struct Login {
        let minutes: Int?
        let network: String
        let gatewayPort: String
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    static let probeURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"]
        session = URLSession(configuration: config)
    }

    func probe() async -> Probe {
        guard let page = try? await fetch(Self.probeURL) else { return .offline }
        if page.contains("<TITLE>Success</TITLE>") { return .online }
        return page.contains("ruijienetworks.com") ? .ruijie(page) : .otherPortal
    }

    /// Does what the "One-click Login" button does, then reads the session length from the portal's config.
    func login(_ probePage: String) async throws -> Login {
        var page = probePage
        // A router can answer with a page that redirects by script; follow the portal link in it.
        if page.firstMatch(of: /sessionId=/) == nil,
           let link = page.firstMatch(of: /https:\/\/portal-[a-z0-9-]+\.ruijienetworks\.com\/[^"'<>\s]+/),
           let url = URL(string: String(link.0).replacingOccurrences(of: "&amp;", with: "&")) {
            page += "\n" + (try await fetch(url))
        }
        guard let portal = page.firstMatch(of: /https:\/\/portal-[a-z0-9-]+\.ruijienetworks\.com/)?.0,
              let sessionId = page.firstMatch(of: /sessionId=([0-9A-Za-z]+)/)?.1
        else { throw Failure(description: "the login page has no session") }

        var request = URLRequest(url: URL(string: "\(portal)/api/auth/direct/?lang=en_US")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["phoneNumber": "", "sessionId": String(sessionId)])
        let reply = try JSONSerialization.jsonObject(with: try await session.data(for: request).0) as? [String: Any]
        guard let logon = (reply?["result"] as? [String: Any])?["logonUrl"] as? String, let logonURL = URL(string: logon) else {
            throw Failure(description: reply?["message"] as? String ?? "the portal refused the login")
        }
        _ = try await session.data(from: logonURL)
        guard case .online = await probe() else { throw Failure(description: "still offline after login") }

        return Login(
            minutes: await sessionMinutes(portal: String(portal), page: page),
            network: page.firstMatch(of: /[?&]ssid=([^&\s]+)/).flatMap { String($0.1).removingPercentEncoding } ?? "Wi-Fi",
            gatewayPort: page.firstMatch(of: /[?&]gw_port=([0-9]+)/).map { String($0.1) } ?? "2060"
        )
    }

    /// True when the router answers on its portal port, which tells a remembered cafe router from another router at the same address.
    func routerAnswers(_ address: String) async -> Bool {
        guard let url = URL(string: "http://\(address)/") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        return (try? await session.data(for: request)) != nil
    }

    private func sessionMinutes(portal: String, page: String) async -> Int? {
        guard let theme = page.firstMatch(of: /RES=[^&"'\s]*\/([0-9A-Za-z]+)/)?.1,
              let url = URL(string: "\(portal)/download/static/maccauth/expand/res/\(theme)/config.json"),
              let data = try? await session.data(from: url).0,
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let validity = (config["oneclick"] as? [String: Any])?["oneclick_validity"]
        else { return nil }
        return Int("\(validity)")
    }

    /// Returns the body followed by every URL the request went through, so callers can search one text.
    private func fetch(_ url: URL) async throws -> String {
        let recorder = RedirectRecorder()
        let (data, response) = try await session.data(for: URLRequest(url: url), delegate: recorder)
        return ([String(decoding: data, as: UTF8.self)] + recorder.urls + [response.url?.absoluteString ?? ""]).joined(separator: "\n")
    }
}

private final class RedirectRecorder: NSObject, URLSessionTaskDelegate {
    var urls: [String] = []

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        if let url = request.url?.absoluteString { urls.append(url) }
        return request
    }
}
