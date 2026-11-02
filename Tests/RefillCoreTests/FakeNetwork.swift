import Foundation
@testable import RefillCore

/// Answers PortalClient's requests from recorded responses, keyed by host and path, and remembers every request.
final class FakeNetwork: Transport {
    struct Response {
        var status = 200
        var location: String?
        var body = ""
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Response] = [:]
    nonisolated(unsafe) private static var log: [(url: URL, body: Data?)] = []

    static func serve(_ newRoutes: [String: Response]) {
        lock.withLock { routes = newRoutes; log = [] }
    }

    static func client() -> PortalClient {
        PortalClient(transport: FakeNetwork())
    }

    /// "host/path" of every request, in order.
    static var visited: [String] { lock.withLock { log.map { ($0.url.host ?? "") + $0.url.path(percentEncoded: true) } } }
    static var hosts: Set<String> { Set(lock.withLock { log.compactMap(\.url.host) }) }

    static func posted(to path: String) -> [String: String]? {
        body(postedTo: path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
    }

    static func body(postedTo path: String) -> Data? {
        lock.withLock { log.last(where: { $0.url.path(percentEncoded: true) == path && $0.body != nil })?.body }
    }

    func send(_ request: URLRequest, local: Bool, network: LocalNetwork?) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let url = request.url!
        let route = Self.lock.withLock {
            Self.log.append((url, request.httpBody))
            return Self.routes[(url.host ?? "") + url.path(percentEncoded: true)]
        }
        guard let route else { throw URLError(.cannotConnectToHost) }
        var headers = ["Content-Type": "text/html"]
        if let location = route.location { headers["Location"] = location }
        return (Data(route.body.utf8), HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}
