import AppKit
import RefillCore
import SwiftUI

/// A small window to carry around a cafe: the Wi-Fi's signal right now, the best spot so far, and ticks that come faster
/// where the signal is stronger, like a Geiger counter. Reads the radio twice a second while open; sends nothing.
@MainActor
final class SeatFinder {
    private var window: NSPanel?
    private var reader: Timer?
    private var ticker: Timer?
    private let model = Model()

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = L("Find a Better Seat")
        panel.level = .floating
        // A menu bar app is not active once its menu closes; the finder stays while the person walks around.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: Meter(model: model))
        panel.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        window = panel
        model.best = nil
        read()
        reader = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.read() }
        }
        scheduleTick()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func stop() {
        reader?.invalidate()
        ticker?.invalidate()
        reader = nil
        ticker = nil
        window = nil
    }

    private func read() {
        let vitals = Vitals.read()
        model.now = vitals
        if let vitals, vitals.margin > model.best?.margin ?? .min { model.best = vitals }
    }

    private func scheduleTick() {
        let interval = model.now?.tick ?? 1.5
        ticker = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window != nil else { return }
                if self.model.sound, self.model.now != nil { NSSound(named: "Tink")?.play() }
                self.scheduleTick()
            }
        }
    }

    @MainActor
    final class Model: ObservableObject {
        @Published var now: Vitals?
        @Published var best: Vitals?
        @Published var sound = true
    }

    private struct Meter: View {
        @ObservedObject var model: Model
        static let caramel = Color(red: 0.92, green: 0.56, blue: 0.30)
        static let ink = Color(red: 0.29, green: 0.16, blue: 0.09)

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                if let now = model.now {
                    Text(Self.word(now)).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Self.ink)
                    GeometryReader { box in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Self.caramel.opacity(0.18))
                            Capsule().fill(Self.caramel).frame(width: max(12, box.size.width * now.strength))
                                .animation(.easeOut(duration: 0.4), value: now.strength)
                        }
                    }
                    .frame(height: 16)
                    Text(String(format: L("%d dBm, %d dB above the noise"), now.rssi, now.margin)).font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
                    if let best = model.best {
                        Text(String(format: L("Best so far: %d dBm"), best.rssi)).font(.system(.body, design: .rounded).weight(.semibold))
                    }
                } else {
                    Text(L("Wi-Fi is off or not joined to a network")).font(.system(size: 20, weight: .semibold, design: .rounded))
                }
                Spacer(minLength: 0)
                Text(L("Carry your Mac around. The ticks come faster where the signal is stronger.")).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L("Ticks"), isOn: $model.sound)
            }
            .padding(20)
            .frame(width: 320, height: 300)
        }

        static func word(_ vitals: Vitals) -> String {
            vitals.bars >= 3 ? L("Strong signal") : vitals.bars == 2 ? L("Good signal") : L("Weak signal")
        }
    }
}
