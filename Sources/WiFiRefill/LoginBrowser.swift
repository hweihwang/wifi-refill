import AppKit
import Network
import RefillCore
import WebKit

/// Runs a login page in a private web view: to learn which buttons the person presses, and later to press them again.
///
/// The page's own scripts run as in any browser, in a store that keeps nothing once it closes. Every connection goes
/// through a WiFiRelay, out on the Wi-Fi, so a VPN cannot hide the page; WebRTC, which would not use the relay, is off.
/// Wi-Fi Refill's script runs in a content world of its own, which the page's scripts cannot reach: it reports what can
/// be pressed, records the person's presses while teaching, and presses for them during a replay. What the person types
/// is learned only if they tick Remember What I Type, and then kept in the Keychain, never in the recipe.
@MainActor
final class LoginBrowser: NSObject {
    enum Lesson {
        case learned(Recipe)
        case typed
        case opensWindows
        case tooManyPresses
        case unclearButton
        case nothingPressed
        case cancelled
    }

    /// The whole replay, from loading the page to Apple's check page coming through.
    static let replayDeadline: TimeInterval = 120
    /// Fresh starts within the deadline, for pages that change between visits, such as rotating adverts.
    static let attempts = 3
    static let maxSteps = 20

    private let world = WKContentWorld.world(name: "WiFiRefill")
    private let relay: WiFiRelay
    private let teaching: Bool
    private let webView: WKWebView
    private let window: NSWindow
    private let banner = NSTextField(wrappingLabelWithString: "")
    private let remember = NSButton(checkboxWithTitle: L("Remember what I type on this page"), target: nil, action: nil)
    /// What the person typed, by the step it fills; kept only if the lesson is learned and they ticked the box.
    private var typed: [Int: String] = [:]
    /// What each document last reported it can press, by the document's own id.
    private var documents: [String: (frame: WKFrameInfo, elements: [Element], seen: Date)] = [:]
    private var presses: [Element] = []
    /// Why this page cannot be learned, once that is clear; the person can still log in.
    private var unlearnable: Lesson?
    private var closed = false

