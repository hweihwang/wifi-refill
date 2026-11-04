import Foundation
import Network
import SystemConfiguration

/// Looks at every leg between this Mac and the internet at once, on the Wi-Fi or Ethernet itself, and answers within
/// a few seconds however many legs are down.
public enum Checkup {
    /// Where each check goes. The doctor tool replaces them to stand in for a broken leg without breaking the network.
    public struct Targets: Sendable {
        /// nil: the network's own router, name servers, and Apple's check server's address.
        public var router: String?
        public var nameServers: [String]?
        public var internet: String?
        public var probe = PortalClient.probeURL
        public var vpn = PortalClient.probeURL

        public init() {}
    }

    static let checkHost = "captive.apple.com"
    static let quick: TimeInterval = 1
    static let patient: TimeInterval = 2.5
    /// The address that last served Apple's check page over the Wi-Fi, so a broken name server can be told from a
    /// broken line even on the first check after launch. Only a public address, noted by the transport that loaded it.
    private static var lastAddress: String? {
        get { UserDefaults.standard.string(forKey: "checkAddress") }
        set { UserDefaults.standard.set(newValue, forKey: "checkAddress") }
    }

    static func served(by address: String) {
        if isPublic(address), address != lastAddress { lastAddress = address }
    }

    public static func run(on network: LocalNetwork?, targets: Targets = Targets()) async -> Diagnosis {
        let start = Date()
        func done(_ seen: Observations) -> Diagnosis {
            Diagnosis(observations: seen, milliseconds: Int(Date().timeIntervalSince(start) * 1000))
        }
        let radio = Vitals.radio()
        guard let network else {
            if radio == .broken { return done(Observations(wifi: .broken)) }
            // Wi-Fi Refill looks at IPv4 legs only: on a network with IPv6 alone it can't tell.
            if let wifi = Vitals.interface, hasGlobalIPv6(wifi) { return done(Observations(wifi: radio)) }
            // Joined, but the router handed out no address.
            return done(Observations(wifi: radio, router: radio.isOK ? .broken : .unknown))
        }
        let router = targets.router ?? network.router
        let known = targets.internet ?? lastAddress
        async let reached = reach(router, on: network)
        async let lookup = resolve(checkHost, servers: targets.nameServers ?? nameServers(of: network.interface), on: network)
        async let line = connect(known, on: network, within: patient)
        async let probe = within(patient) { await PortalClient().on(network).probe(targets.probe) }
        async let vpn = throughVPN(targets.vpn, under: network)

        let dns = await lookup
        var internet = await line
        if known == nil, let address = dns.address {
            // Nothing known yet: try the address just looked up, in what is left of the time.
            internet = await connect(address, on: network, within: max(0.2, patient - Date().timeIntervalSince(start)))
        }
        var routerReading = await reached
        // A name server on the router that answers, even with an error, shows the router is there.
        if !routerReading.isOK, dns.responders.contains(router) { routerReading = .ok(milliseconds: nil) }
        let page = await probe
        let wifi = network.interface == Vitals.interface ? radio : .ok(milliseconds: nil)
        return done(Observations(wifi: wifi, router: routerReading, dns: dns.reading, internet: internet, probe: page, vpn: await vpn))
    }

    /// A connection to Apple's check server by address; unknown without one.
    static func connect(_ address: String?, on network: LocalNetwork, within seconds: TimeInterval) async -> Reading {
        guard let address else { return .unknown }
        return await open(address, port: 80, on: network, within: seconds, refusalAnswers: false).0
    }

    /// The router's round trip: a ping, or a TCP handshake for routers that ignore pings. A refusal is an answer too.
    public static func reach(_ host: String, on network: LocalNetwork) async -> Reading {
        async let ping = ping(host, interface: network.interface, within: quick)
        async let web = open(host, port: 80, on: network, within: quick, refusalAnswers: true).0
        let first = await ping
        return first.isOK ? first : await web
    }

    // MARK: Name servers

