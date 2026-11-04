import AppKit
import Companion
import RefillCore

/// Animates the menu bar cup from the Wi-Fi: steam for the signal, faster with traffic; and, if the person wants it, a
/// bigger cup on the desktop whose coffee is the cafe session and which a little kettle refills. Reads the radio and the
/// kernel's byte counters once a second, and sends nothing; Core Animation moves both between readings.
@MainActor
final class CupController {
    var animated: Bool {
        get { UserDefaults.standard.object(forKey: "animateCup") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "animateCup")
            apply()
        }
    }

    /// The cup on the desktop, off unless the person turns it on.
    var onDesktop: Bool {
        get { UserDefaults.standard.bool(forKey: "desktopCup") }
        set {
            UserDefaults.standard.set(newValue, forKey: "desktopCup")
            apply()
        }
    }

    /// Asks the menu bar item to show its usual icon again.
    var restoreIcon: (() -> Void)?
    /// The menu's status line, shown on the desktop cup.
    var describe: (() -> String)?

    private let watcher: Watcher
    private let item: NSStatusItem
    private var cup: MenuBarCup?
    private var panel: NSPanel?
    private var desk: CupScene?
    private var hovering = false
    private var panelObservers: [NSObjectProtocol] = []
    private var pathPanel: NSPanel?
    private var path: BeanScene?
    private var ping: Task<Void, Never>?
    private var pathObserver: NSObjectProtocol?
    private var routerMilliseconds: Int?
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
        panelObservers.forEach(NotificationCenter.default.removeObserver)
        panelObservers = []
        panel?.close()
        panel = nil
        desk = nil
        sampler?.invalidate()
        sampler = nil
        last = nil
        restoreIcon?()
        if animated, let button = item.button { cup = MenuBarCup(button: button) }
        if onDesktop { showDesk() }
        startSampling()
    }

    private func startSampling() {
        guard sampler == nil, cup != nil || desk != nil || path != nil else { return }
        sample()
        sampler = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    /// The way from this Mac to the internet, stop by stop, with coffee beans carrying the traffic and the broken stop
    /// marked. Pings the router every three seconds while it shows.
    func showPath() {
        if let pathPanel {
            pathPanel.orderFrontRegardless()
            return
        }
        let size = NSSize(width: 440, height: 187)
        let scene = BeanScene()
        scene.rounded = false
        scene.frame = NSRect(origin: .zero, size: size)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = L("The Way to the Internet")
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = scene
        panel.center()
        pathObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if let observer = self?.pathObserver { NotificationCenter.default.removeObserver(observer) }
                self?.pathObserver = nil
                self?.ping?.cancel()
                self?.path = nil
                self?.pathPanel = nil
                self?.routerMilliseconds = nil
                if self?.cup == nil, self?.desk == nil {
                    self?.sampler?.invalidate()
                    self?.sampler = nil
                }
            }
        }
        pathPanel = panel
        path = scene
        startSampling()
        sample()
        panel.orderFrontRegardless()
    }

    /// Shows a change of the watcher's status at once rather than on the next reading.
    func statusChanged() { sample() }

    /// The cup in a small borderless window that floats above other windows, can be dragged anywhere, and remembers
    /// where it was put. Right-click hides it.
    private func showDesk() {
        let size = NSSize(width: 230, height: 230)
        let scene = CupScene()
        scene.frame = NSRect(origin: .zero, size: size)
        scene.onHover = { [weak self] inside in
            self?.hovering = inside
            self?.sample()
        }
        let menu = NSMenu()
        let hide = NSMenuItem(title: L("Hide the Cup"), action: #selector(hideDesk), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        scene.menu = menu
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = scene
        if let saved = UserDefaults.standard.string(forKey: "desktopCupOrigin") {
            panel.setFrameOrigin(NSPointFromString(saved))
        } else if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24))
        }
        panelObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: "desktopCupOrigin")
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sample() }
            },
        ]
        panel.orderFrontRegardless()
        self.panel = panel
        desk = scene
    }

    @objc private func hideDesk() { onDesktop = false }

    private func sample() {
        guard cup != nil || desk != nil || path != nil else { return }
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
        if let start = watcher.sessionStart, let end = watcher.sessionEnd, end > now, end > start {
            pulse.sessionLeft = end.timeIntervalSince(now) / end.timeIntervalSince(start)
        }
        pulse.refilled = watcher.refilled
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let path {
            if let network, tick % 3 == 1 || routerMilliseconds == nil {
                pulse.vpn = Checkup.tunnel(over: network)
                ping?.cancel()
                ping = Task {
                    let reading = await Checkup.ping(network.router, interface: network.interface, within: 1)
                    guard !Task.isCancelled else { return }
                    if case .ok(let ms?) = reading { self.routerMilliseconds = ms } else { self.routerMilliseconds = nil }
                }
            } else if let network {
                pulse.vpn = Checkup.tunnel(over: network)
            }
            pulse.routerMilliseconds = routerMilliseconds
            path.still = reduceMotion
            path.show(pulse, text: describe?() ?? "")
        }
        let filled = { if case .loggedIn = watcher.status { true } else { false } }()
        cup?.show(pulse, filled: filled, still: reduceMotion)
        if let desk {
            desk.still = reduceMotion
            let alert = !pulse.isUp && pulse.state != .loggingIn && pulse.state != .paused
            desk.show(pulse, text: alert || hovering ? describe?() : nil)
            // Animation stands still while the cup is out of sight, and with Reduce Motion.
            let still = reduceMotion || panel.map { !$0.occlusionState.contains(.visible) } ?? false
            if let layer = desk.layer, (layer.speed == 0) != still {
                layer.timeOffset = still ? layer.convertTime(CACurrentMediaTime(), from: nil) : 0
                layer.speed = still ? 0 : 1
                if !still { layer.beginTime = 0 }
            }
        }
    }

    private func state(network: LocalNetwork?) -> Pulse.State {
        if watcher.status == .paused { return .paused }
        if watcher.diagnosis?.broken == .vpn { return .broken(.vpn) }
        switch watcher.status {
        case .loggingIn, .teaching, .waitingForPage: return .loggingIn
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