    /// Presses `recipe`'s steps on the page the network shows now. True once Apple's check page comes through. Ends by
    /// the deadline whatever the page does, and as soon as the caller is cancelled.
    static func replay(_ recipe: Recipe, on network: LocalNetwork, client: PortalClient) async -> Bool {
        guard let relay = try? await WiFiRelay.start(on: network) else { return false }
        let browser = LoginBrowser(relay: relay, teaching: false)
        // The first of the replay, the deadline and cancellation decides. A page can hang a press indefinitely, so
        // the browser and relay close at once, without waiting for the replay to notice.
        let outcome = Outcome()
        let work = Task { outcome.finish(await browser.runReplay(recipe, client: client)) }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(replayDeadline + 5))
            outcome.finish(false)
        }
        let online = await withTaskCancellationHandler {
            await withCheckedContinuation { outcome.wait($0) }
        } onCancel: {
            Task { @MainActor in outcome.finish(false) }
        }
        work.cancel()
        deadline.cancel()
        browser.close()
        return online
    }

    /// Resumes its waiter once, with whichever result comes first.
    @MainActor
    private final class Outcome {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?

        func wait(_ continuation: CheckedContinuation<Bool, Never>) {
            if let result { continuation.resume(returning: result) } else { self.continuation = continuation }
        }

        func finish(_ value: Bool) {
            guard result == nil else { return }
            result = value
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    /// Shows the login page so the person can log in while Wi-Fi Refill learns which buttons they press.
    static func teach(page: String, on network: LocalNetwork, client: PortalClient) async -> Lesson {
        guard let relay = try? await WiFiRelay.start(on: network) else { return .cancelled }
        let browser = LoginBrowser(relay: relay, teaching: true)
        let lesson = await browser.runLesson(page: page, client: client)
        browser.close()
        return lesson
    }

    private init(relay: WiFiRelay, teaching: Bool) {
        self.relay = relay
        self.teaching = teaching
        let store = WKWebsiteDataStore.nonPersistent()
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: relay.port)!))
        proxy.applyCredential(username: relay.username, password: relay.password)
        // Never fall back to a direct connection, which a VPN would swallow.
        proxy.allowFailover = false
        store.proxyConfigurations = [proxy]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let controller = configuration.userContentController
        // WebRTC opens its own sockets, past the relay. WebKit's switch for it is not public; without it, take the API
        // away from the page before its scripts run.
        if !Self.setPrivate(configuration.preferences, "_setPeerConnectionEnabled:", false) {
            let removal = "for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel']) { try { delete window[name]; } catch (e) {} }"
            controller.addUserScript(WKUserScript(source: removal, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        // No login page needs the camera or microphone; asking is refused below in any case.
        Self.setPrivate(configuration.preferences, "_setMediaDevicesEnabled:", false)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 760), configuration: configuration)
        webView.customUserAgent = PortalClient.userAgent
        // WebKit pauses animations on a page it thinks nobody sees, and login pages wait for them (Awing's does). Behind
        // other windows, or while the screen is locked, that is every page. WebKit's own switch for this is not public;
        // without it, pages that wait for an animation only log in while the screen is on.
        Self.setPrivate(webView, "_setWindowOcclusionDetectionEnabled:", false)
        if teaching {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        } else {
            // Out of sight, but in a window: a web view without one never runs its page's animations.
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
        super.init()
        controller.addUserScript(WKUserScript(source: PageScript.source(teaching: teaching), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.add(self, contentWorld: world, name: "refill")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.isReleasedWhenClosed = false
        window.delegate = self
        if teaching {
            window.title = L("Teach Wi-Fi Refill")
            banner.stringValue = L("Log in as you usually do. Wi-Fi Refill remembers the buttons you press and does it for you each time this network logs you out. If the page asks you to type, such as a phone or room number, tick the box below and it types that for you too.")
            banner.preferredMaxLayoutWidth = 440
            remember.state = .off
            let stack = NSStackView(views: [banner, remember, webView])
            stack.orientation = .vertical
            stack.spacing = 10
            stack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)
            window.contentView = stack
            banner.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                banner.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20),
                banner.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20),
                remember.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20),
                webView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            ])
            window.center()
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.contentView = webView
            window.orderBack(nil)
        }
        // Start where the network sends Apple's check page, as a browser would: some networks answer it in place.
        webView.load(URLRequest(url: PortalClient.probeURL))
    }

    /// Calls a private WebKit setter if this macOS has it.
    @discardableResult
    private static func setPrivate(_ object: NSObject, _ name: String, _ value: Bool) -> Bool {
        let selector = Selector((name))
        guard object.responds(to: selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(object.method(for: selector), to: Setter.self)(object, selector, value)
        return true
    }

    private func close() {
        closed = true
        relay.stop()
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        window.delegate = nil
        window.orderOut(nil)
        window.close()
    }

    // MARK: Teaching and replaying

    private func runLesson(page: String, client: PortalClient) async -> Lesson {
        while !closed, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !closed, !Task.isCancelled, await client.probe() == .online else { continue }
            if let unlearnable { return unlearnable }
            if presses.isEmpty { return .nothingPressed }
            if !typed.isEmpty, remember.state != .on { return .typed }
            Typed.save(typed, page: page)
            return .learned(Recipe(page: page, steps: presses))
        }
        return .cancelled
    }

    private func runReplay(_ recipe: Recipe, client: PortalClient) async -> Bool {
        let values = recipe.steps.contains { $0.fill == true } ? Typed.load(page: recipe.page) : [:]
        var replay = Replay(recipe, now: Date())
        let deadline = Date().addingTimeInterval(Self.replayDeadline)
        var probed = Date()
        var attempts = 1
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return false }
            if Date().timeIntervalSince(probed) >= 2 {
                if await client.probe() == .online { return true }
                probed = Date()
                guard !Task.isCancelled else { return false }
            }
            let elements = snapshot()
            switch replay.decide(elements.map(\.element), now: Date()) {
            case .press(let index):
                let (document, frame, element) = elements[index]
                let pressed = try? await webView.callAsyncJavaScript(
                    "return __refill.press(document, token)", arguments: ["document": document, "token": element.token ?? 0], in: frame, contentWorld: world
                ) as? Bool
                guard !Task.isCancelled else { return false }
                if pressed == true { replay.pressed(now: Date()) }
            case .fill(let index):
                // Nothing kept for this field, as after the Keychain item was removed: the page needs teaching again.
                guard let value = values[replay.next] else { return false }
                let (document, frame, element) = elements[index]
                let filled = try? await webView.callAsyncJavaScript(
                    "return __refill.fill(document, token, value)", arguments: ["document": document, "token": element.token ?? 0, "value": value], in: frame, contentWorld: world
                ) as? Bool
                guard !Task.isCancelled else { return false }
                if filled == true { replay.pressed(now: Date()) }
            case .wait, .finished:
                // Once the last step is pressed, starting over could submit the page twice: wait for the network.
                break
            case .stuck:
                // A page that changed before its last step, such as another advert: start over on a fresh page.
                guard replay.next < replay.steps.count, attempts < Self.attempts else { return false }
                attempts += 1
                documents = [:]
                replay = Replay(recipe, now: Date())
                webView.load(URLRequest(url: PortalClient.probeURL))
            }
        }
        return false
    }

    /// What every document can press now, in one list, with the document and frame each element lives in.
    private func snapshot() -> [(document: String, frame: WKFrameInfo, element: Element)] {
        var all: [(String, WKFrameInfo, Element)] = []
        for (id, document) in documents.sorted(by: { $0.key < $1.key }) {
            guard Date().timeIntervalSince(document.seen) < 2 else {
                documents[id] = nil
                continue
            }
            all += document.elements.map { (id, document.frame, $0) }
        }
        return all
    }

    private func refuse(_ lesson: Lesson, _ text: String) {
        guard unlearnable == nil else { return }
        unlearnable = lesson
        banner.stringValue = text
        banner.textColor = .systemOrange
    }
}

