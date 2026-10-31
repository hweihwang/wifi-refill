import AppKit
import Network
import OSLog
import RefillCore

/// A cafe login page the person has met, and whether they let Wi-Fi Refill log in there.
struct Profile: Codable, Equatable {
    var id: String
    var network: String
    /// The router address last seen with this page. Only a hint for how often to check, never a reason to log in.
    var router: String
    var allowed: Bool
}

/// Decides when to look at the network and logs in when a known login page appears.
@MainActor
final class Watcher {
    enum Status: Equatable {
        case paused
        case offline
        case noLoginPage
        case unsupported(String)
        case asking(String)
        case notNow(String)
        case turnedOff(String)
        case loggingIn(String)
        case loggedIn(String, until: Date?)
        case routerUnreachable
        case failed(String)
    }

    var onChange: (() -> Void)?
    /// Asks the person whether Wi-Fi Refill may log in on this page from now on.
    var askPermission: ((PortalSession) async -> Bool)?

    private(set) var status = Status.offline { didSet { if status != oldValue { onChange?() } } }
    private(set) var lastProbe: [Hop] = []
    private(set) var profiles: [Profile] {
        get { (defaults.data(forKey: "profiles")).flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "profiles"); onChange?() }
    }

    var paused: Bool {
        get { defaults.bool(forKey: "paused") }
        set {
            defaults.set(newValue, forKey: "paused")
            generation += 1
            check(reason: newValue ? "pause" : "resume")
        }
    }

    var reconnectsToday: Int {
        defaults.string(forKey: "reconnectDay") == Self.today ? defaults.integer(forKey: "reconnectCount") : 0
    }

    private let defaults = UserDefaults.standard
    private let client = PortalClient()
    private let monitor = NWPathMonitor()
    private let logger = Logger(subsystem: "com.hweihwang.WiFiRefill", category: "watcher")
    private var router: String?
    private var sessionEnd: Date?
    private var joinAttempt = 0
    /// Bumps on every network change and pause; results of checks that started earlier are dropped.
    private var generation = 0
    private var timer: Timer?
    private var running = false
    private var pending: String?

    func start() {
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.generation += 1
                self.joinAttempt = 0
                self.check(reason: "network change")
            }
        }
        monitor.start(queue: .main)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.check(reason: "wake") }
        }
    }

    func check(reason: String) {
        timer?.invalidate()
        guard !paused else { status = .paused; return }
        guard !running else { pending = reason; return }
        running = true
        Task {
            await evaluate(reason: reason)
            running = false
            if let next = pending {
                pending = nil
                check(reason: next)
            }
        }
    }

    func setAllowed(_ allowed: Bool, for id: String) {
        profiles = profiles.map { $0.id == id ? Profile(id: $0.id, network: $0.network, router: $0.router, allowed: allowed) : $0 }
        check(reason: "network setting")
    }

    func forget(_ id: String) {
        profiles.removeAll { $0.id == id }
        check(reason: "network forgotten")
    }

    /// The login page's redirect chain for a report, followed further than Wi-Fi Refill goes on its own,
    /// because the person asked for it.
    func reportChain() async -> [Hop] {
        guard let start = lastProbe.first?.location else { return lastProbe }
        let more = (try? await client.get(start, maxHops: 5) { _ in true }) ?? []
        return lastProbe + more
    }

    private func evaluate(reason: String) async {
        let started = generation
        if let current = Gateway.current(), current != router {
            router = current
            sessionEnd = nil
        }
        let cafe = profiles.first { $0.router == router && $0.allowed }
        let result = await client.probe()
        guard started == generation, !paused else { return }
        logger.notice("check (\(reason, privacy: .public)): \(Self.describe(result), privacy: .public)")

        let now = Date()
        switch result {
        case .online:
            joinAttempt = 0
            if let end = sessionEnd, now >= end.addingTimeInterval(Schedule.endingWindow) { sessionEnd = nil }
            status = cafe.map { .loggedIn($0.network, until: sessionEnd) } ?? .noLoginPage
            schedule(Schedule.next(after: .online, now: now, sessionEnd: sessionEnd, onCafe: cafe != nil))
        case .offline:
            status = .offline
            schedule(Schedule.next(after: .offline, now: now, sessionEnd: sessionEnd, onCafe: cafe != nil, joinAttempt: joinAttempt))
            joinAttempt += 1
        case .portal(let hops):
            lastProbe = hops
            await logIn(hops, started: started)
        }
    }

    private func logIn(_ probe: [Hop], started: Int) async {
        guard let (driver, entry) = Drivers.recognize(probe), let router else {
            status = .unsupported(L("This login page isn't supported yet."))
            return schedule(nil)
        }
        do {
            var session = try await driver.prepare(from: entry, router: router, client: client)
            guard started == generation, !paused else { return }

            let known = profiles.first { $0.id == session.profile }
            if known?.allowed == false {
                status = .turnedOff(session.network)
                return schedule(nil)
            }
            if known == nil {
                status = .asking(session.network)
                let allowed = await askPermission?(session) ?? false
                guard started == generation, !paused else { return }
                guard allowed else {
                    status = .notNow(session.network)
                    return schedule(nil)
                }
                // The person may have taken a while; start over so the login page's session is fresh.
                session = try await driver.prepare(from: entry, router: router, client: client)
            }

            status = .loggingIn(session.network)
            let begun = Date()
            try await driver.login(session, client: client)
            let seconds = Date().timeIntervalSince(begun)
            sessionEnd = session.minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
            remember(session)
            countReconnect()
            status = .loggedIn(session.network, until: sessionEnd)
            Log.write("Logged in to \(session.network) in \(String(format: "%.1f", seconds)) s. Session ends \(sessionEnd.map(Log.time) ?? "at an unknown time").")
            schedule(Schedule.next(after: .loggedIn, now: Date(), sessionEnd: sessionEnd, onCafe: true))
        } catch let error as LoginError {
            if case .unsupported(let reason) = error {
                status = .unsupported(reason)
                return schedule(nil)
            }
            fail(.failed(error.description), log: error.description)
        } catch RequestError.routerUnreachable {
            fail(.routerUnreachable, log: "The Wi-Fi router did not answer.")
        } catch {
            fail(.failed(error.localizedDescription), log: error.localizedDescription)
        }
    }

    private func fail(_ newStatus: Status, log reason: String) {
        status = newStatus
        Log.write("Login failed: \(reason)")
        schedule(Schedule.retry)
    }

    private func remember(_ session: PortalSession) {
        var all = profiles.filter { $0.id != session.profile }
        all.append(Profile(id: session.profile, network: session.network, router: session.router, allowed: true))
        profiles = all
    }

    private func countReconnect() {
        defaults.set(reconnectsToday + 1, forKey: "reconnectCount")
        defaults.set(Self.today, forKey: "reconnectDay")
    }

    private func schedule(_ seconds: TimeInterval?) {
        timer?.invalidate()
        guard let seconds else { return }
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.check(reason: "timer") }
        }
        // .common keeps the timer firing while the menu is open. Timers stop counting during sleep; wake triggers a check.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static var today: String {
        Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)", timeZone: .current, calendar: .current))
    }

    private static func describe(_ result: ProbeResult) -> String {
        switch result {
        case .online: "online"
        case .offline: "offline"
        case .portal(let hops): "login page at \(hops.first?.location?.host ?? "same address")"
        }
    }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WiFiRefill.log")

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

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
