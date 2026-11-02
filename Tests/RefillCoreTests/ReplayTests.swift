import Foundation
import Testing
@testable import RefillCore

/// Elements as the Awing page at a Highlands Coffee showed them on 2026-11-02, in a web view through the relay: the
/// optional details popup on /login, then the advert's connect button on /Connecting, which counts down for six seconds.
enum AwingPage {
    static let origin = "http://v1.awingconnect.vn"

    static func popup(_ path: String = "/login") -> [Element] {
        [
            Element(origin: origin, path: path, tag: "span", id: "lang-vi", text: "vie"),
            Element(origin: origin, path: path, tag: "button", id: "male-button", text: "Nam"),
            Element(origin: origin, path: path, tag: "button", id: "female-button", text: "Nữ"),
            Element(origin: origin, path: path, tag: "input", id: "popup-form__submit-btn", type: "submit", text: "Xác nhận & tiếp tục kết nối Internet"),
            Element(origin: origin, path: path, tag: "button", id: "remind-me", type: "submit", text: "Nhắc tôi sau"),
        ]
    }

    static func connect(_ text: String = "KẾT NỐI INTERNET (INTERNET ACCESS)") -> Element {
        Element(origin: origin, path: "/Connecting", tag: "button", id: "connectToInternet", text: text)
    }

    static let recipe = Recipe(page: "http://v1.awingconnect.vn/login?Qv&ap_mac&client_mac&hs_server", steps: [popup()[4], connect()])
}

struct ReplayTests {
    let start = Date(timeIntervalSince1970: 1_793_600_000)

    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// Decides, and confirms a press as the page would.
    func step(_ replay: inout Replay, _ page: [Element], _ second: TimeInterval) -> Replay.Action {
        let action = replay.decide(page, now: at(second))
        if case .press = action { replay.pressed(now: at(second)) }
        return action
    }

    @Test func pressesThroughThePopupAndWaitsForTheCountdown() {
        var replay = Replay(AwingPage.recipe, now: at(0))
        #expect(step(&replay, [], 0) == .wait, "the page is still loading")
        #expect(step(&replay, AwingPage.popup(), 1) == .press(4))
        for second in 0..<6 {
            let counting = AwingPage.connect("KẾT NỐI INTERNET SAU (CONNECTING IN) \(6 - second)S")
            #expect(step(&replay, [counting], 2 + Double(second)) == .wait, "not during the countdown")
        }
        #expect(step(&replay, [AwingPage.connect()], 8) == .press(0))
        #expect(step(&replay, [AwingPage.connect()], 9) == .finished, "each step is pressed once")
    }

    @Test func pressesAgainWhenThePageDidNotTakeThePress() {
        var replay = Replay(Recipe(page: "p", steps: [AwingPage.connect()]), now: at(0))
        #expect(replay.decide([AwingPage.connect()], now: at(1)) == .press(0))
        #expect(replay.decide([AwingPage.connect()], now: at(2)) == .press(0), "no confirmation, same step")
        #expect(!replay.pressedAny)
    }

    @Test func skipsThePopupWhenItDoesNotShow() {
        var replay = Replay(AwingPage.recipe, now: at(0))
        #expect(step(&replay, [AwingPage.connect()], 1) == .press(0))
        #expect(step(&replay, [], 2) == .finished)
    }

    @Test func pressesANewAdvertsButtonOnceItsTextSettles() {
        var replay = Replay(Recipe(page: "p", steps: [AwingPage.connect()]), now: at(0))
        let renamed = AwingPage.connect("TRUY CẬP INTERNET")
        #expect(step(&replay, [renamed], 1) == .wait)
        #expect(step(&replay, [renamed], 1 + Replay.settle) == .press(0))
    }

    @Test func settlingStartsOverWhenTheButtonGoesAway() {
        var replay = Replay(Recipe(page: "p", steps: [AwingPage.connect()]), now: at(0))
        let renamed = AwingPage.connect("TRUY CẬP INTERNET")
        #expect(step(&replay, [renamed], 1) == .wait)
        #expect(step(&replay, [], 5) == .wait)
        #expect(step(&replay, [renamed], 1 + Replay.settle) == .wait, "it was not there the whole time")
        #expect(step(&replay, [renamed], 1 + 2 * Replay.settle) == .press(0), "a full settle after it came back")
    }

    /// Another advert's button with the same words is another button: on 2026-11-02 pressing it did not log in.
    @Test func ignoresAnotherButtonWithTheSameWords() {
        var replay = Replay(Recipe(page: "p", steps: [AwingPage.connect()]), now: at(0))
        var logo = AwingPage.connect()
        logo.id = "logo_button"
        #expect(step(&replay, [logo], 1) == .wait)
    }

    @Test func neverPressesSomethingAmbiguous() {
        var replay = Replay(Recipe(page: "p", steps: [AwingPage.connect()]), now: at(0))
        let twins = [AwingPage.connect(), AwingPage.connect()]
        #expect(step(&replay, twins, 1) == .wait)
        #expect(step(&replay, twins, 2 + Replay.stepTimeout) == .stuck)
    }

    @Test func neverSkipsAnAmbiguousStep() {
        var replay = Replay(AwingPage.recipe, now: at(0))
        let twoRemindButtons = [AwingPage.popup()[4], AwingPage.popup()[4], AwingPage.connect()]
        #expect(step(&replay, twoRemindButtons, 1) == .wait)
    }

    @Test func ignoresLookalikesFromAnotherSite() {
        var replay = Replay(Recipe(page: "p", steps: [AwingPage.connect()]), now: at(0))
        var elsewhere = AwingPage.connect()
        elsewhere.origin = "http://ads.example"
        #expect(step(&replay, [elsewhere], 1) == .wait)
    }

