import Foundation
import Testing
@testable import RefillCore

struct DiagnosisTests {
    let ok = Reading.ok(milliseconds: 5)

    @Test func blamesNothingWhenTheCheckPageLoads() {
        #expect(Diagnosis.blame(Observations(wifi: ok, router: ok, dns: ok, internet: ok, probe: .online)) == nil)
    }

    @Test func aRouterThatIgnoresChecksIsFineWhileTheWebLoads() {
        #expect(Diagnosis.blame(Observations(wifi: ok, router: .broken, dns: ok, internet: ok, probe: .online)) == nil)
    }

    @Test func blamesTheRadioFirst() {
        #expect(Diagnosis.blame(Observations(wifi: .broken, router: .broken, dns: .broken, internet: .broken)) == .wifi)
    }

    @Test func blamesTheRouterOnlyWhenNothingBeyondItAnswers() {
        #expect(Diagnosis.blame(Observations(wifi: ok, router: .broken, dns: .broken, internet: .broken)) == .router)
        #expect(Diagnosis.blame(Observations(wifi: ok, router: .broken, dns: ok, internet: .broken)) == .internet)
    }

    @Test func aNameServerThatFailsWithTheLineIsNotTheProblem() {
        #expect(Diagnosis.blame(Observations(wifi: ok, router: ok, dns: .broken, internet: .broken)) == .internet)
    }

    @Test func blamesTheNameServerWhenTheLineWorks() {
        #expect(Diagnosis.blame(Observations(wifi: ok, router: ok, dns: .broken, internet: ok)) == .dns)
    }

    @Test func aLoginPageComesBeforeEverythingButTheRadio() {
        let portal = ProbeResult.portal([Hop(url: PortalClient.probeURL, status: 302, location: nil, body: "")])
        #expect(Diagnosis.blame(Observations(wifi: ok, router: .broken, dns: .broken, internet: .broken, probe: portal)) == .loginPage)
    }

    @Test func blamesTheVPNWhenTheWiFiReachesTheWeb() {
        #expect(Diagnosis.blame(Observations(wifi: ok, router: ok, dns: ok, internet: ok, probe: .online, vpn: .broken)) == .vpn)
    }

    @Test func everyLegAnsweringWithoutTheWebIsTheLine() {
        #expect(Diagnosis.blame(Observations(wifi: ok, router: ok, dns: ok, internet: ok, probe: nil)) == .internet)
    }

    @Test func theCheckPageOutweighsTheRadio() {
        #expect(Diagnosis.blame(Observations(wifi: .broken, router: ok, dns: ok, internet: ok, probe: .online)) == nil)
    }

    @Test func blamesNothingWithoutEvidence() {
        #expect(Diagnosis.blame(Observations()) == nil)
        // A name server that fails while the line was never measured could be either.
        #expect(Diagnosis.blame(Observations(wifi: ok, router: ok, dns: .broken, internet: .unknown)) == nil)
    }

    @Test func tellsAResponseFromAnythingElse() {
        var answer = Checkup.query("captive.apple.com", id: 9)
        #expect(!Checkup.answers(answer, id: 9))
        answer.replaceSubrange(2..<4, with: [0x81, 0x82])
        #expect(Checkup.answers(answer, id: 9))
        #expect(!Checkup.answers(answer, id: 10))
    }

    @Test func keepsOnlyPublicAddresses() {
        #expect(Checkup.isPublic("17.253.144.10"))
        for address in ["10.29.64.2", "172.20.0.1", "192.168.110.1", "100.100.100.100", "169.254.1.1", "192.0.2.80", "198.51.100.80", "203.0.113.80", "127.0.0.1", "224.0.0.251", "not an address"] {
            #expect(!Checkup.isPublic(address), "\(address)")
        }
    }

    @Test func readsTheAddressFromARealAnswer() {
        // An answer for captive.apple.com: a CNAME, then its A record, names compressed.
        let question = Checkup.query("captive.apple.com", id: 0x1234)
        var answer = question
        answer.replaceSubrange(2..<4, with: [0x81, 0x80])
        answer.replaceSubrange(6..<8, with: [0, 2])
        answer.append(contentsOf: [0xc0, 0x0c, 0, 5, 0, 1, 0, 0, 0, 60, 0, 6, 3, 0x61, 0x62, 0x63, 0xc0, 0x14])
        answer.append(contentsOf: [0xc0, 0x29, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 17, 253, 1, 2])
        #expect(Checkup.address(in: answer, id: 0x1234) == "17.253.1.2")
        #expect(Checkup.address(in: answer, id: 0x4321) == nil)
        #expect(Checkup.address(in: answer.prefix(answer.count - 2), id: 0x1234) == nil)
    }

    @Test func refusesAnErrorAnswer() {
        var answer = Checkup.query("captive.apple.com", id: 7)
        answer.replaceSubrange(2..<4, with: [0x81, 0x83])
        #expect(Checkup.address(in: answer, id: 7) == nil)
    }

    @Test func barsFollowTheMarginOverTheNoise() {
        #expect(Vitals(rssi: -44, noise: -94, rate: 866, channel: 124, gigahertz: 5).bars == 3)
        #expect(Vitals(rssi: -67, noise: -92, rate: 144, channel: 6, gigahertz: 2).bars == 2)
        #expect(Vitals(rssi: -80, noise: -92, rate: 6, channel: 6, gigahertz: 2).bars == 1)
    }

    @Test func trafficSurvivesTheCounterWrapping() {
        let rate = Traffic.rate(from: Traffic(received: .max - 99, sent: 0), to: Traffic(received: 900, sent: 2000), seconds: 2)
        #expect(rate.received == 500)
        #expect(rate.sent == 1000)
    }

    @Test func noticesTheMacSendingIntoTheVoid() {
        let before = Traffic(received: 0, sent: 0, packetsIn: 1000, packetsOut: 1000)
        // Apps retry; only a little multicast comes back.
        #expect(Traffic.stalled(from: before, to: Traffic(received: 0, sent: 0, packetsIn: 1002, packetsOut: 1030)))
        // Idle: a few packets either way.
        #expect(!Traffic.stalled(from: before, to: Traffic(received: 0, sent: 0, packetsIn: 1001, packetsOut: 1006)))
        // An upload: one acknowledgement for every two packets sent.
        #expect(!Traffic.stalled(from: before, to: Traffic(received: 0, sent: 0, packetsIn: 1500, packetsOut: 2000)))
        // A download.
        #expect(!Traffic.stalled(from: before, to: Traffic(received: 0, sent: 0, packetsIn: 3000, packetsOut: 1400)))
        // Counters wrap.
        #expect(Traffic.stalled(from: Traffic(received: 0, sent: 0, packetsIn: 5, packetsOut: .max - 9), to: Traffic(received: 0, sent: 0, packetsIn: 6, packetsOut: 20)))
    }
}