    /// The name servers of the service on `interface`, not the VPN's.
    static func nameServers(of interface: String) -> [String] {
        let store = SCDynamicStoreCreate(nil, "WiFiRefill" as CFString, nil, nil)
        let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] ?? []
        for key in keys {
            guard (SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any])?["InterfaceName"] as? String == interface else { continue }
            let dns = key.replacingOccurrences(of: "/IPv4", with: "/DNS")
            let servers = (SCDynamicStoreCopyValue(store, dns as CFString) as? [String: Any])?["ServerAddresses"] as? [String] ?? []
            return servers.filter { LocalNetwork.ipv4($0) != nil }
        }
        return []
    }

    /// Asks the network's name servers for `name`. `responders` are the servers that answered at all, even with an
    /// error.
    static func resolve(_ name: String, servers: [String], on network: LocalNetwork) async -> (reading: Reading, address: String?, responders: Set<String>) {
        guard !servers.isEmpty else { return (.unknown, nil, []) }
        let id = UInt16.random(in: 1...UInt16.max)
        return await withTaskGroup(of: (reading: Reading, address: String?, server: String?).self) { group in
            for server in servers.prefix(2) {
                group.addTask {
                    let (reading, data) = await open(server, port: 53, datagram: query(name, id: id), on: network, within: patient, refusalAnswers: false)
                    guard reading.isOK, let data, answers(data, id: id) else { return (.broken, nil, nil) }
                    guard let address = address(in: data, id: id) else { return (.broken, nil, server) }
                    return (reading, address, server)
                }
            }
            var result: (reading: Reading, address: String?, responders: Set<String>) = (.broken, nil, [])
            for await answer in group {
                if let server = answer.server { result.responders.insert(server) }
                if answer.reading.isOK, !result.reading.isOK {
                    result.reading = answer.reading
                    result.address = answer.address
                }
            }
            return result
        }
    }

    /// Whether `data` is a response to question `id`, whatever it says.
    static func answers(_ data: Data, id: UInt16) -> Bool {
        let bytes = [UInt8](data.prefix(4))
        return bytes.count == 4 && UInt16(bytes[0]) << 8 | UInt16(bytes[1]) == id && bytes[2] & 0x80 != 0
    }

    /// A DNS question for the IPv4 address of `name`.
    static func query(_ name: String, id: UInt16) -> Data {
        var packet = Data([UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])
        for label in name.split(separator: ".") {
            packet.append(UInt8(label.utf8.count))
            packet.append(contentsOf: label.utf8)
        }
        packet.append(contentsOf: [0, 0, 1, 0, 1])
        return packet
    }

    /// The first IPv4 address in a DNS answer to question `id`, or nil.
    static func address(in answer: Data, id: UInt16) -> String? {
        let bytes = [UInt8](answer)
        guard bytes.count >= 12, UInt16(bytes[0]) << 8 | UInt16(bytes[1]) == id, bytes[3] & 0x0f == 0 else { return nil }
        let questions = Int(bytes[4]) << 8 | Int(bytes[5])
        let answers = Int(bytes[6]) << 8 | Int(bytes[7])
        var at = 12
        func skipName() -> Bool {
            while at < bytes.count {
                let length = Int(bytes[at])
                if length & 0xc0 == 0xc0 { at += 2; return true }
                at += 1
                if length == 0 { return true }
                at += length
            }
            return false
        }
        for _ in 0..<questions {
            guard skipName() else { return nil }
            at += 4
        }
        for _ in 0..<answers {
            guard skipName(), at + 10 <= bytes.count else { return nil }
            let type = Int(bytes[at]) << 8 | Int(bytes[at + 1])
            let length = Int(bytes[at + 8]) << 8 | Int(bytes[at + 9])
            at += 10
            guard at + length <= bytes.count else { return nil }
            if type == 1, length == 4 { return bytes[at..<at + 4].map(String.init).joined(separator: ".") }
            at += length
        }
        return nil
    }

    // MARK: Through a VPN

    /// Apple's check page along the default route, when that is a VPN rather than the Wi-Fi or Ethernet. Only Apple's
    /// own page counts, and redirects are not followed: an intercepted VPN must not pass, nor send Wi-Fi Refill elsewhere.
    public static func throughVPN(_ url: URL = PortalClient.probeURL, under network: LocalNetwork) async -> Reading {
        guard tunnel(over: network) else { return .unknown }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = patient
        configuration.timeoutIntervalForResource = patient
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let start = Date()
        guard let (data, response) = try? await session.data(from: url, delegate: NoRedirects()),
              (response as? HTTPURLResponse)?.statusCode == 200,
              String(decoding: data.prefix(DirectTransport.bodyLimit), as: UTF8.self).contains("<TITLE>Success</TITLE>")
        else { return .broken }
        return .ok(milliseconds: Int(Date().timeIntervalSince(start) * 1000))
    }

    /// Whether a VPN carries all traffic over `network`: the primary service is a tunnel. Another Wi-Fi or Ethernet
    /// service, or an iPhone over USB, is not one.
    public static func tunnel(over network: LocalNetwork) -> Bool {
        let store = SCDynamicStoreCreate(nil, "WiFiRefill" as CFString, nil, nil)
        let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        guard let primary = global?["PrimaryInterface"] as? String, primary != network.interface else { return false }
        return ["utun", "ipsec", "ppp", "tun", "tap"].contains(where: primary.hasPrefix)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    // MARK: Connections

    /// Opens a connection pinned to `network`'s interface and settles on its first answer: a TCP handshake, or the first
    /// datagram back for `datagram`. With `refusalAnswers`, a refused connection counts: the host is there.
    static func open(_ host: String, port: UInt16, datagram: Data? = nil, on network: LocalNetwork, within seconds: TimeInterval, refusalAnswers: Bool) async -> (Reading, Data?) {
        guard let interface = try? await Interfaces.shared.of(network), let port = NWEndpoint.Port(rawValue: port) else { return (.unknown, nil) }
        let parameters: NWParameters = datagram == nil ? .tcp : .udp
        parameters.requiredInterface = interface
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let queue = DispatchQueue(label: "com.hweihwang.WiFiRefill.checkup")
        let start = Date()
        /// Touched on `queue` only.
        final class Once: @unchecked Sendable {
            var continuation: CheckedContinuation<(Reading, Data?), Never>?
            var cancelled = false
            var deadline: DispatchWorkItem?
            func finish(_ connection: NWConnection, _ result: (Reading, Data?)) {
                guard let continuation else { return }
                self.continuation = nil
                deadline?.cancel()
                deadline = nil
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: result)
            }
        }
        let once = Once()
        // The deadline must not keep a finished connection's state alive until it would have fired.
        weak let expiring = once
        let elapsed = { Reading.ok(milliseconds: Int(Date().timeIntervalSince(start) * 1000)) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    // Cancelled before it started: never open the connection.
                    guard !once.cancelled else { return continuation.resume(returning: (.unknown, nil)) }
                    once.continuation = continuation
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            guard let datagram else { return once.finish(connection, (elapsed(), nil)) }
                            connection.send(content: datagram, completion: .idempotent)
                            connection.receiveMessage { data, _, _, error in
                                once.finish(connection, error == nil && data != nil ? (elapsed(), data) : (.broken, nil))
                            }
                        case .waiting(.posix(.ECONNREFUSED)) where refusalAnswers, .failed(.posix(.ECONNREFUSED)) where refusalAnswers:
                            once.finish(connection, (elapsed(), nil))
                        case .failed:
                            once.finish(connection, (.broken, nil))
                        default:
                            break
                        }
                    }
                    let deadline = DispatchWorkItem { expiring?.finish(connection, (.broken, nil)) }
                    once.deadline = deadline
                    queue.asyncAfter(deadline: .now() + seconds, execute: deadline)
                    connection.start(queue: queue)
                }
            }
        } onCancel: {
            queue.async {
                once.cancelled = true
                once.finish(connection, (.unknown, nil))
            }
        }
    }

    /// An ICMP echo on `interface`. Needs no privileges: macOS allows datagram ICMP sockets.
    public static func ping(_ host: String, interface: String, within seconds: TimeInterval) async -> Reading {
        let stop = Flag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { continuation.resume(returning: pingNow(host, interface: interface, within: seconds, stop: stop)) }
            }
        } onCancel: {
            stop.set()
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func set() { lock.withLock { raised = true } }
        var isSet: Bool { lock.withLock { raised } }
    }

    private static func pingNow(_ host: String, interface: String, within seconds: TimeInterval, stop: Flag) -> Reading {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return .unknown }
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard socket >= 0 else { return .unknown }
        defer { close(socket) }
        var index = if_nametoindex(interface)
        setsockopt(socket, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))

        let id = UInt16.random(in: 1...UInt16.max)
        var packet: [UInt8] = [8, 0, 0, 0, UInt8(id >> 8), UInt8(id & 0xff), 0, 1] + Array("refill".utf8)
        var sum: UInt32 = 0
        for i in stride(from: 0, to: packet.count, by: 2) {
            sum += UInt32(packet[i]) << 8 | UInt32(i + 1 < packet.count ? packet[i + 1] : 0)
        }
        while sum > 0xffff { sum = (sum & 0xffff) + (sum >> 16) }
        let checksum = ~UInt16(sum)
        packet[2] = UInt8(checksum >> 8)
        packet[3] = UInt8(checksum & 0xff)

        let start = Date()
        let sent = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socket, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard sent == packet.count else { return .broken }
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            guard !stop.isSet else { return .unknown }
            let left = seconds - Date().timeIntervalSince(start)
            guard left > 0 else { return .broken }
            // Wakes at least every 100 ms to notice cancellation.
            var poller = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(left, 0.1) * 1000))
            guard ready >= 0 else { return .broken }
            if ready == 0 { continue }
            let count = recv(socket, &buffer, buffer.count, 0)
            guard count > 0 else { return .broken }
            // Replies arrive with their IP header.
            let header = Int(buffer[0] & 0x0f) * 4
            guard count >= header + 8 else { continue }
            if buffer[header] == 0, UInt16(buffer[header + 4]) << 8 | UInt16(buffer[header + 5]) == id {
                return .ok(milliseconds: Int(Date().timeIntervalSince(start) * 1000))
            }
        }
    }

    /// Whether `interface` has a global IPv6 address, as on a network with IPv6 alone.
    static func hasGlobalIPv6(_ interface: String) -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        return sequence(first: first, next: { $0.pointee.ifa_next }).contains { entry in
            guard String(cString: entry.pointee.ifa_name) == interface, let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET6) else { return false }
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr.__u6_addr.__u6_addr8.0 & 0xe0 == 0x20 }
        }
    }

    /// Whether an IPv4 address is on the public internet, rather than a private, shared or reserved range a login
    /// page's name server might answer with.
    static func isPublic(_ address: String) -> Bool {
        guard let value = LocalNetwork.ipv4(address) else { return false }
        let reserved: [(UInt32, UInt32)] = [(0x0000_0000, 8), (0x0A00_0000, 8), (0x6440_0000, 10), (0x7F00_0000, 8), (0xA9FE_0000, 16),
                                            (0xAC10_0000, 12), (0xC000_0000, 24), (0xC000_0200, 24), (0xC058_6300, 24), (0xC0A8_0000, 16), (0xC612_0000, 15),
                                            (0xC633_6400, 24), (0xCB00_7100, 24), (0xE000_0000, 3)]
        return !reserved.contains { network, bits in value >> (32 - bits) == network >> (32 - bits) }
    }

    /// `work`'s result, or nil once `seconds` pass.
    static func within<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
