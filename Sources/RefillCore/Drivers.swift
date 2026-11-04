import Foundation

/// A login page that is ready for the button to be pressed.
public struct PortalSession: Sendable, Equatable {
    /// Stays the same for one cafe's login page across visits, so consent and settings can be remembered.
    public var profile: String
    /// The Wi-Fi name the login page reported, or a plain fallback.
    public var network: String
    /// The router address the login page named.
    public var router: String
    /// How long a login lasts, if the login page says.
    public var minutes: Int?
    /// Driver-specific values for the login step.
    public var details: [String: String]

    public init(profile: String, network: String, router: String, minutes: Int?, details: [String: String]) {
        self.profile = profile
        self.network = network
        self.router = router
        self.minutes = minutes
        self.details = details
    }
}

public enum LoginError: Error, Equatable, CustomStringConvertible {
    /// A kind of login page Wi-Fi Refill has not been checked against.
    case unsupported(String)
    /// The login page said no.
    case refused(String)
    /// The login page did something Wi-Fi Refill does not expect.
    case unexpected(String)

    public var description: String {
        switch self {
        case .unsupported(let reason), .refused(let reason), .unexpected(let reason): reason
        }
    }
}

/// Knows one kind of login page. Add a driver only after checking it on a real network, with that network's recorded
/// answers as a test (see CONTRIBUTING.md).
public protocol PortalDriver {
    /// Where this driver's login flow starts in the probe's answer, or nil when the page is not its kind.
    static func entry(in probe: [Hop]) -> URL?
    /// Walks the login page up to its button, without pressing it. `network` is the network the Mac is on now.
    static func prepare(from entry: URL, on network: LocalNetwork, client: PortalClient) async throws -> PortalSession
    /// Does what the login button does.
    static func login(_ session: PortalSession, client: PortalClient) async throws
}

public enum Drivers {
    public static let all: [any PortalDriver.Type] = [RuijieCloud.self, AwingExtreme.self, MikroTikHotspot.self, UniFiGuestPortal.self]

    public static func recognize(_ probe: [Hop]) -> (driver: any PortalDriver.Type, entry: URL)? {
        for driver in all {
            if let entry = driver.entry(in: probe) { return (driver, entry) }
        }
        return nil
    }
}
