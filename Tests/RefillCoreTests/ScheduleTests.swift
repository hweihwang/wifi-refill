import Foundation
import Testing
import RefillCore

struct ScheduleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func waitsForTheNextNetworkChangeOffCafeNetworks() {
        #expect(Schedule.next(after: .online, now: now, sessionEnd: nil, onCafe: false) == nil)
        #expect(Schedule.next(after: .offline, now: now, sessionEnd: nil, onCafe: false) == nil)
        #expect(Schedule.next(after: .unsupportedPage, now: now, sessionEnd: nil, onCafe: true) == nil)
        #expect(Schedule.next(after: .waitingForUser, now: now, sessionEnd: nil, onCafe: true) == nil)
    }

    @Test func checksRightWhenTheSessionEnds() {
        let end = now.addingTimeInterval(120)
        #expect(Schedule.next(after: .loggedIn, now: now, sessionEnd: end, onCafe: true) == 120)
        #expect(Schedule.next(after: .online, now: now, sessionEnd: end, onCafe: true) == 120)
    }

    @Test func checksEveryFewMinutesBeforeTheEndInCaseTheRouterEndsItEarly() {
        let end = now.addingTimeInterval(3600)
        #expect(Schedule.next(after: .loggedIn, now: now, sessionEnd: end, onCafe: true) == Schedule.watchdog)
        #expect(Schedule.next(after: .online, now: now, sessionEnd: end, onCafe: true) == Schedule.watchdog)
    }

    @Test func checksQuicklyJustAfterTheDueTime() {
        let end = now.addingTimeInterval(-10)
        #expect(Schedule.next(after: .online, now: now, sessionEnd: end, onCafe: true) == Schedule.ending)
    }

    @Test func fallsBackToTheWatchdogWhenTheEndIsLongPastOrUnknown() {
        let end = now.addingTimeInterval(-Schedule.endingWindow - 1)
        #expect(Schedule.next(after: .online, now: now, sessionEnd: end, onCafe: true) == Schedule.watchdog)
        #expect(Schedule.next(after: .online, now: now, sessionEnd: nil, onCafe: true) == Schedule.watchdog)
        #expect(Schedule.next(after: .loggedIn, now: now, sessionEnd: nil, onCafe: true) == Schedule.watchdog)
    }

    @Test func retriesWhileANewNetworkGetsAnAddress() {
        #expect(Schedule.next(after: .offline, now: now, sessionEnd: nil, onCafe: false, joinAttempt: 0) == 2)
        #expect(Schedule.next(after: .offline, now: now, sessionEnd: nil, onCafe: false, joinAttempt: 2) == 10)
        #expect(Schedule.next(after: .offline, now: now, sessionEnd: nil, onCafe: false, joinAttempt: 3) == nil)
        #expect(Schedule.next(after: .offline, now: now, sessionEnd: nil, onCafe: true, joinAttempt: 3) == Schedule.watchdog)
    }

    @Test func retriesAFailedLoginSoon() {
        #expect(Schedule.next(after: .loginFailed, now: now, sessionEnd: nil, onCafe: true) == Schedule.retry)
    }
}
