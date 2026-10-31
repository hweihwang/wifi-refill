import Foundation
@testable import RefillCore

/// Answers PortalClient's requests from recorded responses, keyed by host and path, and remembers every request.
final class FakeNetwork: URLProtocol {
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeNetwork.self]
        return PortalClient(configuration: configuration)
    }

    /// "host/path" of every request, in order.
    static var visited: [String] { lock.withLock { log.map { ($0.url.host ?? "") + $0.url.path(percentEncoded: true) } } }
    static var hosts: Set<String> { Set(lock.withLock { log.compactMap(\.url.host) }) }

    static func posted(to path: String) -> [String: String]? {
        let body = lock.withLock { log.last(where: { $0.url.path(percentEncoded: true) == path && $0.body != nil })?.body }
        return body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let route = Self.lock.withLock {
            Self.log.append((url, request.httpBody ?? request.httpBodyStream.map(Self.read)))
            return Self.routes[(url.host ?? "") + url.path(percentEncoded: true)]
        }
        guard let route else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var headers = ["Content-Type": "text/html"]
        if let location = route.location { headers["Location"] = location }
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(route.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
