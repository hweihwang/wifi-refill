import Foundation

/// When to look at the network again. Kept free of timers and I/O so every rule has a test.
///
/// Network changes and waking from sleep always trigger a check. On top of that, on a cafe network Wi-Fi Refill
/// checks right when the session is due to end and every few minutes before it, in case the router ends it early.
/// On any other network it checks nothing until the next network change.
public enum Schedule {
    /// The longest gap between checks on a cafe network.
    public static let watchdog: TimeInterval = 300
    /// Between checks once the session is due to end: routers end it a few seconds late.
    public static let ending: TimeInterval = 2
    /// How long to keep checking quickly after the due time before treating the end as unknown.
    public static let endingWindow: TimeInterval = 180
    /// Before trying again after a failed login.
    public static let retry: TimeInterval = 20
    /// Right after joining a network, while it is still getting an address.
    public static let joinRetries: [TimeInterval] = [2, 5, 10]

    public enum Outcome: Sendable {
        case online, loggedIn, loginFailed, unsupportedPage, waitingForUser, offline
    }

    /// Seconds until the next check, or nil to wait for the next network change or wake.
    /// `joinAttempt` counts offline results since the last network change.
    public static func next(after outcome: Outcome, now: Date, sessionEnd: Date?, onCafe: Bool, joinAttempt: Int = .max) -> TimeInterval? {
        switch outcome {
        case .loggedIn:
            return untilEnd(now: now, sessionEnd: sessionEnd)
        case .loginFailed:
            return retry
        case .unsupportedPage, .waitingForUser:
            return nil
        case .offline:
            if joinAttempt < joinRetries.count { return joinRetries[joinAttempt] }
            return onCafe ? watchdog : nil
        case .online:
            guard onCafe else { return nil }
            if let sessionEnd, now >= sessionEnd, now < sessionEnd.addingTimeInterval(endingWindow) { return ending }
            return untilEnd(now: now, sessionEnd: sessionEnd)
        }
    }

    private static func untilEnd(now: Date, sessionEnd: Date?) -> TimeInterval {
        guard let sessionEnd, sessionEnd > now else { return watchdog }
        return min(max(1, sessionEnd.timeIntervalSince(now)), watchdog)
    }
}
