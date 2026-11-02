import Foundation
import Network

/// A SOCKS5 relay on loopback for the web view that runs a login page. Each connection goes out on the Wi-Fi or
/// Ethernet of the check's network, so a VPN cannot hide the page, and only to the internet or that network's own
/// subnet: never to the Mac itself, loopback, link-local, multicast or other private networks. Only a client with this
/// relay's one-time credential gets through; the web view's proxy settings hold it.
public final class WiFiRelay: @unchecked Sendable {
    public let username = UUID().uuidString
    public let password = UUID().uuidString
    public private(set) var port: UInt16 = 0

    static let maxConnections = 64
    /// Enough for a page and a video advert; a page that streams more is cut off.
    static let maxBytes = 64 * 1024 * 1024
    /// From accepting a connection to relaying it: greeting, login, request and connecting.
    static let setupDeadline: TimeInterval = 15

    private let network: LocalNetwork
    private let interface: NWInterface
    private let allows: @Sendable (NWEndpoint.Host) -> Bool
    private let onNetwork: @Sendable () -> Bool
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.hweihwang.WiFiRefill.relay")
    // Touched on `queue` only.
    private var open: [ObjectIdentifier: NWConnection] = [:]
    private var relaying: Set<ObjectIdentifier> = []
    private var bytes = 0
    private var stopped = false

    /// A running relay for `network`. Stop it when the page is done.
    public static func start(on network: LocalNetwork) async throws -> WiFiRelay {
        let relay = try WiFiRelay(network: network, interface: try await Interfaces.shared.of(network))
        try await relay.listen()
        return relay
    }