extension LoginBrowser: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        func elements(_ value: Any?) -> [Element]? {
            guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return try? JSONDecoder().decode([Element].self, from: data)
        }
        switch kind {
        case "page" where !teaching:
            guard let id = body["document"] as? String, let list = elements(body["elements"]) else { return }
            documents[String(id.prefix(64))] = (message.frameInfo, Array(list.prefix(200)), Date())
        case "press" where teaching && unlearnable == nil:
            guard var element = elements(body["element"].map { [$0] })?.first else { return }
            element.token = nil
            guard element.identifiable else {
                return refuse(.unclearButton, L("Wi-Fi Refill can't tell one of the buttons you pressed apart from others, so it won't learn this page. You can still log in here."))
            }
            guard presses.count < Self.maxSteps else {
                return refuse(.tooManyPresses, L("This page needs more presses than Wi-Fi Refill learns. You can still log in here."))
            }
            presses.append(element)
        case "fill" where teaching && unlearnable == nil:
            guard var element = elements(body["element"].map { [$0] })?.first, let value = body["value"] as? String else { return }
            element.token = nil
            guard element.identifiable else {
                return refuse(.unclearButton, L("Wi-Fi Refill can't tell one of the fields you typed into apart from others, so it won't learn this page. You can still log in here."))
            }
            guard presses.count < Self.maxSteps else {
                return refuse(.tooManyPresses, L("This page needs more presses than Wi-Fi Refill learns. You can still log in here."))
            }
            typed[presses.count] = String(value.prefix(256))
            presses.append(element)
            if remember.state != .on {
                banner.stringValue = L("This page asks you to type. Tick “Remember what I type on this page” to let Wi-Fi Refill type it for you next time.")
                banner.textColor = .systemOrange
            }
        case "unlearnable" where teaching:
            refuse(.unclearButton, L("Wi-Fi Refill can't tell one of the buttons you pressed apart from others, so it won't learn this page. You can still log in here."))
        case "typing" where teaching:
            refuse(.typed, L("This page asks you to type somewhere Wi-Fi Refill can't fill in, so it won't learn it. You can still log in here."))
        default:
            break
        }
    }
}

extension LoginBrowser: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Web pages only: no other apps, files or downloads.
        ["http", "https", "about", "data", "blob"].contains(action.request.url?.scheme ?? "") && !action.shouldPerformDownload ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMIMEType ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // Certificates are checked as usual; a page that asks for a password is not one Wi-Fi Refill logs in to.
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? (.performDefaultHandling, nil) : (.cancelAuthenticationChallenge, nil)
    }
}

extension LoginBrowser: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if teaching { refuse(.opensWindows, L("This page opens another window to log in, which Wi-Fi Refill can't learn yet.")) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {}

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        false
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        .deny
    }
}

extension LoginBrowser: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        closed = true
    }
}
