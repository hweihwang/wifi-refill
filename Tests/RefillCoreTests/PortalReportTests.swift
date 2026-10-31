import Foundation
import Testing
@testable import RefillCore

struct PortalReportTests {
    let hops = [
        Hop(url: URL(string: "http://captive.apple.com/hotspot-detect.html")!, status: 302,
            location: URL(string: "https://login.hotel.example/guest/3f9a2c7e1b5d4a/start?mac=02:00:00:00:00:01&ip=203.0.113.7&token=s3cret&room=")!, body: ""),
        Hop(url: URL(string: "https://login.hotel.example/guest/3f9a2c7e1b5d4a/start?mac=02:00:00:00:00:01&ip=203.0.113.7&token=s3cret&room=")!, status: 200, location: nil, body: """
            <html><head><title>Welcome to Hotel Example</title></head><body>
            <p>Hello Jane Doe, room 1204. Your device 02:00:00:00:00:01 at 203.0.113.7.</p>
            <form method="post" action="/guest/login"><input type="hidden" name="csrf" value="abc123">
            <input name="room"><input name="last_name" type="text"><button type="submit">Connect</button></form>
            </body></html>
            """),
    ]

    @Test func describesStructureWithoutValues() {
        let summary = PortalReport.summary(of: hops, app: "1.0.0", system: "macOS 27.2")
        #expect(summary.contains("https://login.hotel.example/guest/{id}/start?mac&ip&token&room"))
        #expect(summary.contains("title: Welcome to Hotel Example"))
        #expect(summary.contains("form: POST https://login.hotel.example/guest/login; fields: csrf (hidden), room (text), last_name (text)"))
        #expect(summary.contains("buttons: Connect"))
        for secret in ["02:00:00:00:00:01", "203.0.113.7", "s3cret", "abc123", "Jane Doe", "1204", "3f9a2c7e1b5d4a"] {
            #expect(!summary.contains(secret), "leaked \(secret)")
        }
    }

    @Test func hidesPublicAddressesButKeepsRouterAddresses() {
        #expect(PortalReport.describe(URL(string: "http://192.168.110.1:2060/wifidog/auth?token=x")!) == "http://192.168.110.1:2060/wifidog/auth?token")
        #expect(PortalReport.describe(URL(string: "http://8.8.4.4/login")!) == "http://public-ip/login")
    }

    @Test func buildsAnIssueAddress() {
        let url = PortalReport.issueURL(repository: "hweihwang/wifi-refill", title: "Login page: Hotel Example", body: "summary")
        #expect(url.absoluteString.hasPrefix("https://github.com/hweihwang/wifi-refill/issues/new?title=Login%20page:%20Hotel%20Example"))
    }
}
