import Foundation
import Network

/// Network.framework's handle for a network's interface, which a connection needs to be pinned to it.
final class Interfaces: @unchecked Sendable {
    static let shared = Interfaces()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var available: [NWInterface] = []

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.withLock { self?.available = path.availableInterfaces }
        }
        monitor.start(queue: DispatchQueue(label: "com.hweihwang.WiFiRefill.interfaces"))
    }

    /// The interface of `network`, while the Mac is still on it. Network.framework lists interfaces a moment after it
    /// starts.
    func of(_ network: LocalNetwork) async throws -> NWInterface {
        for _ in 0..<20 {
            guard Gateway.current() == network else { throw URLError(.networkConnectionLost) }
            if let interface = lock.withLock({ available.first { $0.name == network.interface } }) { return interface }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw URLError(.notConnectedToInternet)
    }
}
