import Foundation
import SystemConfiguration

/// The Wi-Fi or Ethernet network the Mac is on: its interface, its router, and the Mac's own address and subnet mask.
public struct LocalNetwork: Sendable, Equatable {
    /// The interface's BSD name, such as en0.
    public var interface: String
    public var router: String
    public var address: String
    public var mask: String
    /// macOS's name for this network: the router's address and hardware address. Tells two cafes apart even when
    /// their routers share an address.
    public var signature: String?

    public init(interface: String, router: String, address: String, mask: String, signature: String? = nil) {
        self.interface = interface
        self.router = router
        self.address = address
        self.mask = mask
        self.signature = signature
    }

    /// Whether `host` is an IPv4 address on this network. Host names never are.
    public func contains(_ host: String) -> Bool {
        guard let host = Self.ipv4(host), let address = Self.ipv4(address), let mask = Self.ipv4(mask) else { return false }
        return host & mask == address & mask
    }

    static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ (1...3).contains($0.count) && $0.allSatisfy { ("0"..."9").contains($0) } }) else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes.reduce(0) { $0 << 8 | UInt32($1) } : nil
    }
}

public enum Gateway {
    /// The network macOS uses right now. Needs no Location permission, unlike the Wi-Fi name.
    public static func current() -> LocalNetwork? {
        let store = SCDynamicStoreCreate(nil, "WiFiRefill" as CFString, nil, nil)
        let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any]
        let order = [global?["PrimaryService"] as? String].compactMap { $0 } + (setup?["ServiceOrder"] as? [String] ?? [])
        let hardware = (SCNetworkInterfaceCopyAll() as NSArray as? [SCNetworkInterface] ?? []).filter {
            [kSCNetworkInterfaceTypeIEEE80211 as String, kSCNetworkInterfaceTypeEthernet as String].contains(SCNetworkInterfaceGetInterfaceType($0) as String?)
        }
        return pick(
            from: order.map { id in SCDynamicStoreCopyValue(store, "State:/Network/Service/\(id)/IPv4" as CFString) as? [String: Any] ?? [:] },
            wifiOrEthernet: Set(hardware.compactMap { SCNetworkInterfaceGetBSDName($0) as String? })
        )
    }

    /// The first service in macOS's order on Wi-Fi or Ethernet. A VPN that carries all traffic, such as Tailscale with an
    /// exit node, becomes the primary service, but the login page belongs to the Wi-Fi underneath.
    static func pick(from services: [[String: Any]], wifiOrEthernet: Set<String>) -> LocalNetwork? {
        for ipv4 in services {
            guard let interface = ipv4["InterfaceName"] as? String, wifiOrEthernet.contains(interface),
                  let router = ipv4["Router"] as? String,
                  let address = (ipv4["Addresses"] as? [String])?.first,
                  let mask = (ipv4["SubnetMasks"] as? [String])?.first
            else { continue }
            return LocalNetwork(interface: interface, router: router, address: address, mask: mask, signature: ipv4["NetworkSignature"] as? String)
        }
        return nil
    }
}
