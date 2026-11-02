import Foundation

/// Login pages people taught and shared, checked on a real network before they ship (see CONTRIBUTING.md). They work
/// like a page the person taught themselves, except that Wi-Fi Refill asks before using one on a network.
public extension Recipe {
    static let builtIn: [Recipe] = [
        // Awing Free Wi-Fi at a Highlands Coffee, 2026-11-02: the optional details popup, then the advert's connect
        // button after its countdown. The AwingExtreme driver logs in without the page; this takes over when the
        // page's form changes beyond what the driver knows.
        Recipe(page: "http://v1.awingconnect.vn/login", steps: [
            Element(origin: "http://v1.awingconnect.vn", path: "/login", tag: "button", id: "remind-me", type: "submit", text: "Nhắc tôi sau"),
            Element(origin: "http://v1.awingconnect.vn", path: "/Connecting", tag: "button", id: "connectToInternet", text: "KẾT NỐI INTERNET (INTERNET ACCESS)"),
        ]),
    ]

    /// The shared recipe for the page a check met, matched by scheme, host, port and path.
    static func builtIn(for probe: [Hop]) -> Recipe? {
        guard let location = probe.first?.location else { return nil }
        let page = String(key(for: location).prefix { $0 != "?" })
        return builtIn.first { $0.page == page }
    }

    /// What Share This Login Page… sends, built like the login page report: addresses with unfamiliar names replaced,
    /// and each step's element by tag, type and role from short lists, and by id, name, label and text only where
    /// they read like a button's caption. Never a value typed, a session, or anything that looks like an address.
    func shared() -> String {
        var copy = self
        copy.page = URL(string: page).map(PortalReport.describe) ?? "*"
        copy.verified = false
        copy.steps = steps.map { step in
            var shared = step
            shared.origin = URL(string: step.origin).map(PortalReport.describe) ?? "*"
            shared.path = step.path.split(separator: "/", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : PortalReport.known(String($0)) }.joined(separator: "/")
            shared.tag = Self.sharedTags.contains(step.tag) ? step.tag : "*"
            shared.type = step.type.map { Self.sharedTypes.contains($0) ? $0 : "*" }
            shared.role = step.role.map { Self.sharedTypes.contains($0) ? $0 : "*" }
            shared.id = Self.caption(step.id)
            shared.name = Self.caption(step.name)
            shared.label = Self.caption(step.label)
            shared.text = Self.caption(step.text)
            shared.token = nil
            return shared
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(copy)) ?? Data(), as: UTF8.self)
    }

    private static let sharedTags: Set = ["a", "button", "div", "img", "input", "label", "li", "span"]
    private static let sharedTypes: Set = ["button", "checkbox", "image", "link", "radio", "reset", "submit"]

    /// Kept only when it reads like a button's caption or name: letters in any script, spaces and a little punctuation,
    /// at most two digits, at most 60 characters. Anything else could be a hardware address, an address, a phone number
    /// or a session, and becomes *.
    static func caption(_ text: String?) -> String? {
        guard let text else { return nil }
        let punctuation: Set<Character> = [" ", "-", "_", "(", ")", ".", ",", "!", "?", "&", "'", "’", ":"]
        let plain = text.count <= 60 && text.filter(\.isNumber).count <= 2
            && text.allSatisfy { $0.isLetter || $0.isNumber || punctuation.contains($0) }
        return plain ? text : "*"
    }
}
