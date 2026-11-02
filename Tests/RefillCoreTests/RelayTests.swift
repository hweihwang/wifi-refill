import Foundation
import Network
import Testing
@testable import RefillCore

struct RelayPolicyTests {
    let network = AwingFixture.network

    @Test(arguments: [
        ("10.29.64.2", true), ("10.29.64.1", true), ("8.8.8.8", true), ("17.253.61.141", true),
        ("10.29.64.96", false), ("10.29.64.0", false), ("10.29.67.255", false), ("10.29.68.1", false), ("192.168.1.1", false),
        ("172.16.5.4", false), ("127.0.0.1", false), ("169.254.1.1", false), ("100.100.100.100", false), ("224.0.0.251", false),
        ("255.255.255.255", false), ("0.0.0.0", false),
        ("2606:4700::1", true), ("::ffff:10.29.64.2", true), ("::ffff:192.168.1.1", false), ("fe80::1", false), ("fd00::1", false),
        ("::1", false), ("ff02::1", false),
    ])
    func sendsThePageOnlyToTheInternetAndTheWiFi(address: String, allowed: Bool) {
        #expect(WiFiRelay.allows(NWEndpoint.Host(address), on: network, own: []) == allowed)
    }

    @Test func neverReachesTheMacItself() {
        let own = IPv6Address("2001:db8::5")!
        #expect(!WiFiRelay.allows(.ipv6(own), on: network, own: [own.rawValue]))
        #expect(WiFiRelay.allows(.ipv6(IPv6Address("2001:db8::6")!), on: network, own: [own.rawValue]))
    }

    /// However wide a network says it is, loopback, link-local and multicast stay out of reach.
    @Test func keepsTheUnreachableOutOfAWideSubnet() {
        let wide = LocalNetwork(interface: "en0", router: "10.0.0.1", address: "10.0.0.2", mask: "0.0.0.0")
        for address in ["127.0.0.1", "169.254.1.1", "224.0.0.251", "8.8.8.8"] {
            #expect(WiFiRelay.allows(NWEndpoint.Host(address), on: wide, own: []) == (address == "8.8.8.8"))
        }
    }
}

/// The relay run on loopback, with a local echo server standing in for the cafe.
@Suite(.serialized) struct RelayProtocolTests {
    let network = LocalNetwork(interface: "lo0", router: "127.0.0.1", address: "127.0.0.2", mask: "255.0.0.0")

    final class Socket: @unchecked Sendable {
        let connection: NWConnection

        init(port: UInt16, host: String = "127.0.0.1") async throws {
            connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { [connection] state in
                    switch state {
                    case .ready: connection.stateUpdateHandler = nil; continuation.resume()
                    case .failed(let error), .waiting(let error): connection.stateUpdateHandler = nil; continuation.resume(throwing: error)
                    default: break
                    }
                }
                connection.start(queue: .global())
            }
        }

        func write(_ bytes: [UInt8]) {
            connection.send(content: Data(bytes), completion: .idempotent)
        }

