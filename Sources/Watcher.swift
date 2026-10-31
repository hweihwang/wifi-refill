import AppKit
import Network
import OSLog
import SystemConfiguration

/// Decides when to look for the login page: once when the Mac joins a network, then only when the portal session is due to end.
@MainActor
final class Watcher {
    enum Status: Equatable {
        case paused, offline, noPortal, otherPortal, loggingIn
        case loggedIn(network: String, until: Date?)
        case failed(String)
    }

    var onChange: (() -> Void)?
    private(set) var status: Status = .offline { didSet { if status != oldValue { onChange?() } } }
    private(set) var lastLogin: Date?

    var paused: Bool {
        get { defaults.bool(forKey: "paused") }
        set { defaults.set(newValue, forKey: "paused"); check() }
    }

    private let defaults = UserDefaults.standard
    private let portal = Portal()
    private let monitor = NWPathMonitor()
    private let logger = Logger(subsystem: "com.hweihwang.WifiAutologin", category: "watcher")
    private var gateway: String?
    private var cafe: (address: String, name: String)?
    private var due: Date?
    private var timer: Timer?
    private var running = false
    private var again = false

    /// Cafe routers this Mac has logged in through: "gateway:portal port" to network name.
    private var cafes: [String: String] {
        get { defaults.dictionary(forKey: "cafes") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "cafes") }
    }

    func start() {
        // A new path may be another network behind the same gateway address, so confirm the cafe router again.
        monitor.pathUpdateHandler = { [weak self] _ in Task { @MainActor in self?.cafe = nil; self?.check() } }
        monitor.start(queue: .main)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    /// Looks again now. With `force` it probes even when the session is not due to end yet.
    func check(force: Bool = false) {
        timer?.invalidate()
        guard !paused else { status = .paused; return }
        guard !running else { again = true; return }
        running = true
        Task {
            await evaluate(force: force)
            running = false
            if again { again = false; check() }
        }
    }

    private func evaluate(force: Bool) async {
        let now = Date()
        let current = Self.currentGateway()
        // No gateway means a Wi-Fi blip or wake from sleep; keep the session end so the timer survives it.
        if let current, current != gateway { gateway = current; cafe = nil; due = nil }
        if cafe == nil, let current, let match = cafes.first(where: { $0.key.hasPrefix(current + ":") }), await portal.routerAnswers(match.key) {
            cafe = (match.key, match.value)
        }
        if !force, let due, now < due, let cafe {
            status = .loggedIn(network: cafe.name, until: due)
            return schedule(due)
        }

        let probe = await portal.probe()
        logger.notice("probe on gateway \(current ?? "none", privacy: .public): \(String(describing: probe).prefix(40), privacy: .public)")
        switch probe {
        case .ruijie(let page):
            status = .loggingIn
            do {
                let login = try await portal.login(page)
                if let current {
                    cafe = ("\(current):\(login.gatewayPort)", login.network)
                    cafes[cafe!.address] = login.network
                }
                due = login.minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
                lastLogin = Date()
                status = .loggedIn(network: login.network, until: due)
                Log.write("Logged in to \(login.network). Session ends \(due.map(Log.time) ?? "at an unknown time").")
                schedule(due ?? Date().addingTimeInterval(60))
            } catch {
                let reason = (error as? Portal.Failure)?.description ?? error.localizedDescription
                status = .failed(reason)
                Log.write("Login failed: \(reason)")
                schedule(Date().addingTimeInterval(60))
            }
        case .online:
            guard let cafe else { status = .noPortal; return }
            if let due, now < due + 300 {
                // The router ends sessions a little after the due time, so look every few seconds until it does.
                status = .loggedIn(network: cafe.name, until: due)
                schedule(now < due ? due : now.addingTimeInterval(5))
            } else {
                // Session end unknown, for example after a restart at the cafe: look every minute until the first login.
                due = nil
                status = .loggedIn(network: cafe.name, until: nil)
                schedule(now.addingTimeInterval(60))
            }
        case .otherPortal:
            status = .otherPortal
        case .offline:
            status = .offline
            if cafe != nil { schedule(now.addingTimeInterval(60)) }
        }
    }

    private func schedule(_ date: Date) {
        timer?.invalidate()
        // Timers stop counting while the Mac sleeps; the wake notification covers that.
        let timer = Timer(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common) // .common keeps it firing while the menu is open
        self.timer = timer
    }

    private static func currentGateway() -> String? {
        let ipv4 = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        return ipv4?["Router"] as? String
    }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/wifi-autologin.log")

    static func write(_ line: String) {
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)", timeZone: .current, calendar: .current))
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}
