import Foundation

/// One response on the way through a login page: the address, its status, where it sent the Mac next, and its body.
public struct Hop: Sendable, Equatable {
    public let url: URL
    public let status: Int
    public let location: URL?
    public let body: String

    public init(url: URL, status: Int, location: URL?, body: String) {
        self.url = url
        self.status = status
        self.location = location
        self.body = body
    }
}

public enum ProbeResult: Sendable, Equatable {
    case online
    /// Something answered instead of Apple's check page, most likely a login page.
    case portal([Hop])
    case offline
}

public enum RequestError: Error, Equatable {
    /// An address with a user name or password in it, which no login flow needs.
    case refusedAddress
    /// The Wi-Fi router did not answer, often because Local Network access is off for the app.
    case routerUnreachable
}

/// Sends one request on `network` and never follows a redirect. `local` marks a request to a device on the Wi-Fi,
/// which may wait while macOS asks for Local Network access.
protocol Transport: Sendable {
    func send(_ request: URLRequest, local: Bool, network: LocalNetwork?) async throws -> (Data, HTTPURLResponse)
}

/// HTTP for login pages, straight over the Wi-Fi (see DirectTransport). Nothing is shared with Safari or kept on disk.
/// It never follows a redirect by itself: each driver decides which addresses it may visit. It never runs a page's
/// scripts.
public final class PortalClient: Sendable {
    public static let probeURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private let transport: any Transport
    private let network: LocalNetwork?

    public convenience init() {
        self.init(transport: DirectTransport())
    }

    init(transport: any Transport, network: LocalNetwork? = nil) {
        self.transport = transport
        self.network = network
    }

    /// The same client, sending only on `network`: requests fail once the Mac is on another one.
    public func on(_ network: LocalNetwork?) -> PortalClient {
        PortalClient(transport: transport, network: network)
    }

    /// Asks for Apple's check page. Login pages answer it with a redirect or a page of their own.
    public func probe() async -> ProbeResult {
        guard let hop = try? await get(Self.probeURL).first else { return .offline }
        if hop.status == 200, hop.body.contains("<TITLE>Success</TITLE>") { return .online }
        return .portal([hop])
    }

    /// Fetches `url`, then keeps going through HTTP and script redirects while `follow` allows the next address.
    public func get(_ url: URL, maxHops: Int = 6, follow: (URL) -> Bool = { _ in false }) async throws -> [Hop] {
        var hops: [Hop] = []
        var next: URL? = url
        while let current = next, hops.count < maxHops {
            next = nil
            let hop = try await hop(for: Self.request(current))
            hops.append(hop)
            if let location = hop.location, ["http", "https"].contains(location.scheme), follow(location) { next = location }
        }
        return hops
    }

    /// A request to the Wi-Fi router itself, which needs Local Network access.
    public func getFromRouter(_ url: URL) async throws -> Hop {
        try await toRouter(Self.request(url))
    }

    /// A form posted to the router or another device on the Wi-Fi, from a page on `origin`, as a browser posts it.
    public func postFormToRouter(_ fields: KeyValuePairs<String, String>, to url: URL, origin: String) async throws -> Hop {
        var request = Self.request(url, method: "POST", body: Data(Self.formEncoded(fields).utf8))
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        return try await toRouter(request)
    }

    private func toRouter(_ request: URLRequest) async throws -> Hop {
        do {
            return try await hop(for: request, local: true)
        } catch let error as URLError {
            throw [.timedOut, .notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost].contains(error.code) ? RequestError.routerUnreachable : error
        }
    }

    public func postJSON(_ object: [String: String], to url: URL) async throws -> Data {
        var request = Self.request(url, method: "POST", body: try JSONSerialization.data(withJSONObject: object))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request).0
    }

    /// The body of a successful response; other statuses throw. A POST goes out empty, from the page at `referer`, as
    /// a page's script sends it.
    public func fetch(_ url: URL, method: String = "GET", referer: URL? = nil) async throws -> Data {
        var request = Self.request(url, method: method, body: method == "POST" ? Data() : nil)
        request.setValue(referer?.absoluteString, forHTTPHeaderField: "Referer")
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    private func hop(for request: URLRequest, local: Bool = false) async throws -> Hop {
        let url = request.url!
        let (data, response) = try await send(request, local: local)
        let body = String(decoding: data, as: UTF8.self)
        let header = response.value(forHTTPHeaderField: "Location")
        let location = (header.flatMap { URL(string: $0, relativeTo: url) } ?? Self.scriptRedirect(in: body, from: url))?.absoluteURL
        return Hop(url: url, status: response.statusCode, location: location, body: body)
    }

    private func send(_ request: URLRequest, local: Bool = false) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.user == nil, url.password == nil else { throw RequestError.refusedAddress }
        return try await transport.send(request, local: local, network: network)
    }

    private static func request(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// application/x-www-form-urlencoded, encoded the way browsers encode a form.
    static func formEncoded(_ fields: KeyValuePairs<String, String>) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*-._ ")
        func encode(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: plain)!.replacingOccurrences(of: " ", with: "+")
        }
        return fields.map { encode($0.key) + "=" + encode($0.value) }.joined(separator: "&")
    }

    /// The address a page sends the browser to with a script or a meta refresh, as many login pages do.
    static func scriptRedirect(in body: String, from page: URL) -> URL? {
        let patterns = [
            /location(?:\.href)?\s*=\s*["']([^"']+)["']/,
            /location\.replace\(\s*["']([^"']+)["']/,
            /(?i)http-equiv=["']?refresh["']?[^>]*?url=([^"'>\s]+)/,
        ]
        for pattern in patterns {
            if let match = body.firstMatch(of: pattern) {
                return URL(string: String(match.1).replacingOccurrences(of: "&amp;", with: "&"), relativeTo: page)
            }
        }
        return nil
    }
}
