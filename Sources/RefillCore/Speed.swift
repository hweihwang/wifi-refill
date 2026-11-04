import Foundation

/// A speed test's result, from Apple's `networkQuality` tool, which comes with macOS and measures against Apple's own
/// servers.
public struct Speed: Equatable, Sendable {
    /// Megabits per second.
    public var down: Double
    public var up: Double
    /// A round trip while the line is busy, in milliseconds: what a call or a page feels like when others use the Wi-Fi.
    public var loadedRoundTrip: Double

    public init(down: Double, up: Double, loadedRoundTrip: Double) {
        self.down = down
        self.up = up
        self.loadedRoundTrip = loadedRoundTrip
    }

    /// Reads the tool's computer-readable output (`networkQuality -c`).
    public init?(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let down = object["dl_throughput"] as? Double, let up = object["ul_throughput"] as? Double,
              let rpm = object["responsiveness"] as? Double, rpm > 0
        else { return nil }
        self.init(down: down / 1_000_000, up: up / 1_000_000, loadedRoundTrip: 60_000 / rpm)
    }

    /// Enough for a video call: a few megabits each way and round trips that stay short while the line is busy.
    public var goodForCalls: Bool { down >= 4 && up >= 2 && loadedRoundTrip <= 150 }
}

extension Vitals {
    /// How strong the signal is, 0 to 1, for a seat finder: 10 dB over the noise is nothing, 45 dB is as good as it gets.
    public var strength: Double { min(1, max(0, Double(margin - 10) / 35)) }

    /// Seconds between ticks of the seat finder: slow when the signal is weak, quick when it is strong, like a Geiger
    /// counter getting closer.
    public var tick: TimeInterval { 0.15 + (1 - strength) * 1.05 }
}
