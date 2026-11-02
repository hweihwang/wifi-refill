import Foundation
@testable import RefillCore

/// An Awing Free Wi-Fi page on Extreme Networks Wi-Fi, recorded at a Highlands Coffee on 2026-11-02 (Safari's history
/// and cache of the login, and curl replaying the page's `/Home/VerifyUrl` request, which answers only with the page
/// address as Referer).
/// Identifiers are replaced: the Mac's and the access point's hardware addresses (also inside `Qv`, where every letter,
/// digit and space is shifted by one), the store id, Awing's token and session.
enum AwingFixture {
    static let page = "v1.awingconnect.vn"
    static let controller = "10.29.64.2"
    static let qv = "it_qpmjdz=Dbqujwf.ID@bbb_qpmjdz=@dmjfou_njou=211111112@dmjfou_nbd=13.11.11.11.11.12@ttje=Ijhimboet!Dpggff@bq_nbd=13.11.11.11.11.13"
    static let login = "http://v1.awingconnect.vn/login?client_mac=02-00-00-00-00-01&ap_mac=02-00-00-00-00-02&hs_server=10.29.64.2&Qv=it_qpmjdz=Dbqujwf.ID@bbb_qpmjdz=@dmjfou_njou=211111112@dmjfou_nbd=13.11.11.11.11.12@ttje=Ijhimboet!Dpggff@bq_nbd=13.11.11.11.11.13"
    static let network = LocalNetwork(interface: "en0", router: "10.29.64.1", address: "10.29.64.96", mask: "255.255.252.0")
    static let verify = #"{"token":"0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c","captiveContext":{"campaignData":{"sessionId":"0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d","macAddress":"02-00-00-00-00-01","apMac":"02-00-00-00-00-02","placeId":10001,"workspaceId":104,"url":"http://v1.awingconnect.vn/login?client_mac=02-00-00-00-00-01&ap_mac=02-00-00-00-00-02&hs_server=10.29.64.2&Qv=it_qpmjdz=Dbqujwf.ID@bbb_qpmjdz=@dmjfou_njou=211111112@dmjfou_nbd=13.11.11.11.11.12@ttje=Ijhimboet!Dpggff@bq_nbd=13.11.11.11.11.13","userAgent":"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15","campaignId":0,"campaignGroupId":0,"campaignAdId":0,"campaignType":0,"isNetworkCampaign":false,"loginId":0,"loginHtml":null,"welcomeId":0,"welcomeHtml":null},"customerActions":[0],"workspace":{"id":104,"name":"Highlands Coffee","networkStatus":3,"workspaceClassId":6,"description":"[Link:https://www.highlandscoffee.com.vn/ ][Description:Là chuỗi cà phê lớn nhất cả nước với hình ảnh kết hợp giữa giá trị truyền thống và nhịp sống hiện đại. Tệp khách hàng của Highlands phần lớn là các doanh nhân, dân văn phòng, công sở mang đặc điểm tiêu dùng cao. Hệ thống lên đến hơn 700 cửa hàng trải rộng từ các trung tâm thương mại, tòa nhà văn phòng, khu dân cư đến các điểm giao thông trọng yếu.][NameVie:Highlands Coffee][Attribute:Coffee - Beverage Chains][ClassC:]","requiredCustomerData":null,"url":"","customizeCustomerFormPath":"","contactPhoneNumber":"","type":2,"shareType":0,"rateSharing":100.0,"customizeCampaignDefaultPath":null,"customizeIconPath":null,"directoryPath":".1.10171.10172.10173.104#","userWorkspaces":[],"workspaceAttributes":[],"workspaceTemplateStatuses":[],"workspaceCustomerInfoCollection":null},"customer":null,"placeCustomerInfoCollection":{"fields":[0,1],"timeReminder":null},"pageViewEvents":[],"customerRequiredFields":[],"contentAuthenForm":"<form name=\"extreme\" id=\"frmLogin\" action=\"/cgi-bin/hslogin.cgi\" method=\"POST\" style=\"display: none;\">\n    <input name=\"f_flex\" id=\"f_flex\" type=\"hidden\">\n    <input name=\"f_flex_type\" id=\"f_flex_type\" type=\"hidden\" value=\"log\">\n    <input name=\"f_hs_server\" id=\"f_hs_server\" type=\"hidden\">\n    <input name=\"f_Qv\" id=\"f_Qv\" type=\"hidden\">\n</form>\n<script>\n    // set params from URL to form\n    var hs_server = \"NONE\";\n    var port = 880;\n    var postToUrl = \"/cgi-bin/hslogin.cgi\";\n    hs_server = getQueryVariable(\"hs_server\");\n    Qv = getQueryVariable(\"Qv\");\n    postToUrl = \":\" + port + postToUrl;\n    document.getElementById(\"f_hs_server\").value = hs_server;\n    document.getElementById(\"f_Qv\").value = Qv;\n    document.getElementById(\"frmLogin\").action = \"http://\" + hs_server + postToUrl;\n\n    function getQueryVariable(variable) {\n        var query = window.location.search.substring(1);\n        var vars = query.split(/[?&]/);\n        for (var i = 0; i < vars.length; i++) {\n            var pair = vars[i].split(\"=\");\n            if (pair[0] == variable) {\n                if (pair[0] == \"Qv\") {\n                    return vars[i].substr(3, vars[i].length);\n                }\n                return pair[1]; \n            }\n        }\n        return \"\";\n    }\n    awingStateMachineContext.setAuthenType(awingConstants.AUTHEN_TYPE.IFRAME);\n</script>","createdDate":"2026-11-02T14:58:02.1111859+07:00"}}"#

    static func routes(
        login: String = login,
        verify: String? = verify,
        verifyStatus: Int = 200,
        controller: FakeNetwork.Response = .init(status: 302, location: "http://v1.awingconnect.vn/Success")
    ) -> [String: FakeNetwork.Response] {
        var routes: [String: FakeNetwork.Response] = [
            "captive.apple.com/hotspot-detect.html": .init(status: 302, location: login),
            "\(Self.controller)/cgi-bin/hslogin.cgi": controller,
        ]
        routes["\(page)/Home/VerifyUrl"] = verify.map { .init(status: verifyStatus, body: $0) }
        return routes
    }

    /// The recorded answer with one change to its JSON.
    static func verify(changing change: (inout [String: Any]) -> Void) -> String {
        var json = try! JSONSerialization.jsonObject(with: Data(verify.utf8)) as! [String: Any]
        var context = json["captiveContext"] as! [String: Any]
        change(&context)
        json["captiveContext"] = context
        return String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }
}
