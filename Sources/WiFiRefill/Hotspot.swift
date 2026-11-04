import AppKit
import CoreWLAN

/// The person's iPhones nearby that can share their mobile data, as the Wi-Fi menu lists them under Personal Hotspot.
///
/// Apple offers no public way to this. It goes through Sharing, a private framework, whose service serves apps without
/// Apple's entitlement as of macOS 27.3 (it logs "serving anyway"). Joining turns the iPhone's hotspot on over
/// Bluetooth, which answers with the hotspot's name and password, then joins that network. Without Location access
/// macOS leaves network names out of a scan, so the name the iPhone sent goes back into the network the scan found.
@MainActor
final class Hotspot: NSObject {
    struct Phone {
        var name: String
        var battery: Int?
        fileprivate var device: NSObject
    }

    /// Switching takes a few seconds after the Wi-Fi breaks, so a blip doesn't move the Mac onto mobile data.
    static let patience: TimeInterval = 20
    /// macOS may move back to a known Wi-Fi by itself; switching again so soon would bounce between the two.
    static let cooldown: TimeInterval = 10 * 60

    private(set) var phones: [Phone] = []
    /// The phone being joined right now.
    private(set) var joining: String?
    /// The Mac is on a hotspot Wi-Fi Refill joined, until it is on an unmetered network again.
    private(set) var joined = false
    var onFailure: (String) -> Void = { _ in }

    /// Switch to the first phone found once the Wi-Fi has been broken for `patience`.
    var automatic: Bool {
        get { UserDefaults.standard.bool(forKey: "hotspotWhenBroken") }
        set { UserDefaults.standard.set(newValue, forKey: "hotspotWhenBroken"); consider() }
    }

    private lazy var session: NSObject? = {
        dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW)
        guard let type = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type else { return nil }
        let session = type.init()
        session.perform(NSSelectorFromString("setDelegate:"), with: self)
        return session
    }()
    private var browsing = false
    private var brokenSince: Date?
    /// Switching by itself happens once per breakage, so a failure doesn't come back as an alert every few seconds.
    private var switchedThisTime = false
    private var lastSwitch = Date.distantPast
    private var attempt = 0

    /// Looks for phones while the Wi-Fi is broken, and switches to one if the person chose that.
    func wifi(broken: Bool, metered: Bool) {
        if !metered, joining == nil, joined {
            joined = false
        }
        if broken {
            if brokenSince == nil {
                brokenSince = Date()
                Timer.scheduledTimer(withTimeInterval: Self.patience, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.consider() }
                }
            }
            browse(true)
        } else {
            brokenSince = nil
            switchedThisTime = false
            browse(false)
        }
    }

    func join(_ name: String) {
        guard joining == nil, let phone = phones.first(where: { $0.name == name }), let session else { return }
        attempt += 1
        let current = attempt
        joining = name
        let started = Date()
        let enabled: @convention(block) (NSString?, NSString?, NSError?) -> Void = { [weak self] network, password, _ in
            let network = network as String?, password = password as String?
            Task.detached {
                var failure: String?
                if let network, let password {
                    do { try Self.associate(network, password: password) } catch { failure = L("Your Mac couldn't join its network.") }
                } else {
                    failure = L("Your iPhone couldn't turn its hotspot on.")
                }
                await self?.finish(current, failure: failure, after: Date().timeIntervalSince(started))
            }
        }
        session.perform(NSSelectorFromString("enableHotspotForDevice:withCompletionHandler:"), with: phone.device, with: enabled)
        // An iPhone out of Bluetooth range may never answer; a hotspot that answers is joined well within this.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish(current, failure: L("Your iPhone didn't answer."), after: 60) }
        }
    }

    /// Leaves the hotspot: macOS joins its preferred Wi-Fi again once the Wi-Fi is back on.
    func backToWiFi() {
        joined = false
        Task.detached {
            let wifi = CWWiFiClient.shared().interface()
            try? wifi?.setPower(false)
            try? await Task.sleep(for: .seconds(1.5))
            try? wifi?.setPower(true)
        }
    }

    private func finish(_ current: Int, failure: String?, after seconds: TimeInterval) {
        guard current == attempt, joining != nil else { return }
        joining = nil
        if let failure {
            Log.write("Couldn't switch to the iPhone's hotspot.")
            onFailure(failure)
        } else {
            joined = true
            Log.write("Switched to the iPhone's hotspot in \(String(format: "%.1f", seconds)) s.")
        }
    }

    private func consider() {
        guard automatic, !switchedThisTime, joining == nil, !joined, Date().timeIntervalSince(lastSwitch) >= Self.cooldown,
              let since = brokenSince, Date().timeIntervalSince(since) >= Self.patience, let phone = phones.first else { return }
        switchedThisTime = true
        lastSwitch = Date()
        Log.write("The Wi-Fi stayed broken; switching to the iPhone's hotspot.")
        join(phone.name)
    }

    private func browse(_ on: Bool) {
        guard on != browsing, let session else { return }
        browsing = on
        session.perform(NSSelectorFromString(on ? "startBrowsing" : "stopBrowsing"))
        if !on { phones = [] }
    }

    /// The scan finds the hotspot by the name the iPhone sent; macOS may leave that name out of what it returns.
    private nonisolated static func associate(_ name: String, password: String) throws {
        guard let wifi = CWWiFiClient.shared().interface() else { throw JoinError.noWiFi }
        // A hotspot just turned on takes a few seconds to show up.
        for attempt in 0..<5 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 2) }
            guard let network = try wifi.scanForNetworks(withName: name).first else { continue }
            if network.ssid == nil, var record = network.value(forKey: "_scanRecord") as? [String: Any] {
                record["SSID"] = Data(name.utf8)
                record["SSID_STR"] = name
                network.setValue(record, forKey: "_scanRecord")
            }
            return try wifi.associate(to: network, password: password)
        }
        throw JoinError.notFound
    }

    private enum JoinError: Error { case noWiFi, notFound }
}

extension Hotspot {
    /// Called by Sharing's service on its own queue with every phone in range.
    @objc(session:updatedFoundDevices:) nonisolated func session(_ session: NSObject, updatedFoundDevices devices: NSArray) {
        nonisolated(unsafe) let found = devices.compactMap { $0 as? NSObject }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.phones = found.compactMap { device in
                    guard let name = device.value(forKey: "deviceName") as? String else { return nil }
                    return Phone(name: name, battery: (device.value(forKey: "batteryLife") as? NSNumber)?.intValue, device: device)
                }
                self.consider()
            }
        }
    }
}
