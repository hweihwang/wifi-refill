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
///
/// One check runs at a time. Anything that changes what a check should do (a network change, Pause, turning a network
/// off or forgetting it) cancels the running check, and every step re-confirms that its check still applies before it
/// sends a request or changes state.
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
    /// The probe's answer from the last login page, for a report. Nothing else is fetched for reports.
    private(set) var lastProbe: [Hop] = []
    private(set) var profiles: [Profile] {
        get { defaults.data(forKey: "profiles").flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "profiles"); onChange?() }
    }

    var paused: Bool {
        get { defaults.bool(forKey: "paused") }
        set {
            defaults.set(newValue, forKey: "paused")
            restart(reason: newValue ? "pause" : "resume")
        }
    }

    var reconnectsToday: Int {
        defaults.string(forKey: "reconnectDay") == Self.today ? defaults.integer(forKey: "reconnectCount") : 0
    }

    private let defaults = UserDefaults.standard
    private let client = PortalClient()
    private let monitor = NWPathMonitor()
    private let logger = Logger(subsystem: "com.hweihwang.WiFiRefill", category: "watcher")
    /// The current router, nil while there is none.
    private var router: String?
    /// The last router seen; a short gap without one (a Wi-Fi blip, sleep) keeps the session end.
    private var lastRouter: String?
    private var sessionEnd: Date?
    /// The login page the person answered Not Now for, until the Mac joins another network or they choose Check Now.
    private var notNowProfile: String?
    private var joinAttempt = 0
    private var generation = 0
    private var task: Task<Void, Never>?
    private var pending: String?
    private var timer: Timer?

    func start() {
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                self?.joinAttempt = 0
                self?.restart(reason: "network change")
            }
        }
        monitor.start(queue: .main)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.check(reason: "wake") }
        }
    }

    func check(reason: String) {
        if reason == "Check Now" { notNowProfile = nil }
        timer?.invalidate()
        guard !paused else {
            status = .paused
            return
        }
        guard task == nil else {
            pending = reason
            return
        }
        let started = generation
        task = Task {
            await evaluate(reason: reason, started: started)
            task = nil
            if let next = pending {
                pending = nil
                check(reason: next)
            }
        }
    }

    func setAllowed(_ allowed: Bool, for id: String) {
        profiles = profiles.map { $0.id == id ? Profile(id: $0.id, network: $0.network, router: $0.router, allowed: allowed) : $0 }
        restart(reason: "network setting")
    }

    func forget(_ id: String) {
        profiles.removeAll { $0.id == id }
        restart(reason: "network forgotten")
    }

    /// Cancels the running check, whose results no longer apply, and starts a new one.
    private func restart(reason: String) {
        generation += 1
        task?.cancel()
        check(reason: reason)
    }

    private func stillApplies(_ started: Int) -> Bool {
        started == generation && !paused && !Task.isCancelled
    }

    private func evaluate(reason: String, started: Int) async {
        let current = Gateway.current()
        if let current, current != lastRouter {
            lastRouter = current
            sessionEnd = nil
            notNowProfile = nil
        }
        router = current
        let cafe = profiles.first { $0.router == current && $0.allowed }
        let result = await client.probe()
        guard stillApplies(started) else { return }
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
        guard let (driver, entry) = Drivers.recognize(probe) else {
            status = .unsupported("This login page isn't supported yet.")
            return schedule(nil)
        }
        guard let router else {
            return fail(.failed("The login page did not name the router."), code: "no-router", started: started)
        }
        do {
            var session = try await driver.prepare(from: entry, router: router, client: client)
            guard stillApplies(started) else { return }

            let known = profiles.first { $0.id == session.profile }
            if known?.allowed == false {
                status = .turnedOff(session.network)
                return schedule(nil)
            }
            if known == nil {
                if session.profile == notNowProfile {
                    status = .notNow(session.network)
                    return schedule(nil)
                }
                status = .asking(session.network)
                let allowed = await askPermission?(session) ?? false
                guard stillApplies(started) else { return }
                guard allowed else {
                    notNowProfile = session.profile
                    status = .notNow(session.network)
                    return schedule(nil)
                }
                // Remember the answer now, so a failed first login does not ask again.
                let consented = session.profile
                remember(session)
                // The person may have taken a while; start over so the login page's session is fresh.
                session = try await driver.prepare(from: entry, router: router, client: client)
                guard stillApplies(started), session.profile == consented else { return }
            }

            status = .loggingIn(session.network)
            let begun = Date()
            try await driver.login(session, client: client)
            guard stillApplies(started) else { return }
            // Count it only once Apple's check page comes through.
            guard await client.probe() == .online else { throw LoginError.unexpected("Still not online after logging in.") }
            guard stillApplies(started) else { return }

            let seconds = Date().timeIntervalSince(begun)
            sessionEnd = session.minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
            remember(session)
            countReconnect()
            status = .loggedIn(session.network, until: sessionEnd)
            let kind = session.profile.split(separator: ":").first.map(String.init) ?? "portal"
            Log.write("Logged in (\(kind)) in \(String(format: "%.1f", seconds)) s. Session: \(session.minutes.map { "\($0) min" } ?? "length unknown").")
            schedule(Schedule.next(after: .loggedIn, now: Date(), sessionEnd: sessionEnd, onCafe: true))
        } catch let error as LoginError {
            guard stillApplies(started) else { return }
            if case .unsupported(let reason) = error {
                status = .unsupported(reason)
                Log.write("Login page not supported.")
                return schedule(nil)
            }
            let code = switch error { case .refused: "refused"; case .unexpected: "unexpected"; case .unsupported: "unsupported" }
            fail(.failed(error.description), code: code, started: started)
        } catch RequestError.routerUnreachable {
            fail(.routerUnreachable, code: "router-unreachable", started: started)
        } catch {
            fail(.failed("The login page did not answer."), code: "network \((error as? URLError)?.code.rawValue ?? 0)", started: started)
        }
    }

    private func fail(_ newStatus: Status, code: String, started: Int) {
        guard stillApplies(started) else { return }
        status = newStatus
        Log.write("Login failed: \(code).")
        schedule(Schedule.retry)
    }

    /// Saves the profile, keeping the person's on/off choice when it exists.
    private func remember(_ session: PortalSession) {
        var all = profiles
        if let index = all.firstIndex(where: { $0.id == session.profile }) {
            all[index].network = session.network
            all[index].router = session.router
        } else {
            all.append(Profile(id: session.profile, network: session.network, router: session.router, allowed: true))
        }
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
        case .portal: "login page"
        }
    }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WiFiRefill.log")

    /// Writes fixed event text only: never names, addresses or anything a login page sent.
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
