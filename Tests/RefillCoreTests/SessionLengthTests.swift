import Foundation
import Testing
@testable import RefillCore

struct SessionLengthTests {
    let login = Date(timeIntervalSince1970: 1_793_600_000)

    func minutes(_ value: Double) -> Date { login.addingTimeInterval(value * 60) }

    /// The five-minute check finds a 60-minute session's end between minute 58 and 63.
    @Test func learnsFromTheChecksAroundALogout() throws {
        let length = try #require(SessionLength(loggedIn: login, lastOnline: minutes(58), loggedOut: minutes(63)))
        #expect(length.shortest == 58 * 60)
        #expect(length.longest == 63 * 60)
        #expect(length.expected == 58 * 60, "check closely from the earliest the session can end")
    }

    /// The next session is checked every few seconds from minute 58, so its end is caught within seconds.
    @Test func narrowsWithEachLogout() throws {
        let first = try #require(SessionLength(loggedIn: login, lastOnline: minutes(58), loggedOut: minutes(63)))
        let second = try #require(SessionLength(loggedIn: login, lastOnline: minutes(59.97), loggedOut: minutes(60.0)))
        let both = first.adding(second)
        #expect(both.shortest == second.shortest)
        #expect(both.longest == second.longest)
    }

    @Test func startsOverWhenTheCafeChangesItsSessions() throws {
        let hour = try #require(SessionLength(loggedIn: login, lastOnline: minutes(59.9), loggedOut: minutes(60)))
        let twoHours = try #require(SessionLength(loggedIn: login, lastOnline: minutes(119.9), loggedOut: minutes(120)))
        #expect(hour.adding(twoHours) == twoHours)
    }

    @Test func ignoresWhatIsNotASession() {
        #expect(SessionLength(loggedIn: login, lastOnline: minutes(1), loggedOut: minutes(2)) == nil, "a blip or an early end")
        #expect(SessionLength(loggedIn: login, lastOnline: minutes(30), loggedOut: minutes(25)) == nil)
        #expect(SessionLength(loggedIn: login, lastOnline: minutes(30), loggedOut: minutes(3000)) == nil, "the Mac slept for days")
    }
}
