import Foundation
import RefillCore

// Looks at every leg between this Mac and the internet and names the broken one.
//   refill-doctor                          the real network
//   refill-doctor --router 192.0.2.1 ...   stands in for a broken leg with an address that never answers
var targets = Checkup.Targets()
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let flag = arguments.next() {
    guard let value = arguments.next() else { break }
    switch flag {
    case "--router": targets.router = value
    case "--dns": targets.nameServers = [value]
    case "--internet": targets.internet = value
    case "--probe": targets.probe = URL(string: value)!
    case "--vpn": targets.vpn = URL(string: value)!
    default: print("unknown flag \(flag)"); exit(2)
    }
}
let diagnosis = await Checkup.run(on: Gateway.current(), targets: targets)
let seen = diagnosis.observations
func show(_ reading: Reading) -> String {
    switch reading {
    case .ok(let ms?): "ok \(ms) ms"
    case .ok(nil): "ok"
    case .broken: "BROKEN"
    case .unknown: "-"
    }
}
let probe = switch seen.probe { case .online: "online"; case .portal: "login page"; case .offline: "offline"; case nil: "no answer" }
if let vitals = Vitals.read() { print("link     \(vitals.rssi) dBm, noise \(vitals.noise), margin \(vitals.margin) dB, \(vitals.bars) bars, \(Int(vitals.rate)) Mbit/s, ch \(vitals.channel) \(vitals.gigahertz) GHz") }
print("wifi     \(show(seen.wifi))")
print("router   \(show(seen.router))")
print("dns      \(show(seen.dns))")
print("internet \(show(seen.internet))")
print("probe    \(probe)")
print("vpn      \(show(seen.vpn))")
print("blame    \(diagnosis.broken?.rawValue ?? "nothing") in \(diagnosis.milliseconds) ms")
