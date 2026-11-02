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
    /// How long this network keeps a login, learned from its logouts when the login page does not say.
    var session: SessionLength? = nil
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
        case teaching
    }

    var onChange: (() -> Void)?
    /// Asks the person whether Wi-Fi Refill may log in on this page from now on.
    var askPermission: ((PortalSession) async -> Bool)?

    private(set) var status = Status.offline { didSet { if status != oldValue { onChange?() } } }
    /// The probe's answer from the last login page, for a report. Nothing else is fetched for reports.
    private(set) var lastProbe: [Hop] = []
    /// What the person taught Wi-Fi Refill about the login page this network showed last, to share it.
    var shareableRecipe: Recipe? {
        network.flatMap { recipes[Recipe.page(probe: lastProbe, network: $0)] }
    }
    private(set) var profiles: [Profile] {
        get { defaults.data(forKey: "profiles").flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "profiles"); onChange?() }
    }
    /// Login pages the person taught, by page. Kept on this Mac only.
    private var recipes: [String: Recipe] {
        get { defaults.data(forKey: "recipes").flatMap { try? JSONDecoder().decode([String: Recipe].self, from: $0) }?.filter { $0.value.version == Recipe.currentVersion } ?? [:] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "recipes") }
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
    private let portal = PortalClient()
    private let monitor = NWPathMonitor()
    private let logger = Logger(subsystem: "com.hweihwang.WiFiRefill", category: "watcher")
    /// The network the Mac is on, nil while there is none.
    private var network: LocalNetwork?
    /// The last router seen; a short gap without one (a Wi-Fi blip, sleep) keeps the session end.
    private var lastRouter: String?
    /// The last network seen, which choices about one network (Not Now, a page that stopped working) belong to.
    private var lastNetwork: LocalNetwork?
    /// A network macOS has no name for, where the person allowed a taught page, and what the menu calls it: until the
    /// connection ends.
    private var allowedHere: (network: LocalNetwork, name: String)?
    private var sessionEnd: Date?
    /// The login whose length is being learned: when it happened, and the last check that found it still open.
    private var learning: (profile: String, loggedIn: Date, lastOnline: Date)?
    /// When the Mac joined the current network.
    private var joined = Date()
    /// The login page the person answered Not Now for, until the Mac joins another network or they choose Check Now.
    private var notNowProfile: String?
    /// The network whose taught page no longer worked, until the Mac joins another network, Check Now, or a new lesson.
    private var stuckProfile: String?
    /// While the person teaches a page, the lesson's web view logs in; checks wait.
    private var teaching = false
    private var lesson: Task<LoginBrowser.Lesson?, Never>?
    private var joinAttempt = 0
    private var generation = 0
    private var task: Task<Void, Never>?
    private var pending: String?
    private var timer: Timer?

    func start() {
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
        monitor.start(queue: .main)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.check(reason: "wake") }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.check(reason: "unlock") }
        }
    }

    func check(reason: String) {
        if reason == "Check Now" {
            notNowProfile = nil
            stuckProfile = nil
        }
        timer?.invalidate()
        guard !teaching else { return }
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
        profiles = profiles.map { profile in
            var profile = profile
            if profile.id == id { profile.allowed = allowed }
            return profile
        }
        restart(reason: "network setting")
    }

    func forget(_ id: String) {
        profiles.removeAll { $0.id == id }
        restart(reason: "network forgotten")
    }

    /// macOS also reports a change while the Mac stays on the same network, for example when a login opens up the
    /// internet. Only another network (interface, router, address or mask) makes the running check's results stale;
    /// otherwise the check finishes first.
    private func networkChanged() {
        joinAttempt = 0
        if Gateway.current() == network {
            check(reason: "network change")
        } else {
            restart(reason: "network change")
        }
    }

    /// Cancels the running check, whose results no longer apply, and starts a new one.
    private func restart(reason: String) {
        generation += 1
        task?.cancel()
        lesson?.cancel()
        check(reason: reason)
    }

    private func stillApplies(_ started: Int) -> Bool {
        started == generation && !paused && !Task.isCancelled
    }

    private func evaluate(reason: String, started: Int) async {
        let current = Gateway.current()
        if let current, current.router != lastRouter {
            lastRouter = current.router
            joined = Date()
            sessionEnd = nil
            learning = nil
        }
        if let current, current != lastNetwork {
            lastNetwork = current
            notNowProfile = nil
            stuckProfile = nil
            allowedHere = nil
        }
        // Permission for one connection ends with it: another cafe can look exactly the same.
        if current == nil { allowedHere = nil }
        network = current
        let cafe = profiles.first { $0.router == current?.router && $0.allowed }
            ?? allowedHere.flatMap { $0.network == current ? Profile(id: "page:this-connection", network: $0.name, router: $0.network.router, allowed: true) : nil }
        // Every request of this check goes out on the network it started on, or not at all.
        let client = portal.on(current)
        let result = await client.probe()
        guard stillApplies(started) else { return }
        logger.notice("check (\(reason, privacy: .public)): \(Self.describe(result), privacy: .public)")

        let now = Date()
        switch result {
        case .online:
            joinAttempt = 0
            if learning?.profile == cafe?.id { learning?.lastOnline = now }
            if let end = sessionEnd, now >= end.addingTimeInterval(Schedule.endingWindow) { sessionEnd = nil }
            status = cafe.map { .loggedIn($0.network, until: sessionEnd) } ?? .noLoginPage
            schedule(Schedule.next(after: .online, now: now, sessionEnd: sessionEnd, onCafe: cafe != nil, joined: joined))
        case .offline:
            status = .offline
            schedule(Schedule.next(after: .offline, now: now, sessionEnd: sessionEnd, onCafe: cafe != nil, joinAttempt: joinAttempt))
            joinAttempt += 1
        case .portal(let hops):
            lastProbe = hops
            learnSessionLength(loggedOut: now)
            await logIn(hops, client: client, started: started)
        }
    }

    private func logIn(_ probe: [Hop], client: PortalClient, started: Int) async {
        guard let network else {
            return fail(.failed("The login page did not name the router."), code: "no-router", started: started)
        }
        // A page the person taught wins over a driver: they teach a page when its driver fails them. A shared page
        // comes after drivers.
        let taught = recipes[Recipe.page(probe: probe, network: network)]
        guard taught == nil, let (driver, entry) = Drivers.recognize(probe) else {
            return await logInAsTaught(probe, recipe: taught ?? Recipe.builtIn(for: probe), on: network, client: client, started: started)
        }
        do {
            var session = try await driver.prepare(from: entry, on: network, client: client)
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
                session = try await driver.prepare(from: entry, on: network, client: client)
                guard stillApplies(started) else { return }
                // A different login page now: the answer was for another one, so look again and ask again.
                guard session.profile == consented else { throw LoginError.unexpected("The login page changed while you were deciding.") }
            }

            status = .loggingIn(session.network)
            let begun = Date()
            try await driver.login(session, client: client)
            guard stillApplies(started) else { return }
            // Count it only once Apple's check page comes through; routers can take a moment to open up.
            var online = false
            for attempt in 0..<3 where !online {
                if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
                online = await client.probe() == .online
                guard stillApplies(started) else { return }
            }
            guard online else { throw LoginError.unexpected("Still not online after logging in.") }

            let seconds = Date().timeIntervalSince(begun)
            remember(session)
            loggedIn(session)
            countReconnect()
            status = .loggedIn(session.network, until: sessionEnd)
            let kind = session.profile.split(separator: ":").first.map(String.init) ?? "portal"
            Log.write("Logged in (\(kind)) in \(String(format: "%.1f", seconds)) s. Session: \(Self.describe(session.minutes, learned: profiles.first { $0.id == session.profile }?.session)).")
            schedule(Schedule.next(after: .loggedIn, now: Date(), sessionEnd: sessionEnd, onCafe: true))
        } catch let error as LoginError {
            guard stillApplies(started) else { return }
            if case .unsupported(let reason) = error {
                // The page changed beyond what its driver knows; a shared recipe presses its buttons instead.
                if let shared = Recipe.builtIn(for: probe) {
                    return await logInAsTaught(probe, recipe: shared, on: network, client: client, started: started)
                }
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

    /// A page the person taught: press what they pressed, on a network they allowed.
    private func logInAsTaught(_ probe: [Hop], recipe: Recipe?, on network: LocalNetwork, client: PortalClient, started: Int) async {
        guard let recipe else {
            status = .unsupported("This login page isn't supported yet.")
            return schedule(nil)
        }
        let consent = Recipe.consent(on: network)
        let session = PortalSession(profile: consent ?? "page:this-connection", network: Self.name(of: probe), router: network.router, minutes: nil, details: [:])
        if stuckProfile == session.profile {
            status = .failed("The login page changed. Teach Wi-Fi Refill again.")
            return schedule(nil)
        }
        let known = consent.flatMap { id in profiles.first { $0.id == id } }
        if known?.allowed == false {
            status = .turnedOff(session.network)
            return schedule(nil)
        }
        if known == nil, allowedHere?.network != network {
            if notNowProfile == session.profile {
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
            if consent == nil { allowedHere = (network, session.network) } else { remember(session) }
        }

        status = .loggingIn(session.network)
        let begun = Date()
        let online = await LoginBrowser.replay(recipe, on: network, client: client)
        guard stillApplies(started) else { return }
        guard online else {
            if Self.screenLocked {
                // Not the page's fault: some pages only finish while the screen is on. Unlocking checks again.
                status = .failed("The screen was locked. Wi-Fi Refill tries again when you unlock your Mac.")
                Log.write("Login failed: taught page, screen locked.")
                return schedule(nil)
            }
            // Pressing again every few seconds would not help a page that changed; the person decides what next.
            stuckProfile = session.profile
            status = .failed("The login page changed. Teach Wi-Fi Refill again.")
            Log.write("Login failed: taught page.")
            return schedule(nil)
        }
        let page = Recipe.page(probe: probe, network: network)
        if !recipe.verified, var verified = recipes[page] {
            verified.verified = true
            recipes[page] = verified
        }
        if consent != nil { remember(session) }
        loggedIn(session)
        countReconnect()
        status = .loggedIn(session.network, until: sessionEnd)
        Log.write("Logged in (taught page, \(recipe.steps.count) presses) in \(String(format: "%.1f", Date().timeIntervalSince(begun))) s. Session: \(Self.describe(nil, learned: profiles.first { $0.id == session.profile }?.session)).")
        schedule(Schedule.next(after: .loggedIn, now: Date(), sessionEnd: sessionEnd, onCafe: true))
    }

    /// Shows the login page the network shows now, so the person logs in while Wi-Fi Refill learns their presses.
    /// Teaching it counts as allowing Wi-Fi Refill to log in on this network. Nil when there is no login page.
    /// Pausing, changing a network's setting or moving to another network cancels the lesson.
    func teach() async -> LoginBrowser.Lesson? {
        guard !teaching else { return nil }
        teaching = true
        generation += 1
        task?.cancel()
        timer?.invalidate()
        status = .teaching
        let started = generation
        let running = Task { await learn(started: started) }
        lesson = running
        let result = await running.value
        lesson = nil
        teaching = false
        restart(reason: "lesson")
        return result
    }

    private func learn(started: Int) async -> LoginBrowser.Lesson? {
        guard let network = Gateway.current() else { return nil }
        let client = portal.on(network)
        guard case .portal(let probe) = await client.probe() else { return nil }
        guard stillApplies(started) else { return .cancelled }
        lastProbe = probe
        let page = Recipe.page(probe: probe, network: network)
        let lesson = await LoginBrowser.teach(page: page, on: network, client: client)
        // A lesson that outlived a pause, a changed setting or a move to another network teaches nothing.
        guard stillApplies(started), Gateway.current() == network else { return .cancelled }
        if case .learned(let recipe) = lesson {
            recipes[page] = recipe
            stuckProfile = nil
            if let consent = Recipe.consent(on: network) {
                remember(PortalSession(profile: consent, network: Self.name(of: probe), router: network.router, minutes: nil, details: [:]))
                profiles = profiles.map { profile in
                    var profile = profile
                    if profile.id == consent { profile.allowed = true }
                    return profile
                }
            } else {
                allowedHere = (network, Self.name(of: probe))
            }
            Log.write("Learned a login page (\(recipe.steps.count) presses).")
        }
        return lesson
    }

    private static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// When the session just logged in to ends: as the login page says, or as this network's logouts showed. A page that
    /// does not say starts or goes on learning.
    private func loggedIn(_ session: PortalSession) {
        let now = Date()
        let learned = profiles.first { $0.id == session.profile }?.session
        sessionEnd = session.minutes.map { now.addingTimeInterval(TimeInterval($0 * 60)) } ?? learned.map { now.addingTimeInterval($0.expected) }
        let stored = profiles.contains { $0.id == session.profile }
        learning = session.minutes == nil && stored ? (session.profile, now, now) : nil
    }

    /// The network logged the Mac out: the session ended after the last check that was online, and before now.
    private func learnSessionLength(loggedOut now: Date) {
        defer { learning = nil }
        guard let learning, let length = SessionLength(loggedIn: learning.loggedIn, lastOnline: learning.lastOnline, loggedOut: now) else { return }
        profiles = profiles.map { profile in
            var profile = profile
            if profile.id == learning.profile { profile.session = profile.session?.adding(length) ?? length }
            return profile
        }
        Log.write("Session ended after \(Int(length.shortest / 60))-\(Int(length.longest / 60)) min.")
    }

    private static func describe(_ minutes: Int?, learned: SessionLength?) -> String {
        if let minutes { return "\(minutes) min" }
        if let learned { return "about \(Int(learned.expected / 60)) min, learned" }
        return "length unknown, learning"
    }

    /// What the menu calls a taught network: the login page's host.
    private static func name(of probe: [Hop]) -> String {
        probe.first?.location?.host ?? "Wi-Fi"
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
