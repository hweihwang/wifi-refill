import Foundation
import Testing
import RefillCore

struct ProblemsTests {
    let now = Date(timeIntervalSince1970: 1_793_800_000)

    @Test func notesAProblemOnceAndWhenItEnds() {
        var log = ProblemLog()
        log.found(.internet, at: now)
        log.found(.internet, at: now.addingTimeInterval(60))
        log.cleared(at: now.addingTimeInterval(120))
        #expect(log.problems.count == 1)
        #expect(log.problems[0].broken == .internet)
        #expect(log.problems[0].end == now.addingTimeInterval(120))
    }

    @Test func anotherStepBreakingEndsTheLastProblem() {
        var log = ProblemLog()
        log.found(.router, at: now)
        log.found(.internet, at: now.addingTimeInterval(30))
        #expect(log.problems.map(\.broken) == [.router, .internet])
        #expect(log.problems[0].end == now.addingTimeInterval(30))
        #expect(log.problems[1].end == nil)
    }

    @Test func aVPNWorkingAgainOnlyEndsAVPNProblem() {
        var log = ProblemLog()
        log.found(.internet, at: now)
        log.cleared(at: now.addingTimeInterval(10), only: .vpn)
        #expect(log.problems[0].end == nil)
        log.cleared(at: now.addingTimeInterval(20))
        #expect(log.problems[0].end != nil)
    }

    @Test func keepsTheLastTen() {
        var log = ProblemLog()
        for minute in 0..<15 {
            log.found(minute.isMultiple(of: 2) ? .dns : .router, at: now.addingTimeInterval(Double(minute) * 60))
        }
        #expect(log.problems.count == ProblemLog.limit)
        #expect(log.problems.last?.start == now.addingTimeInterval(14 * 60))
    }

    @Test func countsBytesBothWaysAcrossTheCountersWrapping() {
        let before = Traffic(received: .max - 99, sent: 1_000)
        #expect(Traffic.bytes(from: before, to: Traffic(received: 900, sent: 3_000)) == 3_000)
    }
}
