import Foundation
import Testing
import RefillCore

struct SpeedTests {
    /// What `networkQuality -c -M 10 -I en0` printed on a 183/149 Mbit/s line, trimmed to the fields that matter.
    @Test func readsTheToolsOutput() throws {
        let json = #"{"dl_throughput": 182622288, "ul_throughput": 149180832, "responsiveness": 450.6744689941406, "base_rtt": 30.1, "interface_name": "en0"}"#
        let speed = try #require(Speed(json: Data(json.utf8)))
        #expect(Int(speed.down) == 182)
        #expect(Int(speed.up) == 149)
        #expect(Int(speed.loadedRoundTrip) == 133)
        #expect(speed.goodForCalls)
    }

    @Test func refusesWhatItCannotRead() {
        #expect(Speed(json: Data("not json".utf8)) == nil)
        #expect(Speed(json: Data(#"{"dl_throughput": 1}"#.utf8)) == nil)
        #expect(Speed(json: Data(#"{"dl_throughput": 1, "ul_throughput": 1, "responsiveness": 0}"#.utf8)) == nil)
    }

    @Test func aSluggishLineIsNoGoodForCalls() {
        #expect(!Speed(down: 50, up: 10, loadedRoundTrip: 600).goodForCalls)
        #expect(!Speed(down: 2, up: 1, loadedRoundTrip: 40).goodForCalls)
    }

    @Test func ticksFasterAsTheSignalGetsStronger() {
        let weak = Vitals(rssi: -85, noise: -92, rate: 6, channel: 1, gigahertz: 2)
        let strong = Vitals(rssi: -40, noise: -94, rate: 866, channel: 124, gigahertz: 5)
        #expect(weak.strength == 0)
        #expect(strong.strength == 1)
        #expect(strong.tick < weak.tick)
        #expect((0.15...1.2).contains(weak.tick) && (0.15...1.2).contains(strong.tick))
    }
}
