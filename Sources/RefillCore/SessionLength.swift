import Foundation

/// How long a network keeps a login, learned from the network itself when its login page does not say.
///
/// Each time the network logs the Mac out, the session ended somewhere between the last check that was still online
/// and the first that met the login page. Sessions of the same length narrow that window from both sides; one that
/// does not fit (the cafe changed its setting, the Mac slept through the end) starts over from it.
public struct SessionLength: Codable, Equatable, Sendable {
    /// Seconds: the session lasted at least `shortest` and at most `longest`.
    public private(set) var shortest: TimeInterval
    public private(set) var longest: TimeInterval

    /// Shorter than this is not a session the network ended, but a blip, a restart or a router ending it early.
    static let minimum: TimeInterval = 5 * 60

    /// What one logout shows, or nil when it shows nothing useful.
    public init?(loggedIn: Date, lastOnline: Date, loggedOut: Date) {
        let shortest = lastOnline.timeIntervalSince(loggedIn), longest = loggedOut.timeIntervalSince(loggedIn)
        guard shortest >= Self.minimum, longest >= shortest, longest <= 24 * 60 * 60 else { return nil }
        self.shortest = shortest
        self.longest = longest
    }

    /// This length and another logout's, narrowed to what both allow.
    public func adding(_ other: SessionLength) -> SessionLength {
        guard other.shortest <= longest, shortest <= other.longest else { return other }
        var both = self
        both.shortest = max(shortest, other.shortest)
        both.longest = min(longest, other.longest)
        return both
    }

    /// When to start checking closely: the earliest the session can end. From there Wi-Fi Refill checks every few
    /// seconds, so the next logout pins the end down.
    public var expected: TimeInterval { shortest }
}
