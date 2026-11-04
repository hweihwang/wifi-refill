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
        let buttons = elements.filter { $0.fill != true }
        #expect(buttons.map(\.text) == ["Connect", "Accept", nil])
        #expect(buttons.first?.id == "go")
        #expect(buttons.last?.checked == true)
        // The field can be filled again; what the editable span holds is no field Wi-Fi Refill fills.
        #expect(elements.filter { $0.fill == true }.map(\.id) == ["phone"])
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

    /// Fills a field through its own setter and sends the events typing would, so the page's code sees the value.
    @Test func fillsAFieldTheWayTypingWould() async throws {
        let (web, inbox) = page("""
            <input id="phone" type="tel" placeholder="Phone number" oninput="document.title = 'typed ' + this.value">
            """)
        let (_, elements) = try await report(inbox)
        let field = try #require(elements.first { $0.fill == true })
        #expect(field.text == "Phone number")
        let document = try #require(inbox.messages.first { $0["kind"] as? String == "page" }?["document"] as? String)
        let filled = try await web.callAsyncJavaScript("return __refill.fill(document, token, value)", arguments: ["document": document, "token": field.token ?? 0, "value": "0901234567"], in: nil, contentWorld: world) as? Bool
        #expect(filled == true)
        #expect(try await web.evaluateJavaScript("document.title") as? String == "typed 0901234567")
    }

    /// While teaching, what the person really types goes with the press that sends it, field by field.
    @Test func learnsWhatThePersonTypesWithThePressThatSendsIt() async throws {
        let (web, inbox) = page("""
            <form onsubmit="return false"><input id="room" name="room" placeholder="Room"><button id="go">Connect</button></form>
            """, teaching: true)
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))
        _ = try await web.evaluateJavaScript("document.getElementById('room').focus(); 1")
        window.makeFirstResponder(web)
        for character in "1204" {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let key = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: String(character), charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0)!
                window.sendEvent(key)
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        let box = try #require(try await web.evaluateJavaScript("const r = document.getElementById('go').getBoundingClientRect(); [r.x + r.width / 2, r.y + r.height / 2]") as? [Double])
        let point = web.convert(NSPoint(x: box[0], y: web.isFlipped ? box[1] : web.bounds.height - box[1]), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let click = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(click)
        }
        try await Task.sleep(for: .milliseconds(500))
        let kinds = inbox.messages.compactMap { $0["kind"] as? String }
        #expect(kinds == ["fill", "press"])
        let fill = try #require(inbox.messages.first { $0["kind"] as? String == "fill" })
        #expect(fill["value"] as? String == "1204")
        #expect((fill["element"] as? [String: Any])?["name"] as? String == "room")
        #expect((fill["element"] as? [String: Any])?["fill"] as? Bool == true)
        #expect(((inbox.messages.last?["element"] as? [String: Any])?["id"] as? String) == "go")
    }

    /// Return in a field sends the form without a click: that is learned as a press of the form's own button.
    @Test func learnsReturnAsAPressOfTheFormsButton() async throws {
        let (web, inbox) = page("""
            <form onsubmit="return false"><input id="voucher" name="voucher"><input type="submit" id="send" value="Send"></form>
            """, teaching: true)
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))
        _ = try await web.evaluateJavaScript("document.getElementById('voucher').focus(); 1")
        window.makeFirstResponder(web)
        for (character, code) in [("7", UInt16(26)), ("\r", UInt16(36))] {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!)
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(inbox.messages.compactMap { $0["kind"] as? String } == ["fill", "press"])
        #expect(inbox.messages.first?["value"] as? String == "7")
        #expect(((inbox.messages.last?["element"] as? [String: Any])?["id"] as? String) == "send")
    }
}
