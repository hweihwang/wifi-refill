import AppKit
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
        watcher.onChange = { [weak self] in self?.updateIcon() }
        watcher.askPermission = { [weak self] session in self?.askToLogIn(session) ?? false }
        updateIcon()
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
        menu.addItem(.separator())
        menu.addItem(action(L("Check Now"), #selector(checkNow)))
        switch watcher.status {
        case .unsupported, .failed:
            menu.addItem(action(L("Open Login Page"), #selector(openLoginPage)))
            menu.addItem(action(L("Report This Login Page…"), #selector(reportLoginPage)))
        case .notNow, .turnedOff, .asking:
            menu.addItem(action(L("Open Login Page"), #selector(openLoginPage)))
        case .routerUnreachable:
            menu.addItem(action(L("Allow Local Network Access…"), #selector(openLocalNetworkSettings)))
            menu.addItem(action(L("Open Login Page"), #selector(openLoginPage)))
        default:
            break
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
        switch watcher.status {
        case .paused: L("Paused")
        case .offline: L("Offline")
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
        }
    }

    private func updateIcon() {
        let symbol: String
        var active = false
        switch watcher.status {
        case .failed, .routerUnreachable: symbol = "exclamationmark.triangle"
        case .loggedIn, .loggingIn, .asking: symbol = "cup.and.saucer.fill"; active = true
        default: symbol = "cup.and.saucer"
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: statusText)
        item.button?.appearsDisabled = !active && symbol != "exclamationmark.triangle"
        item.button?.toolTip = "Wi-Fi Refill: \(statusText)"
        item.button?.setAccessibilityLabel("Wi-Fi Refill: \(statusText)")
    }

    // MARK: Actions

    @objc private func checkNow() { watcher.check(reason: "Check Now") }

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

    @objc private func reportLoginPage() {
        Task {
            let chain = watcher.lastProbe
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            let system = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
            let summary = PortalReport.summary(of: chain, app: version, system: system)

            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = L("Report this login page")
            alert.informativeText = L("This is everything the report contains: how the page is built, with unfamiliar names replaced. Edit anything you'd rather not share. Open GitHub sends this text to GitHub in the page address, and it is only published if you submit the issue there.")
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
                NSWorkspace.shared.open(PortalReport.issueURL(repository: Self.repository, title: "Login page report", body: text.string))
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
