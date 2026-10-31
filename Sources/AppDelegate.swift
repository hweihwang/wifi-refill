import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let watcher = Watcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Replacing the app bundle drops the login item, so register again unless the user turned it off.
        if UserDefaults.standard.object(forKey: "openAtLogin") as? Bool ?? true, SMAppService.mainApp.status != .enabled {
            setOpenAtLogin(true)
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        watcher.onChange = { [weak self] in self?.updateIcon() }
        updateIcon()
        watcher.start()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(info(statusText))
        if let last = watcher.lastLogin { menu.addItem(info("Last automatic login at \(Log.time(last))")) }
        menu.addItem(.separator())
        menu.addItem(action("Check Now", #selector(checkNow)))
        menu.addItem(action("Pause", #selector(togglePause), on: watcher.paused))
        menu.addItem(action("Open at Login", #selector(toggleOpenAtLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(action("Show Log", #selector(showLog)))
        menu.addItem(.separator())
        menu.addItem(action("Quit Wi-Fi Autologin", #selector(NSApplication.terminate(_:)), target: NSApp))
    }

    private var statusText: String {
        switch watcher.status {
        case .paused: "Paused"
        case .offline: "Offline"
        case .noPortal: "No login page on this network"
        case .otherPortal: "This network's login page isn't supported"
        case .loggingIn: "Logging in…"
        case .loggedIn(let network, nil): "\(network): logged in"
        case .loggedIn(let network, let until?) where until > Date(): "\(network): logged in until \(Log.time(until))"
        case .loggedIn(let network, _): "\(network): logging in again…"
        case .failed(let reason): "Login failed: \(reason)"
        }
    }

    private func updateIcon() {
        let active: Bool
        switch watcher.status {
        case .loggedIn, .loggingIn, .failed: active = true
        default: active = false
        }
        let symbol = if case .failed = watcher.status { "exclamationmark.triangle" } else if active { "cup.and.saucer.fill" } else { "cup.and.saucer" }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Wi-Fi Autologin")
        item.button?.appearsDisabled = !active
        item.button?.toolTip = statusText
    }

    @objc private func checkNow() { watcher.check(force: true, reason: "Check Now") }

    @objc private func togglePause() { watcher.paused.toggle() }

    @objc private func toggleOpenAtLogin() {
        let on = SMAppService.mainApp.status != .enabled
        UserDefaults.standard.set(on, forKey: "openAtLogin")
        setOpenAtLogin(on)
    }

    @objc private func showLog() {
        if !FileManager.default.fileExists(atPath: Log.url.path) { Log.write("Log started.") }
        NSWorkspace.shared.open(Log.url)
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

    private func action(_ title: String, _ selector: Selector, on: Bool = false, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = target ?? self
        item.state = on ? .on : .off
        return item
    }
}
