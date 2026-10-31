/// The Ruijie Cloud one-click flow recorded at a cafe on 2026-10-31 (curl -v at the moment the session ended).
/// Identifiers are replaced: router id and serial, the Mac's address, the public address, signatures and the session.
/// The `/api/auth/direct/` reply follows the shape the page's own script reads (oneClickLogin.js: success, result.logonUrl).
enum RuijieFixture {
    static let sessionId = "5f0c2b7e9a1d4c3e8b6a0f1e2d3c4b5a"
    static let portal = "portal-as.ruijienetworks.com"
    static let gatewayQuery = "gw_id=0a1b2c3d4e5f&gw_sn=H1UC00TEST001&gw_address=192.168.110.1&gw_port=2060&ip=192.168.110.10&mac=02:00:00:00:00:01&slot_num=13&nasip=203.0.113.7&ssid=Cafe%20Guest&ustate=0&mac_req=1&url=http%3A%2F%2Fcaptive%2Eapple%2Ecom%2Fhotspot%2Ddetect%2Ehtml&chap_id=%5C022&chap_challenge=%5C241%5C143%5C312&v=2&timestamp=1793433582&sign=9d1c0e5b7a3f2e4d6c8b0a1f3e5d7c9b"

    static func routes(
        isEG: String = "0",
        scriptTarget: String? = nil,
        settings: String = #"{"post_url":"https://www.google.com/","oneclick":{"oneclick_validity":"60","oneclick_qos":{"up_rate":"10000000","down_rate":"10000000"},"oneclick_times":"0"},"custom_html":{"login_options":["pass"],"lang":["en_US"]}}"#,
        direct: String = #"{"success":true,"timestamp":1793433590000,"message":"ok","result":{"logonUrl":"http://192.168.110.1:2060/wifidog/auth?token=7e3a9c1b5d2f4e6a8c0b1d3f5a7c9e1b&phoneNumber=0200.0000.0001"}}"#
    ) -> [String: FakeNetwork.Response] {
        [
            "captive.apple.com/hotspot-detect.html": .init(status: 302, location: "https://\(portal)/auth/wifidogAuth/login/?\(gatewayQuery)"),
            "\(portal)/auth/wifidogAuth/login/": .init(body: "<script>self.location.href='\(scriptTarget ?? "/api/auth/wifidog?stage=portal&\(gatewayQuery)")'</script>"),
            "\(portal)/api/auth/wifidog": .init(status: 302, location: "/download/static/maccauth/src/index.html?RES=./../expand/res/e6gosjyxkvkzvuabekw&IS_EG=\(isEG)&sessionId=\(sessionId)"),
            "\(portal)/download/static/maccauth/src/index.html": .init(body: "<html>login page</html>"),
            "\(portal)/download/static/maccauth/expand/res/e6gosjyxkvkzvuabekw/config.json": .init(body: settings),
            "\(portal)/api/auth/direct/": .init(body: direct),
            "192.168.110.1/wifidog/auth": .init(status: 302, location: "https://www.google.com/?gw_id=0a1b2c3d4e5f"),
        ]
    }
}
