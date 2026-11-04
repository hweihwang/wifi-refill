import Foundation

/// The last few times the internet stopped, with the step that broke and how long it lasted, kept on this Mac to look
/// back at. Nothing about the network, the person or the pages: a step and two times.
public struct ProblemLog: Codable, Equatable, Sendable {
    public struct Problem: Codable, Equatable, Sendable {
        public var leg: String
        public var start: Date
        /// Nil while it lasts.
        public var end: Date?

        public var broken: Leg? { Leg(rawValue: leg) }
    }

    public static let limit = 10
    public private(set) var problems: [Problem] = []

    public init() {}

    /// A broken step found now: a new problem, unless the same one is still going on. Another step breaking ends the
    /// last problem.
    public mutating func found(_ leg: Leg, at now: Date) {
        if let last = problems.last, last.end == nil {
            if last.leg == leg.rawValue { return }
            problems[problems.count - 1].end = now
        }
        problems.append(Problem(leg: leg.rawValue, start: now))
        problems = Array(problems.suffix(Self.limit))
    }

    /// The internet works again, or the step that broke works again.
    public mutating func cleared(at now: Date, only leg: Leg? = nil) {
        guard let last = problems.last, last.end == nil, leg == nil || last.leg == leg?.rawValue else { return }
        problems[problems.count - 1].end = now
    }
}

extension Traffic {
    /// Bytes both ways between two readings, the 32-bit counters' wrapping included.
    public static func bytes(from old: Traffic, to new: Traffic) -> UInt64 {
        UInt64(new.received &- old.received) + UInt64(new.sent &- old.sent)
    }
}
