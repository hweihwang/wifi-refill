import Foundation
import Testing
import WebKit
@testable import RefillCore

/// The page script in a real WebKit, on a plain-HTTP page like most login pages, where some browser APIs are missing.
@MainActor @Suite(.serialized) struct PageScriptTests {
    final class Inbox: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { messages.append(body) }
        }
    }

    let world = WKContentWorld.world(name: "WiFiRefill")

    func page(_ html: String, teaching: Bool = false) -> (WKWebView, Inbox) {
        let inbox = Inbox()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: PageScript.source(teaching: teaching), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        configuration.userContentController.add(inbox, contentWorld: world, name: "refill")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 760), configuration: configuration)
        web.loadHTMLString("<html><body>\(html)</body></html>", baseURL: URL(string: "http://portal.example/login")!)
        return (web, inbox)
    }

    /// The first report of what can be pressed, as the app decodes it.
    func report(_ inbox: Inbox) async throws -> (json: String, elements: [Element]) {
        for _ in 0..<100 {
            if let message = inbox.messages.first(where: { $0["kind"] as? String == "page" }), let list = message["elements"] {
                let data = try JSONSerialization.data(withJSONObject: list)
                return (String(decoding: data, as: UTF8.self), try JSONDecoder().decode([Element].self, from: data))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw URLError(.timedOut)
    }

    @Test func reportsWhatCanBePressedAndNothingTyped() async throws {
        let (web, inbox) = page("""
            <button id="go">Connect</button>
            <input id="phone" type="text" value="0901234567" onclick="void 0">
            <input type="submit" value="Accept">
            <input id="terms" type="checkbox" checked>
            <a href="/hidden" style="display:none">Hidden</a>
            <button disabled>Off</button>
            <div onclick="void 0"><span contenteditable="true">0901234567</span></div>
            """)
        let (json, elements) = try await report(inbox)
        _ = web
        #expect(elements.map(\.text) == ["Connect", "Accept", nil])
        #expect(elements.first?.id == "go")
        #expect(elements.last?.checked == true)
        #expect(elements.allSatisfy { $0.origin == "http://portal.example" && $0.path == "/login" && $0.token != nil })
        #expect(!json.contains("0901234567"), "a field's value never leaves the page")
    }

    @Test func pressesExactlyTheElementItWasToldTo() async throws {
        let (web, inbox) = page("""
            <button onclick="document.title = 'first'">Connect</button>
            <button onclick="document.title = 'second'">Connect</button>
            """)
        let (_, elements) = try await report(inbox)
        let second = try #require(elements.last?.token)
        let document = try #require(inbox.messages.first { $0["kind"] as? String == "page" }?["document"] as? String)
        func press(_ token: Int, in document: String) async throws -> Bool? {
            try await web.callAsyncJavaScript("return __refill.press(document, token)", arguments: ["document": document, "token": token], in: nil, contentWorld: world) as? Bool
        }
        #expect(try await press(second, in: "another document") == false, "a token only means something in its own document")
        #expect(try await press(999, in: document) == false)
        #expect(try await press(second, in: document) == true)
        #expect(try await web.evaluateJavaScript("document.title") as? String == "second")
    }

    /// While teaching, only a person's own clicks and typing count; a page cannot fake either.
    @Test func ignoresWhatThePageDoesByItself() async throws {
        let (web, inbox) = page("""
            <button id="go">Connect</button><input id="phone" type="text">
            """, teaching: true)
        try await Task.sleep(for: .milliseconds(300))
        _ = try await web.evaluateJavaScript("""
            document.getElementById('go').click();
            const phone = document.getElementById('phone');
            phone.value = '0901234567';
            phone.dispatchEvent(new Event('input', { bubbles: true }));
            1
            """)
        try await Task.sleep(for: .milliseconds(500))
        #expect(inbox.messages.isEmpty)
    }

    /// The page cannot reach the script's functions from its own world.
    @Test func keepsItsFunctionsFromThePage() async throws {
        let (web, inbox) = page("<button>Connect</button>")
        _ = try await report(inbox)
        #expect(try await web.evaluateJavaScript("typeof window.__refill") as? String == "undefined")
    }
}
