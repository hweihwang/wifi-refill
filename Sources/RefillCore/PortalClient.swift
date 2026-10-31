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

/// HTTP for login pages. Ephemeral, so nothing is shared with Safari or kept on disk. It never follows a redirect by
/// itself: each driver decides which addresses it may visit. It never runs a page's scripts.
public final class PortalClient: @unchecked Sendable {
    public static let probeURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    static let bodyLimit = 256 * 1024

    private let session: URLSession
    private let routerSession: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        // The resource deadline also ends responses that trickle in slowly, which the per-request timeout does not.
        let main = Self.prepared(configuration)
        main.timeoutIntervalForResource = 20
        session = URLSession(configuration: main, delegate: NoRedirects(), delegateQueue: nil)
        // macOS may hold the first request to the router while it asks about Local Network access; wait for the answer.
        let router = Self.prepared(configuration.copy() as! URLSessionConfiguration)
        router.waitsForConnectivity = true
        router.timeoutIntervalForResource = 30
        routerSession = URLSession(configuration: router, delegate: NoRedirects(), delegateQueue: nil)
    }

    private static func prepared(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        configuration.timeoutIntervalForRequest = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return configuration
    }

    /// Asks for Apple's check page. Login pages answer it with a redirect or a page of their own.
    public func probe() async -> ProbeResult {
        guard let hop = try? await get(Self.probeURL).first else { return .offline }
        if hop.status == 200, hop.body.contains("<TITLE>Success</TITLE>") { return .online }
        return .portal([hop])
    }

    /// Fetches `url`, then keeps going through HTTP and script redirects while `follow` allows the next address.
    public func get(_ url: URL, maxHops: Int = 6, follow: (URL) -> Bool = { _ in false }) async throws -> [Hop] {
        try await get(url, with: session, maxHops: maxHops, follow: follow)
    }

    /// A request to the Wi-Fi router itself, which needs Local Network access.
    public func getFromRouter(_ url: URL) async throws -> Hop {
        do {
            return try await get(url, with: routerSession, maxHops: 1, follow: { _ in false })[0]
        } catch let error as URLError {
            throw [.timedOut, .notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost].contains(error.code) ? RequestError.routerUnreachable : error
        }
    }

    public func postJSON(_ object: [String: String], to url: URL) async throws -> Data {
        guard url.user == nil, url.password == nil else { throw RequestError.refusedAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        return try await read(request, with: session).0
    }

    /// The body of a successful response; other statuses throw.
    public func fetch(_ url: URL) async throws -> Data {
        guard url.user == nil, url.password == nil else { throw RequestError.refusedAddress }
        let (data, response) = try await read(URLRequest(url: url), with: session)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return data
    }

    private func get(_ url: URL, with session: URLSession, maxHops: Int, follow: (URL) -> Bool) async throws -> [Hop] {
        var hops: [Hop] = []
        var next: URL? = url
        while let current = next, hops.count < maxHops {
            next = nil
            guard current.user == nil, current.password == nil else { throw RequestError.refusedAddress }
            let (data, response) = try await read(URLRequest(url: current), with: session)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data, as: UTF8.self)
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location")
            let location = (header.flatMap { URL(string: $0, relativeTo: current) } ?? Self.scriptRedirect(in: body, from: current))?.absoluteURL
            hops.append(Hop(url: current, status: status, location: location, body: body))
            if let location, ["http", "https"].contains(location.scheme), follow(location) { next = location }
        }
        return hops
    }

    /// Reads at most `bodyLimit` bytes, so a hostile network cannot fill memory.
    private func read(_ request: URLRequest, with session: URLSession) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= Self.bodyLimit {
                bytes.task.cancel()
                break
            }
        }
        return (data, response)
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

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
