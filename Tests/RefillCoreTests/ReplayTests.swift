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