        /// `count` bytes, or fewer when the relay closes the connection.
        func read(_ count: Int) async -> [UInt8] {
            await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in
                    continuation.resume(returning: data.map([UInt8].init) ?? [])
                }
            }
        }

        deinit { connection.cancel() }
    }

    func loopback() async -> NWInterface {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor(requiredInterfaceType: .loopback)
            monitor.pathUpdateHandler = { path in
                guard let interface = path.availableInterfaces.first else { return }
                monitor.cancel()
                continuation.resume(returning: interface)
            }
            monitor.start(queue: DispatchQueue(label: "loopback"))
        }
    }

    /// The real address rule unless `anywhere`, which lets the local echo server stand in for the cafe.
    func relay(anywhere: Bool = false, onNetwork: Bool = true) async throws -> WiFiRelay {
        var everywhere: (@Sendable (NWEndpoint.Host) -> Bool)?
        if anywhere { everywhere = { _ in true } }
        let stays: @Sendable () -> Bool = { onNetwork }
        let interface = await loopback()
        let relay = try WiFiRelay(network: network, interface: interface, allows: everywhere, onNetwork: stays)
        try await relay.listen()
        return relay
    }

    /// Echoes whatever it receives, on 127.0.0.1.
    func echoServer() async throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            func echo() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, done, _ in
                    if let data { connection.send(content: data, completion: .idempotent) }
                    if !done { echo() }
                }
            }
            connection.start(queue: .global())
            echo()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state { listener.stateUpdateHandler = nil; continuation.resume() }
            }
            listener.start(queue: .global())
        }
        return listener
    }

    /// Greets and logs in; returns the socket ready for a request.
    func greeted(_ relay: WiFiRelay, password: String? = nil) async throws -> (Socket, [UInt8]) {
        let socket = try await Socket(port: relay.port)
        socket.write([5, 1, 2])
        #expect(await socket.read(2) == [5, 2])
        let user = Array(relay.username.utf8), pass = Array((password ?? relay.password).utf8)
        socket.write([1, UInt8(user.count)] + user + [UInt8(pass.count)] + pass)
        return (socket, await socket.read(2))
    }

    func connect(_ socket: Socket, ipv4: [UInt8], port: UInt16) async -> [UInt8] {
        socket.write([5, 1, 0, 1] + ipv4 + [UInt8(port >> 8), UInt8(port & 0xFF)])
        return await socket.read(10)
    }

    @Test func relaysAClientThatHoldsTheCredential() async throws {
        let echo = try await echoServer()
        defer { echo.cancel() }
        let relay = try await relay(anywhere: true)
        defer { relay.stop() }
        let (socket, login) = try await greeted(relay)
        #expect(login == [1, 0])
        #expect(await connect(socket, ipv4: [127, 0, 0, 1], port: echo.port!.rawValue).prefix(2) == [5, 0])
        socket.write(Array("hello".utf8))
        #expect(await socket.read(5) == Array("hello".utf8))
    }

    /// A client that has sent everything and closed its side still gets the answer.
    @Test func deliversTheAnswerAfterTheClientFinishesSending() async throws {
        let echo = try await echoServer()
        defer { echo.cancel() }
        let relay = try await relay(anywhere: true)
        defer { relay.stop() }
        let (socket, _) = try await greeted(relay)
        #expect(await connect(socket, ipv4: [127, 0, 0, 1], port: echo.port!.rawValue).prefix(2) == [5, 0])
        socket.connection.send(content: Data("hello".utf8), contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        #expect(await socket.read(5) == Array("hello".utf8))
    }

    @Test func stopsOnceTheMacIsOnAnotherNetwork() async throws {
        let relay = try await relay(onNetwork: false)
        let socket = try await Socket(port: relay.port)
        socket.write([5, 1, 2])
        #expect(await socket.read(2).isEmpty, "the relay hangs up without a word")
    }

    @Test func refusesAWrongPassword() async throws {
        let relay = try await relay()
        defer { relay.stop() }
        let (socket, login) = try await greeted(relay, password: "guess")
        #expect(login == [1, 1])
        #expect(await socket.read(1).isEmpty, "the relay hangs up")
    }

    @Test func refusesClientsWithoutTheCredential() async throws {
        let relay = try await relay()
        defer { relay.stop() }
        let socket = try await Socket(port: relay.port)
        socket.write([5, 1, 0])
        #expect(await socket.read(2) == [5, 0xFF])
    }

    @Test func refusesCommandsOtherThanConnect() async throws {
        let relay = try await relay()
        defer { relay.stop() }
        let (socket, _) = try await greeted(relay)
        socket.write([5, 2, 0, 1, 127, 0, 0, 1, 0, 80])
        #expect(await socket.read(2) == [5, 7])
    }

    @Test func refusesTheMacAndOtherNetworks() async throws {
        let relay = try await relay()
        defer { relay.stop() }
        for address: [UInt8] in [[127, 0, 0, 2], [10, 0, 0, 1], [192, 168, 1, 1]] {
            let (socket, _) = try await greeted(relay)
            #expect(await connect(socket, ipv4: address, port: 80).prefix(2) == [5, 2])
        }
    }

    /// A name is checked once it resolves, before any of the page's bytes go through.
    @Test func refusesANameThatResolvesOutsideTheWiFi() async throws {
        let echo = try await echoServer()
        defer { echo.cancel() }
        let relay = try await relay()
        defer { relay.stop() }
        let (socket, _) = try await greeted(relay)
        let name = Array("localhost".utf8), port = echo.port!.rawValue
        socket.write([5, 1, 0, 3, UInt8(name.count)] + name + [UInt8(port >> 8), UInt8(port & 0xFF)])
        #expect(await socket.read(10).prefix(2) == [5, 2])
    }
}
