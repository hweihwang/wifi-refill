import AppKit
import Companion
import RefillCore
import ServiceManagement
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let repository = "hweihwang/wifi-refill"
    static let website = URL(string: "https://hweihwang.com/wifi-refill/")!

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let watcher = Watcher()
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var welcome: WelcomeWindow?
    private let seatFinder = SeatFinder()
    private var speedTest: Process?
    private var lastSpeed: (speed: Speed, at: Date)?
    private lazy var cup = CupController(watcher: watcher, item: item)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Replacing the app drops its login item; register again unless the person turned it off or must approve it.
        // A freshly installed app reports .notFound rather than .notRegistered.
        let loginItem = SMAppService.mainApp.status
        if UserDefaults.standard.object(forKey: "openAtLogin") as? Bool ?? true, loginItem != .enabled, loginItem != .requiresApproval {
            setOpenAtLogin(true)
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        watcher.onChange = { [weak self] in
            self?.updateIcon()
            self?.cup.statusChanged()
        }
        watcher.askPermission = { [weak self] session in self?.askToLogIn(session) ?? false }
        updateIcon()
        cup.restoreIcon = { [weak self] in self?.updateIcon() }
        cup.describe = { [weak self] in self?.statusText ?? "" }
        cup.apply()
        watcher.start()
        if !UserDefaults.standard.bool(forKey: "welcomed") { showWelcome() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWelcome()
        return false
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(info(statusText))
        switch watcher.reconnectsToday {
        case 0: break
        case 1: menu.addItem(info(L("Logged you back in once today")))
        case let count: menu.addItem(info(String(format: L("Logged you back in %d times today"), count)))
        }
        if let lastSpeed {
            menu.addItem(info(String(format: L("Speed at %@: %d Mbit/s down, %d up, %d ms when busy"), Log.time(lastSpeed.at),
                                     Int(lastSpeed.speed.down.rounded()), Int(lastSpeed.speed.up.rounded()), Int(lastSpeed.speed.loadedRoundTrip.rounded()))))
        }
        menu.addItem(.separator())
        menu.addItem(action(L("Check Now"), #selector(checkNow)))
        menu.addItem(action(L("Find a Better Seat…"), #selector(findSeat)))
        if speedTest == nil {
            menu.addItem(action(L("Test Speed"), #selector(testSpeed)))
        } else {
            menu.addItem(info(L("Testing speed…")))
        }
        switch watcher.status {
        case .unsupported, .failed:
            menu.addItem(action(L("Teach Wi-Fi Refill This Login Page…"), #selector(teach)))
            menu.addItem(action(L("Open Login Page"), #selector(openLoginPage)))
            menu.addItem(action(L("Report This Login Page…"), #selector(reportLoginPage)))
        case .notNow, .turnedOff, .asking:
            menu.addItem(action(L("Open Login Page"), #selector(openLoginPage)))
        case .routerUnreachable:
            menu.addItem(action(L("Allow Local Network Access…"), #selector(openLocalNetworkSettings)))
            menu.addItem(action(L("Open Login Page"), #selector(openLoginPage)))
        case .offline where watcher.diagnosis?.broken != .loginPage:
            // macOS joins an iPhone's hotspot by itself only when no Wi-Fi is around at all; it lists it here.
            menu.addItem(action(L("Use Your iPhone's Hotspot…"), #selector(openWiFiSettings)))
        default:
            break
        }
        if watcher.shareableRecipe != nil {
            menu.addItem(action(L("Share This Login Page…"), #selector(shareLoginPage)))
        }
        if !watcher.profiles.isEmpty {
            let networks = NSMenu()
            for profile in watcher.profiles.sorted(by: { $0.network < $1.network }) {
                let choices = NSMenu()
                choices.addItem(action(L("Log In Automatically"), #selector(toggleNetwork(_:)), on: profile.allowed, value: profile.id))
                choices.addItem(action(L("Forget This Network"), #selector(forgetNetwork(_:)), value: profile.id))
                let entry = NSMenuItem(title: profile.network, action: nil, keyEquivalent: "")
                entry.state = profile.allowed ? .on : .off
                entry.submenu = choices
                networks.addItem(entry)
            }
            let entry = NSMenuItem(title: L("Networks"), action: nil, keyEquivalent: "")
            entry.submenu = networks
            menu.addItem(entry)
        }
        menu.addItem(action(L("Animate the Cup"), #selector(toggleAnimation), on: cup.animated))
        menu.addItem(action(L("Cup on the Desktop"), #selector(toggleDesktopCup), on: cup.onDesktop))
        menu.addItem(.separator())
        menu.addItem(action(L("Pause"), #selector(togglePause), on: watcher.paused))
        menu.addItem(action(L("Open at Login"), #selector(toggleOpenAtLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        let update = NSMenuItem(title: L("Check for Updates…"), action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updater
        menu.addItem(update)
        menu.addItem(action(L("About Wi-Fi Refill"), #selector(showAbout)))
        menu.addItem(action(L("Show Log"), #selector(showLog)))
        menu.addItem(.separator())
        menu.addItem(action(L("Quit Wi-Fi Refill"), #selector(NSApplication.terminate(_:)), target: NSApp))
    }

    private var statusText: String {
        if watcher.diagnosis?.broken == .vpn, watcher.status != .paused { return Self.problem(.vpn) }
        return switch watcher.status {
        case .paused: L("Paused")
        case .offline: watcher.diagnosis?.broken.map(Self.problem) ?? L("Offline")
        case .noLoginPage: L("No login page right now")
        case .unsupported(let reason): L(reason)
        case .asking(let network): String(format: L("Waiting for your answer about %@"), network)
        case .notNow(let network): String(format: L("Not logged in to %@"), network)
        case .turnedOff(let network): String(format: L("Automatic login is off for %@"), network)
        case .loggingIn(let network): String(format: L("Logging in to %@…"), network)
        case .loggedIn(let network, nil): String(format: L("%@: logged in"), network)
        case .loggedIn(let network, let until?) where until > Date():
            String(format: L("%@: logged in until %@"), network, Log.time(until))
        case .loggedIn(let network, _): String(format: L("%@: logging in again soon"), network)
        case .routerUnreachable: L("Can't reach the Wi-Fi router")
        case .failed(let reason): String(format: L("Couldn't log in: %@"), L(reason))
        case .teaching: L("Learning this login page…")
        case .waitingForPage(let network): String(format: L("%@: waiting for the login page…"), network)
        }
    }

    /// What is wrong, by the leg that broke.
    private static func problem(_ leg: Leg) -> String {
        switch leg {
        case .wifi: L("Wi-Fi is off or too far")
        case .router: L("The router isn't answering")
        case .loginPage: L("A login page is in the way")
        case .dns: L("The network can't look up names")
        case .internet: L("The router's internet is down")
        case .vpn: L("Your VPN isn't getting through")
        }
    }

    private func updateIcon() {
        let symbol: String
        var active = false
        switch watcher.status {
        case .failed, .routerUnreachable: symbol = "exclamationmark.triangle"
        case .loggedIn, .loggingIn, .asking, .teaching, .waitingForPage: symbol = "cup.and.saucer.fill"; active = true
        default: symbol = "cup.and.saucer"
        }
        if !cup.animated {
            item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusText)
        }
        // The animated cup shows the network itself; the still icon is dimmed where there is nothing to do.
        item.button?.appearsDisabled = !cup.animated && !active && symbol != "exclamationmark.triangle"
        item.button?.toolTip = "Wi-Fi Refill: \(statusText)"
        item.button?.setAccessibilityLabel("Wi-Fi Refill: \(statusText)")
    }

    // MARK: Actions

    @objc private func checkNow() { watcher.check(reason: "Check Now") }

    @objc private func toggleAnimation() { cup.animated.toggle() }

    @objc private func findSeat() { seatFinder.show() }

    /// Runs macOS's own speed test over the Wi-Fi or Ethernet itself, past any VPN, for at most twelve seconds.
    @objc private func testSpeed() {
        guard speedTest == nil, let network = Gateway.current() else { return }
        if watcher.expensive {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = L("Test speed on a metered connection?")
            alert.informativeText = L("A speed test moves a few hundred megabytes on a fast line, which this connection may count against a data plan.")
            alert.addButton(withTitle: L("Test Speed"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        process.arguments = ["-c", "-M", "12", "-I", network.interface]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in self?.finishSpeedTest(Speed(json: data)) }
        }
        do {
            try process.run()
            speedTest = process
        } catch {
            finishSpeedTest(nil)
        }
    }

    private func finishSpeedTest(_ speed: Speed?) {
        speedTest = nil
        NSApp.activate()
        let alert = NSAlert()
        if let speed {
            lastSpeed = (speed, Date())
            alert.messageText = String(format: L("%d Mbit/s down, %d up"), Int(speed.down.rounded()), Int(speed.up.rounded()))
            alert.informativeText = String(format: speed.goodForCalls
                ? L("A round trip takes %d ms while the line is busy: good for video calls.")
                : L("A round trip takes %d ms while the line is busy: video calls may stutter."), Int(speed.loadedRoundTrip.rounded()))
        } else {
            alert.messageText = L("Couldn't test the speed")
            alert.informativeText = L("The test didn't finish. Try again once the internet works.")
        }
        alert.runModal()
    }

    @objc private func toggleDesktopCup() { cup.onDesktop.toggle() }

    @objc private func openWiFiSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!)
    }

    @objc private func teach() {
        Task {
            let lesson = await watcher.teach()
            let (title, text): (String, String)
            switch lesson {
            case nil:
                (title, text) = (L("There's no login page right now"), L("Wi-Fi Refill can learn a login page while it is showing, such as the next time this network logs you out."))
            case .learned(let recipe) where recipe.steps.contains { $0.fill == true }:
                (title, text) = (L("Wi-Fi Refill learned this login page"), L("It will type what you typed and press the same buttons for you each time this network logs you out. What you typed stays in your Keychain on this Mac."))
            case .learned:
                (title, text) = (L("Wi-Fi Refill learned this login page"), L("It will press the same buttons for you each time this network logs you out."))
            case .typed:
                (title, text) = (L("Wi-Fi Refill can't learn this page"), L("The page asks you to type. Teach it again and tick “Remember what I type on this page” to let Wi-Fi Refill type it for you, or log in yourself."))
            case .opensWindows:
                (title, text) = (L("Wi-Fi Refill can't learn this page yet"), L("The page opens another window to log in. Report This Login Page… helps add support for it."))
            case .tooManyPresses:
                (title, text) = (L("Wi-Fi Refill can't learn this page"), L("This page needs more presses than Wi-Fi Refill learns, so it stays with you."))
            case .unclearButton:
                (title, text) = (L("Wi-Fi Refill can't learn this page"), L("Wi-Fi Refill can't tell one of the buttons you pressed apart from the others, so this page stays with you."))
            case .nothingPressed:
                (title, text) = (L("Nothing to learn"), L("You were logged in without pressing anything in Wi-Fi Refill's window. Try again the next time the login page appears, and log in in that window."))
            case .cancelled:
                return
            }
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = text
            alert.runModal()
        }
    }

    @objc private func togglePause() { watcher.paused.toggle() }

    @objc private func toggleNetwork(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let profile = watcher.profiles.first(where: { $0.id == id }) else { return }
        watcher.setAllowed(!profile.allowed, for: id)
    }

    @objc private func forgetNetwork(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        watcher.forget(id)
    }

    @objc private func toggleOpenAtLogin() {
        let on = SMAppService.mainApp.status != .enabled
        UserDefaults.standard.set(on, forKey: "openAtLogin")
        setOpenAtLogin(on)
    }

    @objc private func openLoginPage() {
        NSWorkspace.shared.open(PortalClient.probeURL)
    }

    @objc private func openLocalNetworkSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
    }

    @objc private func showLog() {
        if !FileManager.default.fileExists(atPath: Log.url.path) { Log.write("Log started.") }
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func showAbout() {
        NSApp.activate()
        let credits = NSMutableAttributedString(string: L("Logs your Mac back in when cafe Wi-Fi logs you out.") + "\n")
        credits.append(NSAttributedString(string: "hweihwang.com/wifi-refill", attributes: [.link: Self.website]))
        credits.append(NSAttributedString(string: "  ·  "))
        credits.append(NSAttributedString(string: "GitHub", attributes: [.link: URL(string: "https://github.com/\(Self.repository)")!]))
        credits.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func reportLoginPage() { report(sharing: nil) }

    /// What the person taught here goes with the report, so the next version can know the page for everyone.
    @objc private func shareLoginPage() { report(sharing: watcher.shareableRecipe) }

    private func report(sharing recipe: Recipe?) {
        Task {
            let chain = watcher.lastProbe
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            let system = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
            var summary = PortalReport.summary(of: chain, app: version, system: system)
            if let recipe {
                summary += "\n\nThe buttons Wi-Fi Refill learned to press here:\n```json\n\(recipe.shared())\n```"
            }

            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = recipe == nil ? L("Report this login page") : L("Share this login page")
            alert.informativeText = recipe == nil
                ? L("This is everything the report contains: how the page is built, with unfamiliar names replaced. Edit anything you'd rather not share. Open GitHub sends this text to GitHub in the page address, and it is only published if you submit the issue there.")
                : L("This is everything the report contains: how the page is built and the buttons Wi-Fi Refill learned to press here, with unfamiliar names and anything that looks like an address or an identifier replaced. Nothing you typed is in it. Edit anything you'd rather not share. Open GitHub sends this text to GitHub in the page address, and it is only published if you submit the issue there.")
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
            text.string = summary
            text.isEditable = true
            text.isRichText = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            let scroll = NSScrollView(frame: text.frame)
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            alert.accessoryView = scroll
            alert.addButton(withTitle: L("Open GitHub"))
            alert.addButton(withTitle: L("Copy"))
            alert.addButton(withTitle: L("Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // A fixed title: everything sent is in the preview the person could edit.
                NSWorkspace.shared.open(PortalReport.issueURL(repository: Self.repository, title: recipe == nil ? "Login page report" : "Login page recipe", body: text.string))
            case .alertSecondButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text.string, forType: .string)
            default:
                break
            }
        }
    }

    private func askToLogIn(_ session: PortalSession) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(format: L("Log in to %@ automatically?"), session.network)
        alert.informativeText = L("This Wi-Fi asks you to press a button on its login page. Wi-Fi Refill can press it for you now and each time the network logs you out. Logging in accepts the network's terms of use.\n\nThe first time, macOS may ask to let Wi-Fi Refill reach devices on your local network. Allow it, so Wi-Fi Refill can reach the cafe's router or Wi-Fi controller.")
        alert.addButton(withTitle: L("Log In Automatically"))
        alert.addButton(withTitle: L("Open Login Page"))
        alert.addButton(withTitle: L("Not Now"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: openLoginPage(); return false
        default: return false
        }
    }

    private func showWelcome() {
        if welcome == nil {
            welcome = WelcomeWindow(openAtLogin: SMAppService.mainApp.status == .enabled) { [weak self] openAtLogin in
                UserDefaults.standard.set(true, forKey: "welcomed")
                UserDefaults.standard.set(openAtLogin, forKey: "openAtLogin")
                if openAtLogin != (SMAppService.mainApp.status == .enabled) { self?.setOpenAtLogin(openAtLogin) }
                self?.welcome = nil
            }
        }
        welcome?.show()
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("Could not change Open at Login: \(error.localizedDescription)")
        }
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, on: Bool = false, value: String? = nil, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = target ?? self
        item.state = on ? .on : .off
        item.representedObject = value
        return item
    }
}
