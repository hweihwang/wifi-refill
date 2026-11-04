import Foundation

/// The stretches between this Mac and the internet, in the order a request crosses them.
public enum Leg: String, CaseIterable, Sendable {
    /// The radio link from the Mac to the access point.
    case wifi
    /// The access point to the router.
    case router
    /// A login page holding the network.
    case loginPage
    /// The network's name server.
    case dns
    /// The router's line to the internet.
    case internet
    /// A VPN that carries all traffic.
    case vpn
}

public enum Reading: Sendable, Equatable {
    case ok(milliseconds: Int?)
    case broken
    /// Nothing to look at, such as no VPN, or the check could not tell.
    case unknown

    public var isOK: Bool { if case .ok = self { true } else { false } }
}

/// What one look at every leg found.
public struct Observations: Sendable, Equatable {
    public var wifi: Reading
    public var router: Reading
    public var dns: Reading
    /// A connection to Apple's check server by its address, so it needs no name server.
    public var internet: Reading
    /// Apple's check page over the Wi-Fi itself; nil when it did not answer in time.
    public var probe: ProbeResult?
    /// Apple's check page through a VPN that carries all traffic; unknown without one.
    public var vpn: Reading

    public init(wifi: Reading = .unknown, router: Reading = .unknown, dns: Reading = .unknown, internet: Reading = .unknown, probe: ProbeResult? = nil, vpn: Reading = .unknown) {
        self.wifi = wifi
        self.router = router
        self.dns = dns
        self.internet = internet
        self.probe = probe
        self.vpn = vpn
    }
}

public struct Diagnosis: Sendable, Equatable {
    public var observations: Observations
    public var milliseconds: Int

    public init(observations: Observations, milliseconds: Int) {
        self.observations = observations
        self.milliseconds = milliseconds
    }

    public var broken: Leg? { Self.blame(observations) }

    /// The leg to blame: the first broken one along the path that nothing further along contradicts, or nil when
    /// nothing is broken or the evidence doesn't say. A router that ignores the check while the internet answers
    /// through it is fine; a name server that times out while the line is down is not the problem.
    public static func blame(_ seen: Observations) -> Leg? {
        // Apple's check page over the Wi-Fi outweighs every other reading.
        switch seen.probe {
        case .online: return seen.vpn == .broken ? .vpn : nil
        case .portal: return .loginPage
        case .offline, nil: break
        }
        if seen.wifi == .broken { return .wifi }
        if seen.router == .broken, !seen.dns.isOK, !seen.internet.isOK { return .router }
        if seen.internet == .broken { return .internet }
        if seen.dns == .broken, seen.internet.isOK { return .dns }
        // Every leg answers, yet the check page does not: the line is too slow or lets nothing through to the web.
        if seen.router.isOK, seen.dns.isOK, seen.internet.isOK { return .internet }
        return nil
    }
}