    /// `allows` and `onNetwork` stand in for the address rule and the network check in tests.
    init(network: LocalNetwork, interface: NWInterface, allows: (@Sendable (NWEndpoint.Host) -> Bool)? = nil, onNetwork: (@Sendable () -> Bool)? = nil) throws {
        self.network = network
        self.interface = interface
        let own = Self.ownAddresses()
        self.allows = allows ?? { Self.allows($0, on: network, own: own) }
        self.onNetwork = onNetwork ?? { Gateway.current() == network }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func listen() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [unowned self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    port = listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] client in self?.accept(client) }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.async { [self] in
            stopped = true
            listener.newConnectionHandler = nil
            listener.cancel()
            open.values.forEach { $0.cancel() }
            open = [:]
        }
    }

    // MARK: SOCKS5 (RFC 1928) with username and password (RFC 1929), CONNECT only

    private func accept(_ client: NWConnection) {
        guard !stopped, open.count < Self.maxConnections else { return client.cancel() }
        // The page belongs to the network it was opened on: once the Mac is elsewhere, nothing more goes through.
        guard onNetwork() else {
            client.cancel()
            return stop()
        }
        track(client)
        queue.asyncAfter(deadline: .now() + Self.setupDeadline) { [weak self, weak client] in
            guard let self, let client, !self.relaying.contains(ObjectIdentifier(client)) else { return }
            self.close(client)
        }
        client.start(queue: queue)
        read(client, 2) { [self] head in
            guard head[0] == 5, head[1] > 0 else { return close(client) }
            read(client, Int(head[1])) { [self] methods in
                guard methods.contains(2) else { return send(client, [5, 0xFF], thenClose: true) }
                send(client, [5, 2])
                authenticate(client)
            }
        }
    }

    private func authenticate(_ client: NWConnection) {
        read(client, 2) { [self] head in
            guard head[0] == 1, head[1] > 0 else { return close(client) }
            read(client, Int(head[1])) { [self] user in
                read(client, 1) { [self] length in
                    guard length[0] > 0 else { return send(client, [1, 1], thenClose: true) }
                    read(client, Int(length[0])) { [self] pass in
                        guard user == Array(username.utf8), pass == Array(password.utf8) else { return send(client, [1, 1], thenClose: true) }
                        send(client, [1, 0])
                        request(client)
                    }
                }
            }
        }
    }

    private func request(_ client: NWConnection) {
        read(client, 4) { [self] head in
            guard head[0] == 5 else { return close(client) }
            guard head[1] == 1 else { return reply(client, 7) }
            let withHost: (@escaping (NWEndpoint.Host) -> Void) -> Void
            switch head[3] {
            case 1: withHost = { [self] next in read(client, 4) { next(.ipv4(IPv4Address(Data($0))!)) } }
            case 4: withHost = { [self] next in read(client, 16) { next(.ipv6(IPv6Address(Data($0))!)) } }
            case 3:
                withHost = { [self] next in
                    read(client, 1) { [self] length in
                        guard length[0] > 0 else { return close(client) }
                        read(client, Int(length[0])) { next(NWEndpoint.Host(String(decoding: $0, as: UTF8.self))) }
                    }
                }
            default: return reply(client, 8)
            }
            withHost { [self] host in
                read(client, 2) { [self] bytes in
                    guard let port = NWEndpoint.Port(rawValue: UInt16(bytes[0]) << 8 | UInt16(bytes[1])), port.rawValue != 0 else { return reply(client, 2) }
                    connect(client, to: host, port: port)
                }
            }
        }
    }

    private func connect(_ client: NWConnection, to host: NWEndpoint.Host, port: NWEndpoint.Port) {
        // An address is checked before connecting; a name once it resolves, before a byte of the page goes through.
        if case .name = host {} else if !allows(host) { return reply(client, 2) }
        let parameters = NWParameters.tcp
        parameters.requiredInterface = interface
        let remote = NWConnection(host: host, port: port, using: parameters)
        track(remote)
        remote.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                remote.stateUpdateHandler = nil
                guard case .hostPort(let address, _) = remote.currentPath?.remoteEndpoint, allows(address) else {
                    close(remote)
                    return reply(client, 2)
                }
                send(client, [5, 0, 0, 1, 0, 0, 0, 0, 0, 0])
                relaying.insert(ObjectIdentifier(client))
                let pair = Pair(client, remote)
                pipe(client, to: remote, pair)
                pipe(remote, to: client, pair)
            case .waiting, .failed:
                remote.stateUpdateHandler = nil
                close(remote)
                reply(client, 4)
            default:
                break
            }
        }
        remote.start(queue: queue)
    }

    /// Both directions of one relayed connection. Each ends on its own; the connections close when both have.
    private final class Pair {
        let a: NWConnection, b: NWConnection
        var ended = 0
        init(_ a: NWConnection, _ b: NWConnection) { self.a = a; self.b = b }
    }

    /// Reads the next chunk only once the last one is sent, so a slow side never piles data up in the relay.
    private func pipe(_ from: NWConnection, to: NWConnection, _ pair: Pair) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
            if error != nil { return end(pair) }
            let chunk = data ?? Data()
            bytes += chunk.count
            guard bytes <= Self.maxBytes else { return stop() }
            to.send(content: chunk.isEmpty ? nil : chunk, contentContext: complete ? .finalMessage : .defaultMessage, isComplete: complete, completion: .contentProcessed { [self] sendError in
                if sendError != nil { return end(pair) }
                if complete {
                    pair.ended += 1
                    if pair.ended == 2 { end(pair) }
                } else {
                    pipe(from, to: to, pair)
                }
            })
        }
    }

    private func end(_ pair: Pair) {
        relaying.remove(ObjectIdentifier(pair.a))
        close(pair.a)
        close(pair.b)
    }

    // MARK: Helpers, all on `queue`

    private func read(_ connection: NWConnection, _ count: Int, then: @escaping ([UInt8]) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [self] data, _, _, error in
            guard error == nil, let data, data.count == count else { return close(connection) }
            then([UInt8](data))
        }
    }

    private func send(_ connection: NWConnection, _ bytes: [UInt8], thenClose: Bool = false) {
        connection.send(content: Data(bytes), completion: .contentProcessed { [self] _ in if thenClose { close(connection) } })
    }

    private func reply(_ client: NWConnection, _ code: UInt8) {
        send(client, [5, code, 0, 1, 0, 0, 0, 0, 0, 0], thenClose: true)
    }

    private func track(_ connection: NWConnection) {
        open[ObjectIdentifier(connection)] = connection
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        open[ObjectIdentifier(connection)] = nil
        relaying.remove(ObjectIdentifier(connection))
    }

    // MARK: Where the page may go

    /// The internet and the Wi-Fi's own subnet. Never the Mac itself, loopback, link-local, multicast or broadcast,
    /// whatever the subnet; never another private network.
    static func allows(_ host: NWEndpoint.Host, on network: LocalNetwork, own: Set<Data>) -> Bool {
        switch host {
        case .ipv4(let address):
            return !own.contains(address.rawValue) && allows(ipv4: address.rawValue.reduce(0) { $0 << 8 | UInt32($1) }, on: network)
        case .ipv6(let address):
            if let mapped = address.asIPv4 { return allows(.ipv4(mapped), on: network, own: own) }
            // Global unicast only (2000::/3): not link-local, unique local or multicast.
            return !own.contains(address.rawValue) && (address.rawValue.first.map { $0 & 0xE0 == 0x20 } ?? false)
        default:
            return false
        }
    }

    static func allows(ipv4 address: UInt32, on network: LocalNetwork) -> Bool {
        func within(_ prefix: UInt32, _ bits: UInt32) -> Bool { address >> (32 - bits) == prefix >> (32 - bits) }
        let never: [(UInt32, UInt32)] = [(0x0000_0000, 8), (0x7F00_0000, 8), (0xA9FE_0000, 16), (0xE000_0000, 4), (0xF000_0000, 4)]
        guard !never.contains(where: within) else { return false }
        if let own = LocalNetwork.ipv4(network.address), let mask = LocalNetwork.ipv4(network.mask),
           mask.leadingZeroBitCount == 0, mask.nonzeroBitCount >= 8, (~mask).nonzeroBitCount == mask.trailingZeroBitCount,
           address & mask == own & mask {
            // The Wi-Fi's own devices, such as its router or login controller; not its network or broadcast address.
            let host = address & ~mask
            return address != own && host != 0 && host != ~mask
        }
        let otherPrivate: [(UInt32, UInt32)] = [(0x0A00_0000, 8), (0x6440_0000, 10), (0xAC10_0000, 12), (0xC000_0000, 24), (0xC0A8_0000, 16), (0xC612_0000, 15)]
        return !otherPrivate.contains(where: within)
    }

    /// Every address of every interface of this Mac, so a page cannot reach the Mac's own services through the relay.
    static func ownAddresses() -> Set<Data> {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var addresses: Set<Data> = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { var raw = $0.pointee.sin_addr; addresses.insert(Data(bytes: &raw, count: 4)) }
            case AF_INET6:
                address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { var raw = $0.pointee.sin6_addr; addresses.insert(Data(bytes: &raw, count: 16)) }
            default:
                break
            }
        }
        return addresses
    }
}
