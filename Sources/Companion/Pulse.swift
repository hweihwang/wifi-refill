import Foundation
import RefillCore

/// What the menu bar cup shows, read from the Mac every second.
public struct Pulse: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case online
        case loggingIn
        /// The leg that stopped the Mac reaching the internet.
        case broken(Leg)
        /// On a network, but without the internet, and the legs don't say why.
        case noInternet
        /// Wi-Fi Refill isn't checking, so it doesn't say how the network is.
        case paused
        case offline
    }

    public var state: State
    /// 0 without a link, then 1 to 3.
    public var bars: Int
    /// Bytes per second over the Wi-Fi or Ethernet.
    public var received: Double
    public var sent: Double

    public init(state: State = .online, bars: Int = 3, received: Double = 0, sent: Double = 0) {
        self.state = state
        self.bars = bars
        self.received = received
        self.sent = sent
    }

    /// 0 when idle, 1 around 10 MB/s and above, on a log scale: a page load shows, a download shows more.
    public var busy: Double {
        let bytes = received + sent
        guard bytes > 2_000 else { return 0 }
        return min(1, log10(bytes / 2_000) / log10(5_000))
    }

    public var isUp: Bool { if case .online = state { true } else { false } }
}
