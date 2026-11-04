import CoreWLAN
import Darwin

/// The Wi-Fi link as the radio sees it. Needs no Location permission: macOS hides only the network's name and the
/// access point's address without it.
public struct Vitals: Sendable, Equatable {
    /// Signal and noise in dBm.
    public var rssi: Int
    public var noise: Int
    /// The rate the Mac last sent at, in Mbit/s.
    public var rate: Double
    public var channel: Int
    /// 2, 5 or 6 GHz; 0 when macOS does not say.
    public var gigahertz: Int

    public init(rssi: Int, noise: Int, rate: Double, channel: Int, gigahertz: Int) {
        self.rssi = rssi
        self.noise = noise
        self.rate = rate
        self.channel = channel
        self.gigahertz = gigahertz
    }

    /// How far the signal stands above the noise, which decides what the link can carry.
    public var margin: Int { rssi - noise }

    /// 1 to 3, like the bars of the Wi-Fi icon. 35 dB and up carries anything; under 20 dB pages stall.
    public var bars: Int { margin >= 35 ? 3 : margin >= 20 ? 2 : 1 }

    /// The radio's link: broken while Wi-Fi is off or joined to no network, unknown on a Mac without Wi-Fi.
    public static func radio() -> Reading {
        guard let wifi = CWWiFiClient.shared().interface() else { return .unknown }
        return wifi.powerOn() && wifi.wlanChannel() != nil ? .ok(milliseconds: nil) : .broken
    }

    /// The Wi-Fi interface's link, or nil while Wi-Fi is off, not joined, or the radio could not measure it
    /// (macOS reports 0 dBm then).
    public static func read() -> Vitals? {
        guard let wifi = CWWiFiClient.shared().interface(), wifi.powerOn(), let channel = wifi.wlanChannel() else { return nil }
        let rssi = wifi.rssiValue()
        guard rssi != 0 else { return nil }
        let gigahertz = switch channel.channelBand {
        case .band2GHz: 2
        case .band5GHz: 5
        case .band6GHz: 6
        default: 0
        }
        return Vitals(rssi: rssi, noise: wifi.noiseMeasurement(), rate: wifi.transmitRate(), channel: channel.channelNumber, gigahertz: gigahertz)
    }

    /// The BSD name of the Wi-Fi interface, such as en0.
    public static var interface: String? { CWWiFiClient.shared().interface()?.interfaceName }
}

/// Bytes an interface has moved, read from the kernel's counters. Asks nothing of the network.
public struct Traffic: Sendable, Equatable {
    public var received: UInt32
    public var sent: UInt32
    public var packetsIn: UInt32
    public var packetsOut: UInt32

    public init(received: UInt32, sent: UInt32, packetsIn: UInt32 = 0, packetsOut: UInt32 = 0) {
        self.received = received
        self.sent = sent
        self.packetsIn = packetsIn
        self.packetsOut = packetsOut
    }

    public static func read(_ interface: String) -> Traffic? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            guard item.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), String(cString: item.ifa_name) == interface,
                  let data = item.ifa_data?.assumingMemoryBound(to: if_data.self).pointee
            else { continue }
            return Traffic(received: data.ifi_ibytes, sent: data.ifi_obytes, packetsIn: data.ifi_ipackets, packetsOut: data.ifi_opackets)
        }
        return nil
    }

    /// Whether the Mac kept sending while almost nothing came back, as when the internet stops behind a working
    /// Wi-Fi: apps retry and nothing answers. Idle networks send little; working ones answer with as many packets as
    /// they get, or at worst one for every two an upload sends.
    public static func stalled(from old: Traffic, to new: Traffic) -> Bool {
        let out = new.packetsOut &- old.packetsOut
        let back = new.packetsIn &- old.packetsIn
        return out >= 12 && back * 4 < out
    }

    /// Bytes per second between two readings. The counters are 32 bits and wrap; between readings seconds apart
    /// they wrap at most once.
    public static func rate(from old: Traffic, to new: Traffic, seconds: Double) -> (received: Double, sent: Double) {
        guard seconds > 0 else { return (0, 0) }
        return (Double(new.received &- old.received) / seconds, Double(new.sent &- old.sent) / seconds)
    }
}
