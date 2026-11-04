import AppKit
import Companion
import RefillCore

/// Animates the menu bar cup from the Wi-Fi: steam for the signal, faster with traffic. Reads the radio and the
/// kernel's byte counters once a second, and sends nothing; Core Animation moves the steam between readings.
@MainActor
final class CupController {
    var animated: Bool {
        get { UserDefaults.standard.object(forKey: "animateCup") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "animateCup")
            apply()
        }
    }

    /// Asks the menu bar item to show its usual icon again.
    var restoreIcon: (() -> Void)?

    private let watcher: Watcher
    private let item: NSStatusItem
    private var cup: MenuBarCup?
    private var sampler: Timer?
    private var last: (interface: String, traffic: Traffic, at: Date)?
    private var network: LocalNetwork?
    private var tick = 0

    init(watcher: Watcher, item: NSStatusItem) {
        self.watcher = watcher
        self.item = item
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func apply() {
        cup?.remove()
        cup = nil
        sampler?.invalidate()
        sampler = nil
        last = nil
        restoreIcon?()
        guard animated, let button = item.button else { return }
        cup = MenuBarCup(button: button)
        sample()
        sampler = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    /// Shows a change of the watcher's status at once rather than on the next reading.
    func statusChanged() { sample() }

    private func sample() {
        guard let cup else { return }
        tick += 1
        let now = Date()
        // Reading the network's services is the costly part of a reading, and it changes rarely.
        if network == nil || tick % 5 == 0 { network = Gateway.current() }
        var pulse = Pulse(state: state(network: network), bars: 0)
        if let network {
            // Ethernet carries no signal to show; it gets full steam.
            pulse.bars = network.interface == Vitals.interface ? Vitals.read()?.bars ?? 1 : 3
            if let traffic = Traffic.read(network.interface) {
                // Counters belong to their interface: after a switch, start over rather than subtract another's.
                if let last, last.interface == network.interface {
                    let rate = Traffic.rate(from: last.traffic, to: traffic, seconds: now.timeIntervalSince(last.at))
                    pulse.received = rate.received
                    pulse.sent = rate.sent
                }
                last = (network.interface, traffic, now)
            }
        } else {
            last = nil
        }
        let filled = { if case .loggedIn = watcher.status { true } else { false } }()
        cup.show(pulse, filled: filled, still: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func state(network: LocalNetwork?) -> Pulse.State {
        if watcher.status == .paused { return .paused }
        if watcher.diagnosis?.broken == .vpn { return .broken(.vpn) }
        switch watcher.status {
        case .loggingIn, .teaching: return .loggingIn
        case .offline:
            if let leg = watcher.diagnosis?.broken { return .broken(leg) }
            // No leg to blame is not the internet working.
            return network == nil ? .offline : .noInternet
        case .routerUnreachable: return .broken(.router)
        case .unsupported, .failed, .notNow, .turnedOff, .asking: return .broken(.loginPage)
        case .paused: return .paused
        case .noLoginPage, .loggedIn: return network == nil ? .offline : .online
        }
    }
}
