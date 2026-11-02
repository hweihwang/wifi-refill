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

    /// What Share This Login Page… sends: the page's address without its query, and each step's element by tag, id,
    /// name, type, role, label and text. Never a value typed, never a session.
    func shared() -> String {
        var copy = self
        copy.page = String(page.prefix { $0 != "?" })
        copy.verified = false
        copy.steps = steps.map { var step = $0; step.token = nil; return step }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(copy)) ?? Data(), as: UTF8.self)
    }
}
