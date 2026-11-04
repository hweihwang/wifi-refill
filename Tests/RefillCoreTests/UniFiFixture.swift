import Foundation
@testable import RefillCore

/// A UniFi guest portal with no authentication: UniFi Network Application 10.0.162 (portal 3.0.16) in a container,
/// recorded with curl on 2026-11-05, its default site's portal as it ships. `hotspotconfig` keeps two of its country
/// codes. Not recorded (there was no access point): the access point's redirect, built from the parameters the
/// controller reads (`ap`, `id`, `t`, `url`, `ssid`), with hardware addresses replaced.
enum UniFiFixture {
    static let controller = "192.168.1.2"
    static let network = LocalNetwork(interface: "en0", router: "192.168.1.1", address: "192.168.1.50", mask: "255.255.255.0")
    static let portal = "http://\(controller):8880/guest/s/default/"
    static let entry = portal + "?ap=02:00:00:00:00:02&id=02:00:00:00:00:01&t=1762300000&url=http://captive.apple.com%2fhotspot-detect.html&ssid=Cafe%20Guest"

    static let config = ##"{"meta":{"rc":"ok"},"data":[{"auth":"none","authentication_text":"Select Your authentication method","bg_color":"#005ED9","bg_image_enabled":false,"bg_type":"color","text_color":"#232326","button_color":"#006FFF","button_text_color":"#FFFFFF","button_text":"Login","link_color":"#006FFF","box_color":"#FFFFFF","box_opacity":100,"box_radius":25,"logo_position":"center","logo_size":128,"success_text":"Welcome to UniFi Guest Hotspot","title":"UniFi Guest Hotspot","welcome_text":"Welcome to UniFi Guest Hotspot","box_text_color":"#000000","languages":["en"],"ccodes":[{"key":"AF","name":"Afghanistan"},{"key":"AL","name":"Albania"}]}]}"##
    static let loggedIn = ##"{"meta":{"rc":"ok"},"data":[{"authorized":true,"redirect_url":"http://captive.apple.com/hotspot-detect.html"}]}"##
    /// `login` on a portal that wants a password, posted without one.
    static let refused = ##"{"meta":{"rc":"ok"},"data":[{"authorized":false,"redirect_url":"http://captive.apple.com/hotspot-detect.html"}]}"##

    static func routes(entry: String = entry, config: String = config, answer: String = loggedIn, host: String = controller) -> [String: FakeNetwork.Response] {
        [
            "captive.apple.com/hotspot-detect.html": .init(status: 302, location: entry),
            // The visit's details go into a cookie, and the browser back to the page it asked for.
            "\(host)/guest/s/default/": .init(status: 302, location: "http://captive.apple.com/hotspot-detect.html"),
            "\(host)/guest/s/default/hotspotconfig": .init(body: config),
            "\(host)/guest/s/default/login": .init(body: answer),
        ]
    }
}
