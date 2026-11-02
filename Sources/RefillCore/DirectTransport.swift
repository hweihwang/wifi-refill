import Foundation
import Network

/// HTTP/1.1 over the Wi-Fi or Ethernet itself, as macOS checks for login pages.
///
/// A VPN that carries all traffic, such as Tailscale with an exit node, reaches nothing while a login page holds the
/// network, so a check through it only ever sees "offline". URLSession cannot choose an interface; Network.framework can.
/// Every request goes out on the interface of the network its check started on, the one drivers check addresses
/// against, and only while the Mac is still on that network.
final class DirectTransport: Transport, @unchecked Sendable {
    static let bodyLimit = 256 * 1024
    /// A whole request, including a slow response. The router gets longer: macOS may be asking about Local Network access.
    static let deadline: TimeInterval = 20
    static let localDeadline: TimeInterval = 30

    private let queue = DispatchQueue(label: "com.hweihwang.WiFiRefill.http")
    private let cookies: HTTPCookieStorage

    init() {
        cookies = URLSessionConfiguration.ephemeral.httpCookieStorage ?? HTTPCookieStorage()
        cookies.cookieAcceptPolicy = .always
    }

    func send(_ request: URLRequest, local: Bool, network: LocalNetwork?) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let network else { throw URLError(.notConnectedToInternet) }
        guard let url = request.url, let host = url.host, let scheme = url.scheme, ["http", "https"].contains(scheme),
              let port = UInt16(exactly: url.port ?? (scheme == "https" ? 443 : 80)).flatMap(NWEndpoint.Port.init(rawValue:))
        else { throw URLError(.unsupportedURL) }
        let parameters: NWParameters = scheme == "https" ? .tls : .tcp
        parameters.requiredInterface = try await Interfaces.shared.of(network)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)

        var message = request
        if let cookie = HTTPCookie.requestHeaderFields(with: cookies.cookies(for: url) ?? [])["Cookie"] {
            message.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let framing = try await exchange(Self.message(for: message, url: url), on: connection, network: network, waits: local, deadline: local ? Self.localDeadline : Self.deadline)
        guard case .complete(let status, let headers, let body) = framing,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else { throw URLError(.badServerResponse) }
        if let setCookie = headers["set-cookie"] {
            cookies.setCookies(HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": setCookie], for: url), for: url, mainDocumentURL: nil)
        }
        return (Data(body.prefix(Self.bodyLimit)), response)
    }

    /// Sends `message` and reads until the response is whole, the server closes, or the body passes the limit.
    private func exchange(_ message: Data, on connection: NWConnection, network: LocalNetwork, waits: Bool, deadline: TimeInterval) async throws -> Framing {
        /// Touched on `queue` only.
        final class State: @unchecked Sendable {
            var continuation: CheckedContinuation<Framing, Error>?
            var cancelled = false
            var raw = Data()
            var timer: DispatchWorkItem?
            let connection: NWConnection
            init(_ connection: NWConnection) { self.connection = connection }

            func finish(_ result: Result<Framing, Error>) {
                guard let continuation else { return }
                self.continuation = nil
                timer?.cancel()
                timer = nil
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(with: result)
            }
        }
        let state = State(connection)
        // The deadline must not keep a finished request's state alive until it would have fired.
        weak var expiring = state
        let queue = queue
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !state.cancelled else { return continuation.resume(throwing: CancellationError()) }
                    state.continuation = continuation
                    func receive() {
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, closed, error in
                            if let data { state.raw.append(data) }
                            let framing = Self.frame(state.raw, closed: closed, full: state.raw.count > Self.bodyLimit + 64 * 1024)
                            if framing != .incomplete {
                                state.finish(.success(framing))
                            } else if let error {
                                state.finish(.failure(URLError(.networkConnectionLost, userInfo: [NSUnderlyingErrorKey: error])))
                            } else {
                                receive()
                            }
                        }
                    }
                    connection.stateUpdateHandler = { status in
                        switch status {
                        case .ready:
                            // A connection can wait a long while, for Local Network access for one; the Mac may be
                            // on another network by the time it opens.
                            guard Gateway.current() == network else { return state.finish(.failure(URLError(.networkConnectionLost))) }
                            connection.send(content: message, completion: .contentProcessed { error in
                                if let error { state.finish(.failure(URLError(.networkConnectionLost, userInfo: [NSUnderlyingErrorKey: error]))) } else { receive() }
                            })
                        case .waiting(let error) where !waits, .failed(let error):
                            state.finish(.failure(URLError(.cannotConnectToHost, userInfo: [NSUnderlyingErrorKey: error])))
                        case .cancelled:
                            state.finish(.failure(CancellationError()))
                        default:
                            break
                        }
                    }
                    let timer = DispatchWorkItem { expiring?.finish(.failure(URLError(.timedOut))) }
                    state.timer = timer
                    queue.asyncAfter(deadline: .now() + deadline, execute: timer)
                    connection.start(queue: queue)
                }
            }
        } onCancel: {
            queue.async {
                state.cancelled = true
                state.finish(.failure(CancellationError()))
            }
        }
    }

    static func message(for request: URLRequest, url: URL) -> Data {
        var target = url.path(percentEncoded: true)
        if target.isEmpty { target = "/" }
        if let query = url.query(percentEncoded: true) { target += "?" + query }
        let defaultPort = url.scheme == "https" ? 443 : 80
        var headers = request.allHTTPHeaderFields ?? [:]
        headers["Host"] = url.host(percentEncoded: true)! + (url.port.map { $0 == defaultPort ? "" : ":\($0)" } ?? "")
        headers["Accept"] = headers["Accept"] ?? "*/*"
        headers["Accept-Encoding"] = "identity"
        headers["Connection"] = "close"
        if let body = request.httpBody { headers["Content-Length"] = String(body.count) }
        let lines = ["\(request.httpMethod ?? "GET") \(target) HTTP/1.1"] + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + (request.httpBody ?? Data())
    }

    enum Framing: Equatable {
        case incomplete
        /// Header names lowercased; repeated headers joined, as browsers do.
        case complete(status: Int, headers: [String: String], body: Data)
        case malformed
    }

    /// One response read from `raw`. `closed`: the server ended the connection. `full`: the body reached the limit, and
    /// what arrived so far stands. A body shorter than the server announced is malformed, not complete.
    static func frame(_ raw: Data, closed: Bool = false, full: Bool = false) -> Framing {
        let ended = closed || full
        var rest = raw[...]
        while true {
            guard let end = rest.firstRange(of: Data("\r\n\r\n".utf8)) else { return ended ? .malformed : .incomplete }
            let lines = String(decoding: rest[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            rest = rest[end.upperBound...]
            let statusLine = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard statusLine.count >= 2, ["HTTP/1.1", "HTTP/1.0"].contains(statusLine[0]), let status = decimal(statusLine[1]), (100...599).contains(status) else {
                return .malformed
            }
            // An interim answer such as 103 Early Hints; the real one follows.
            if status < 200 { continue }

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { return .malformed }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = headers[name].map { $0 + ", " + value } ?? value
            }
            // These carry no body, whatever their length headers describe.
            if status == 204 || status == 304 { return .complete(status: status, headers: headers, body: Data()) }
            if let coding = headers["content-encoding"], coding.lowercased() != "identity" { return .malformed }
            let body = Data(rest)

            if let encoding = headers["transfer-encoding"] {
                guard encoding.lowercased() == "chunked" else { return .malformed }
                switch dechunk(body) {
                case .complete(let content): return .complete(status: status, headers: headers, body: content)
                case .partial(let content): return full ? .complete(status: status, headers: headers, body: content) : closed ? .malformed : .incomplete
                case .malformed: return .malformed
                }
            }
            if let text = headers["content-length"] {
                guard let length = decimal(text) else { return .malformed }
                if body.count >= length { return .complete(status: status, headers: headers, body: body.prefix(length)) }
                return full ? .complete(status: status, headers: headers, body: body) : closed ? .malformed : .incomplete
            }
            // No length given: the body ends when the server closes, as HTTP/1.0 routers do.
            return ended ? .complete(status: status, headers: headers, body: body) : .incomplete
        }
    }

    enum Chunks: Equatable {
        case complete(Data), partial(Data), malformed
    }

    static func dechunk(_ data: Data) -> Chunks {
        let lineEnd = Data("\r\n".utf8)
        var body = Data()
        var rest = data[...]
        while true {
            guard let end = rest.firstRange(of: lineEnd) else { return rest.count > 1024 ? .malformed : .partial(body) }
            let sizeText = String(decoding: rest[..<end.lowerBound], as: UTF8.self).prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
            // Eight hex digits are 4 GB, far past the body limit and far from overflowing.
            guard (1...8).contains(sizeText.count), sizeText.allSatisfy({ $0.isASCII && $0.isHexDigit }), let size = Int(sizeText, radix: 16) else {
                return .malformed
            }
            let start = end.upperBound
            if size == 0 {
                let trailer = rest[start...]
                return trailer.starts(with: lineEnd) || trailer.firstRange(of: Data("\r\n\r\n".utf8)) != nil ? .complete(body) : .partial(body)
            }
            guard rest.distance(from: start, to: rest.endIndex) >= size + 2 else { return .partial(body + rest[start...].prefix(size)) }
            let stop = rest.index(start, offsetBy: size)
            guard rest[stop..<rest.index(stop, offsetBy: 2)].elementsEqual(lineEnd) else { return .malformed }
            body += rest[start..<stop]
            rest = rest[rest.index(stop, offsetBy: 2)...]
        }
    }

    /// A non-negative decimal number in plain ASCII digits, as HTTP writes status codes and lengths.
    static func decimal(_ text: some StringProtocol) -> Int? {
        guard (1...15).contains(text.count), text.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(text)
    }
}
