import Foundation

/// When to look at the network again. Kept free of timers and I/O so every rule has a test.
///
/// Network changes and waking from sleep always trigger a check. On top of that, on a cafe network Wi-Fi Refill
/// checks right when the session is due to end and every few minutes before it, in case the router ends it early.
/// On any other network it checks every few minutes for the first hours after joining, because a cafe network where
/// the person is already logged in looks like any other until its session ends, and then stops.
public enum Schedule {
    /// The longest gap between checks on a cafe network.
    public static let watchdog: TimeInterval = 300
    /// Between checks once the session is due to end: routers end it a few seconds late.
    public static let ending: TimeInterval = 2
    /// How long to keep checking quickly after the due time before treating the end as unknown.
    public static let endingWindow: TimeInterval = 180
    /// Before trying again after a failed login: soon at first, since a router often refuses for a moment right as a
    /// session ends, then less often.
    public static let retries: [TimeInterval] = [3, 8, 20]
    /// On a cafe network, how long a check that finds no internet is taken for the login page on its way rather than
    /// a broken network.
    public static let pageGrace: TimeInterval = 20
    /// Right after joining a network, while it is still getting an address.
    public static let joinRetries: [TimeInterval] = [2, 5, 10]
    /// How long after joining an unknown network Wi-Fi Refill keeps looking for a login page.
    public static let discoveryWindow: TimeInterval = 3 * 60 * 60

    public enum Outcome: Sendable {
        case online, loggedIn, loginFailed, unsupportedPage, waitingForUser, offline
    }

    /// Seconds until the next check, or nil to wait for the next network change or wake.
    /// `joinAttempt` counts offline results since the last network change; `joined` is when the Mac joined this network.
    /// Seconds before trying again after `failures` failed logins in a row.
    public static func retry(after failures: Int) -> TimeInterval {
        retries[min(max(failures - 1, 0), retries.count - 1)]
    }

    public static func next(after outcome: Outcome, now: Date, sessionEnd: Date?, onCafe: Bool, joinAttempt: Int = .max, joined: Date = .distantPast) -> TimeInterval? {
        switch outcome {
        case .loggedIn:
            return untilEnd(now: now, sessionEnd: sessionEnd)
        case .loginFailed:
            return retry(after: 1)
        case .unsupportedPage, .waitingForUser:
            return nil
        case .offline:
            if joinAttempt < joinRetries.count { return joinRetries[joinAttempt] }
            return onCafe ? watchdog : nil
        case .online:
            guard onCafe else { return now.timeIntervalSince(joined) < discoveryWindow ? watchdog : nil }
            if let sessionEnd, now >= sessionEnd, now < sessionEnd.addingTimeInterval(endingWindow) { return ending }
            return untilEnd(now: now, sessionEnd: sessionEnd)
        }
    }

    private static func untilEnd(now: Date, sessionEnd: Date?) -> TimeInterval {
        guard let sessionEnd, sessionEnd > now else { return watchdog }
        return min(max(1, sessionEnd.timeIntervalSince(now)), watchdog)
    }
}