    @Test func findsAnElementWithoutIDByItsText() {
        let accept = Element(origin: AwingPage.origin, path: "/", tag: "a", text: "Accept and connect")
        var replay = Replay(Recipe(page: "p", steps: [accept]), now: at(0))
        let other = Element(origin: AwingPage.origin, path: "/", tag: "a", text: "Terms of use")
        #expect(step(&replay, [other, accept], 1) == .press(1))
    }

    @Test func leavesACheckboxThatIsAlreadyTicked() {
        let terms = Element(origin: AwingPage.origin, path: "/login", tag: "input", id: "agree", type: "checkbox", checked: true)
        var replay = Replay(Recipe(page: "p", steps: [terms, AwingPage.connect()]), now: at(0))
        var ticked = terms
        ticked.checked = true
        #expect(step(&replay, [ticked, AwingPage.connect()], 1) == .press(1), "only the button is pressed")
    }

    @Test func neverSkipsACheckbox() {
        let terms = Element(origin: AwingPage.origin, path: "/login", tag: "input", id: "agree", type: "checkbox", checked: true)
        var replay = Replay(Recipe(page: "p", steps: [terms, AwingPage.connect()]), now: at(0))
        #expect(step(&replay, [AwingPage.connect()], 1) == .wait)
        #expect(step(&replay, [AwingPage.connect()], 2 + Replay.stepTimeout) == .stuck)
    }

    @Test func keysAPageByItsShapeNotItsValues() {
        let a = URL(string: "http://v1.awingconnect.vn/login?client_mac=02-00-00-00-00-01&ap_mac=x&hs_server=10.29.64.2&Qv=a=b@c")!
        let b = URL(string: "http://v1.awingconnect.vn/login?Qv=other&hs_server=10.0.0.2&client_mac=y&ap_mac=z")!
        #expect(Recipe.key(for: a) == AwingPage.recipe.page)
        #expect(Recipe.key(for: a) == Recipe.key(for: b))
        #expect(Recipe.key(for: URL(string: "https://v1.awingconnect.vn/login?Qv=1")!) != Recipe.key(for: URL(string: "http://v1.awingconnect.vn/login?Qv=1")!))
        #expect(Recipe.key(for: URL(string: "http://v1.awingconnect.vn:8080/login")!) == "http://v1.awingconnect.vn:8080/login")
    }
}

struct SharedRecipeTests {
    @Test func sharesButtonsNeverValuesOrSessions() throws {
        var recipe = AwingPage.recipe
        recipe.verified = true
        recipe.steps[0].token = 42
        let shared = recipe.shared()
        let decoded = try JSONDecoder().decode(Recipe.self, from: Data(shared.utf8))
        #expect(decoded.page == "http://*.awingconnect.vn/login?*&ap_mac&client_mac&*", "the address as reports show it: names, never values")
        #expect(!decoded.verified)
        #expect(decoded.steps.allSatisfy { $0.token == nil })
        #expect(decoded.steps.map(\.id) == ["remind-me", "connectToInternet"])
        #expect(!shared.contains("token"))
    }

    @Test func sharesNothingThatLooksLikeAnAddressOrAnIdentifier() throws {
        let step = Element(origin: "https://guest.cafe-example.com", path: "/guest/1204/JaneDoe", tag: "button", id: "connect-8f3a9c21d0",
                           name: "02:00:00:00:00:01", label: "Kết nối", text: "Connect as jane@example.com")
        let shared = try JSONDecoder().decode(Recipe.self, from: Data(Recipe(page: "https://guest.cafe-example.com/guest/1204?mac=02:00", steps: [step]).shared().utf8))
        let sent = try #require(shared.steps.first)
        #expect(shared.page == "https://*.cafe-example.com/guest/*?mac")
        #expect(sent.origin == "https://*.cafe-example.com")
        #expect(sent.path == "/guest/*/*")
        #expect(sent.id == "*")
        #expect(sent.name == "*")
        #expect(sent.label == "Kết nối", "a caption in any language stays")
        #expect(sent.text == "*")
    }

    @Test func findsTheSharedRecipeForAPageWhateverItsQuery() {
        let awing = [Hop(url: PortalClient.probeURL, status: 302, location: URL(string: AwingFixture.login), body: "")]
        let elsewhere = [Hop(url: PortalClient.probeURL, status: 302, location: URL(string: "http://login.hotel.example/portal?mac=1"), body: "")]
        #expect(Recipe.builtIn(for: awing)?.page == "http://v1.awingconnect.vn/login")
        #expect(Recipe.builtIn(for: elsewhere) == nil)
        #expect(Recipe.builtIn(for: [Hop(url: PortalClient.probeURL, status: 200, location: nil, body: "<html>")]) == nil)
    }

    /// The shipped Awing recipe on the page as recorded: popup, countdown, connect.
    @Test func theShippedAwingRecipeFitsTheRecordedPage() throws {
        let recipe = try #require(Recipe.builtIn.first { $0.page == "http://v1.awingconnect.vn/login" })
        let start = Date(timeIntervalSince1970: 1_793_600_000)
        var replay = Replay(recipe, now: start)
        #expect(replay.decide(AwingPage.popup(), now: start) == .press(4))
        replay.pressed(now: start)
        #expect(replay.decide([AwingPage.connect("KẾT NỐI INTERNET SAU (CONNECTING IN) 3S")], now: start.addingTimeInterval(3)) == .wait)
        #expect(replay.decide([AwingPage.connect()], now: start.addingTimeInterval(7)) == .press(0))
    }
}
