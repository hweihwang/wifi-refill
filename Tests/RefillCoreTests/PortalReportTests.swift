import Foundation
import Testing
@testable import RefillCore

struct PortalReportTests {
    let page = URL(string: "https://login.hotel.example/guest/room/1204/JaneDoe/s3cret/start?mac=02:00:00:00:00:01&ip=203.0.113.7&token=s3cret&jane_doe_1204=1&room=")!
    var hops: [Hop] {
        [Hop(url: URL(string: "http://captive.apple.com/hotspot-detect.html")!, status: 200, location: page, body: """
            <html><head><title>Welcome back, Jane Doe</title></head><body>
            <p>Hello Jane Doe, room 1204. Your device 02:00:00:00:00:01 at 203.0.113.7, fe80::1.</p>
            <form method="post" action="/guest/login?janedoe=1"><input type="hidden" name="csrf" value="abc123">
            <input name="room"><input name="last_name" type="text"><input name="jane.doe@example.com" type="x-jane">
            <button type="submit">Connect, Jane</button></form>
            </body></html>
            """)]
    }

    @Test func describesStructureWithoutValuesOrNames() {
        let summary = PortalReport.summary(of: hops, app: "1.0.0", system: "macOS 27.2")
        #expect(summary.contains("next: https://*.hotel.example/guest/room/*/*/*/start?mac&ip&token&*&room"))
        #expect(summary.contains("form: POST http://*.apple.com/guest/login?*; fields: csrf (hidden), room (text), last_name (text), * (*)"))
        for secret in ["02:00:00:00:00:01", "203.0.113.7", "fe80", "s3cret", "abc123", "Jane", "jane", "1204", "Welcome", "Connect"] {
            #expect(!summary.contains(secret), "leaked \(secret)")
        }
    }

    @Test func hidesAddressesThatCouldIdentifySomeone() {
        #expect(PortalReport.describe(URL(string: "http://192.168.110.1:2060/wifidog/auth?token=x")!) == "http://192.168.110.1:2060/wifidog/auth?token")
        #expect(PortalReport.describe(URL(string: "http://8.8.4.4/login")!) == "http://ip-address/login")
        #expect(PortalReport.describe(URL(string: "http://[2001:db8::1]/login")!) == "http://ip-address/login")
        #expect(PortalReport.hideHost("guest-48213377.hotel.example") == "*.hotel.example")
        #expect(PortalReport.hideHost("jane-doe.guest.example") == "*.guest.example")
        #expect(PortalReport.hideHost("portal-as.ruijienetworks.com") == "*.ruijienetworks.com")
        #expect(PortalReport.describe(URL(string: "ftp://files.example/x")!) == "*://files.example/*")
    }

    @Test func buildsAnIssueAddress() {
        let url = PortalReport.issueURL(repository: "hweihwang/wifi-refill", title: "Login page report", body: "summary")
        #expect(url.absoluteString.hasPrefix("https://github.com/hweihwang/wifi-refill/issues/new?title=Login%20page%20report"))
    }
}
