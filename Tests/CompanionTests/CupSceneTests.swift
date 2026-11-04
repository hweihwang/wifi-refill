import AppKit
import Testing
@testable import Companion
import RefillCore

@MainActor
struct CupSceneTests {
    /// Core Animation raises an exception for a position that isn't a number, which ends the app: every state, with
    /// and without Reduce Motion, the refill moment included.
    @Test(arguments: [false, true])
    func drawsEveryState(still: Bool) {
        let scene = CupScene()
        scene.still = still
        for state in MenuBarCupTests.states {
            for bars in 0...3 {
                scene.show(Pulse(state: state, bars: bars, received: 50_000, sessionLeft: 0.4, refilled: Date()), text: "Status")
                scene.show(Pulse(state: state, bars: bars, sessionLeft: nil), text: nil)
            }
        }
        let layers = [scene.root] + scene.root.sublayersDeep
        #expect(layers.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
    }
}
