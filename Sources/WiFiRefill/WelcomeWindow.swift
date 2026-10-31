import AppKit
import SwiftUI

/// Shown on first launch: where the app lives, what it does, and the Open at Login choice.
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let done: (Bool) -> Void
    private let model: Model

    final class Model: ObservableObject {
        @Published var openAtLogin: Bool
        init(openAtLogin: Bool) { self.openAtLogin = openAtLogin }
    }

    init(openAtLogin: Bool, done: @escaping (Bool) -> Void) {
        self.done = done
        model = Model(openAtLogin: openAtLogin)
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Wi-Fi Refill"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: WelcomeView(model: model) { [weak self] in self?.window.close() })
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        done(model.openAtLogin)
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: WelcomeWindow.Model
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Wi-Fi Refill is in your menu bar")).font(.title2.weight(.semibold))
                    Text(L("Look for the cup at the top right of your screen.")).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                point("cup.and.saucer", L("When cafe Wi-Fi logs you out, Wi-Fi Refill logs you back in, usually within seconds."))
                point("hand.raised", L("It asks once per network before it logs in, and never needs a password."))
                point("wifi", L("Works with Ruijie Cloud login pages that have a One-click Login button. Met another kind? Report it from the menu."))
            }
            Toggle(L("Open Wi-Fi Refill when you log in to your Mac"), isOn: $model.openAtLogin)
            HStack {
                Spacer()
                Button(L("Done"), action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.orange).frame(width: 22)
        }
    }
}
