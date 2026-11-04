import CryptoKit
import Foundation

/// The buttons a person pressed to log in on a login page, and the fields they typed into if they chose to let Wi-Fi
/// Refill remember, learned while they did it, so Wi-Fi Refill can do it again when the network logs them out. What
/// they typed is never part of a recipe: it is kept in the Keychain (see `Typed`).
public struct Recipe: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = Recipe.currentVersion
    /// The login page it is for; see `key(for:)`.
    public var page: String
    public var steps: [Element]
    /// False until pressing the steps has logged in by itself once.
    public var verified = false

    public init(page: String, steps: [Element]) {
        self.page = page
        self.steps = steps
    }

    /// Scheme, host, port, path and the names of the query, never its values, so the stores of one chain share a page.
    /// Only a way to find a recipe: whether to use it on a network is the person's choice, asked per network.
    public static func key(for url: URL) -> String {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let names = Set((parts?.percentEncodedQueryItems ?? []).map(\.name)).sorted()
        let port = parts?.port.map { ":\($0)" } ?? ""
        return "\(parts?.scheme ?? "")://\(parts?.host ?? "")\(port)\(parts?.path ?? "")" + (names.isEmpty ? "" : "?" + names.joined(separator: "&"))
    }

    /// The page a check met: where Apple's check page was sent, or, when the network answered it with a page of its
    /// own, that network.
    public static func page(probe: [Hop], network: LocalNetwork) -> String {
        probe.first?.location.map(key(for:)) ?? "inline:" + digest(network.signature ?? network.router)
    }

    /// Whom the person allowed to log in by recipe: one network, by macOS's name for it, hashed so no hardware address
    /// is stored. Nil when macOS has no name for it: two cafes can share a router address, so such a network gets no
    /// lasting permission.
    public static func consent(on network: LocalNetwork) -> String? {
        network.signature.map { "page:" + digest($0) }
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// A button, link, checkbox or other clickable element, as the page script describes it.
public struct Element: Codable, Equatable, Sendable {
    /// The frame's origin, which must match, and path, which only helps.
    public var origin: String
    public var path: String
    public var tag: String
    public var id: String?
    public var name: String?
    public var type: String?
    public var role: String?
    public var label: String?
    /// Visible text, whitespace collapsed.
    public var text: String?
    /// For a checkbox or radio button: in a step, the state the person left it in; on the page, its state now.
    public var checked: Bool?
    /// A field to type into rather than a button to press.
    public var fill: Bool?
    /// On the page only: the page script's handle for this very element, to press exactly what was matched.
    public var token: Int?

    public init(origin: String, path: String, tag: String, id: String? = nil, name: String? = nil, type: String? = nil,
                role: String? = nil, label: String? = nil, text: String? = nil, checked: Bool? = nil, fill: Bool? = nil, token: Int? = nil) {
        self.origin = origin
        self.path = path
        self.tag = tag
        self.id = id
        self.name = name
        self.type = type
        self.role = role
        self.label = label
        self.text = text
        self.checked = checked
        self.fill = fill
        self.token = token
    }

    /// Whether a step can be found again at all: by its id, text, label or name.
    public var identifiable: Bool {
        [id, text, label, name].contains { !($0 ?? "").isEmpty }
    }

    /// A checkbox, radio button or field sets something the page needs; a missing button may just be a popup that did
    /// not show this time.
    var mayBeAbsent: Bool { checked == nil && fill != true }

    enum Found: Equatable {
        case absent
        /// Two elements fit about as well: nothing is pressed, and the step is not skipped either.
        case ambiguous
        /// The one element that is this step, and whether its text is what it was when the person pressed it.
        case unique(index: Int, sameText: Bool)
    }

    /// An element taught with an id is that id, whatever its text says now (a countdown, a new advert); one without is
    /// its text, or failing that its label or name. The rest only breaks ties.
    func find(in page: [Element]) -> Found {
        func same(_ a: String?, _ b: String?) -> Bool {
            guard let a, let b, !a.isEmpty else { return false }
            return a.caseInsensitiveCompare(b) == .orderedSame
        }
        let scored = page.enumerated().compactMap { index, element -> (Int, Int)? in
            guard element.origin == origin, element.tag == tag, (element.fill == true) == (fill == true) else { return nil }
            let identified = if let id, !id.isEmpty { same(id, element.id) }
                else if let text, !text.isEmpty { same(text, element.text) }
                else { same(label, element.label) || same(name, element.name) }
            guard identified else { return nil }
            let score = (same(text, element.text) ? 2 : 0) + (same(label, element.label) ? 1 : 0) + (same(name, element.name) ? 1 : 0)
                + (same(type, element.type) ? 1 : 0) + (same(role, element.role) ? 1 : 0) + (path == element.path ? 1 : 0)
            return (index, score)
        }.sorted { $0.1 > $1.1 }
        guard let best = scored.first else { return .absent }
        guard scored.count == 1 || best.1 - scored[1].1 >= 2 else { return .ambiguous }
        return .unique(index: best.0, sameText: text.map { same($0, page[best.0].text) } ?? true)
    }
}

/// Presses a recipe's steps in order as the page shows them. Pure, so every rule has a test; the browser feeds it
/// what the page shows, does what it says, and reports each press the page confirmed.
public struct Replay: Sendable {
    public enum Action: Equatable, Sendable {
        case wait
        /// Press the element at this index of what the page showed, then call `pressed` if the page confirms it.
        case press(Int)
        /// Type the taught value of step `next` into the field at this index, then call `pressed` if the page confirms it.
        case fill(Int)
        /// Every step is pressed; wait for the network to open.
        case finished
        /// A step did not appear in time, or stayed ambiguous: the page changed.
        case stuck
    }

    /// How long a step may take to appear and become ready, ads and countdowns included.
    public static let stepTimeout: TimeInterval = 40
    /// A matched button whose text differs from when it was taught (a countdown, a new advert) is pressed once its text
    /// has stayed the same, on the same one button, this long.
    public static let settle: TimeInterval = 10

    public let steps: [Element]
    public private(set) var next = 0
    /// Whether any step has been pressed: after that, starting over could submit the page twice.
    public var pressedAny: Bool { pressedCount > 0 }
    private var pressedCount = 0
    private var stepStarted: Date
    private var lastText: String?
    private var textSince: Date

    public init(_ recipe: Recipe, now: Date) {
        steps = recipe.steps
        stepStarted = now
        textSince = now
    }

    public mutating func decide(_ page: [Element], now: Date) -> Action {
        guard next < steps.count else { return .finished }
        let step = steps[next]
        switch step.find(in: page) {
        case .unique(let index, let sameText):
            if step.fill == true { return .fill(index) }
            if let wanted = step.checked, page[index].checked == wanted {
                advance(now)
                return decide(page, now: now)
            }
            if sameText || settled(page[index].text, now: now) { return .press(index) }
        case .ambiguous:
            unsettle(now)
        case .absent:
            unsettle(now)
            // A popup that did not show this time: skip absent buttons, never a checkbox, when a later step is there.
            if let later = steps.indices[(next + 1)...].first(where: { steps[$0].find(in: page) != .absent }),
               case .unique = steps[later].find(in: page),
               steps[next..<later].allSatisfy({ $0.mayBeAbsent && $0.find(in: page) == .absent }) {
                next = later
                stepStarted = now
                return decide(page, now: now)
            }
        }
        return now.timeIntervalSince(stepStarted) > Self.stepTimeout ? .stuck : .wait
    }

    /// The page confirmed the press `decide` asked for.
    public mutating func pressed(now: Date) {
        pressedCount += 1
        advance(now)
    }

    private mutating func advance(_ now: Date) {
        next += 1
        stepStarted = now
        unsettle(now)
    }

    private mutating func unsettle(_ now: Date) {
        lastText = nil
        textSince = now
    }

    private mutating func settled(_ text: String?, now: Date) -> Bool {
        if text != lastText {
            lastText = text
            textSince = now
        }
        return now.timeIntervalSince(textSince) >= Self.settle
    }
}
