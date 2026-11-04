import AppKit
import Testing
@testable import Companion
import RefillCore

@MainActor
struct MenuBarCupTests {
    static let states: [Pulse.State] = [.online, .loggingIn, .broken(.wifi), .broken(.router), .broken(.loginPage), .broken(.dns), .broken(.internet), .broken(.vpn), .noInternet, .paused, .offline]

    /// Core Animation raises an exception for a position that isn't a number, which ends the app.
    @Test(arguments: [false, true])
    func drawsEveryState(still: Bool) {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        let cup = MenuBarCup(button: button)
        for state in Self.states {
            for bars in 0...3 {
                for filled in [false, true] {
                    cup.show(Pulse(state: state, bars: bars, received: 50_000), filled: filled, still: still)
                }
            }
        }
        let layers = button.layer.map { [$0] + Self.all(in: $0) } ?? []
        #expect(!layers.isEmpty)
        #expect(layers.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
    }

    static func all(in layer: CALayer) -> [CALayer] { (layer.sublayers ?? []).flatMap { [$0] + all(in: $0) } }
}
