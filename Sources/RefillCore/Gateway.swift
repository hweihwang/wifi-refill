import Foundation
import SystemConfiguration

public enum Gateway {
    /// The router of the network macOS uses right now. Needs no Location permission, unlike the Wi-Fi name.
    public static func current() -> String? {
        let ipv4 = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        return ipv4?["Router"] as? String
    }
}
