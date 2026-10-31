import Foundation

/// A description of a login page Wi-Fi Refill does not know yet, built only from what the probe already received.
///
/// It is an allowlist, not a filter: status codes, host names, form methods and input types, and path segments,
/// parameter names and field names only when they are common login page words. Everything else becomes a
/// placeholder. There is no page text, no title, no parameter value and no IP address.
public enum PortalReport {
    static let words: Set<String> = [
        "access", "accept", "accept_terms", "agree", "ap", "ap_mac", "apmac", "api", "auth", "auth_pass", "auth_user",
        "authenticate", "authentication", "base_grant_url", "button", "captive", "cgi", "cgi-bin", "chap_challenge",
        "chap_id", "checkbox", "client_ip", "client_mac", "clientmac", "cmd", "code", "connect", "continue",
        "continue_url", "cp", "csrf", "_token", "direct", "download", "dst", "email", "essid", "expand", "facebook",
        "first_name", "firstname", "gateway_id", "get", "google", "grant", "guest", "guests", "gw", "gw_address",
        "gw_id", "gw_port", "gw_sn", "hidden", "hotspot", "index", "index.html", "index.php", "ip", "is_eg", "js",
        "landing", "lang", "language", "last_name", "lastname", "login", "login.html", "login.php", "logon", "mac",
        "mac_req", "maccauth", "nasip", "node_id", "node_mac", "number", "oneclick", "origurl", "pass", "password",
        "phone", "popup", "portal", "post", "radio", "redirect", "redirurl", "register", "res", "room", "session",
        "sessionid", "sid", "sign", "sign-in", "signin", "slot_num", "sms", "social", "splash", "src", "ssid",
        "stage", "start", "static", "submit", "success", "switchip", "tel", "terms", "text", "timestamp", "token",
        "tos", "url", "user", "user_continue_url", "username", "user_name", "users", "ustate", "v", "vlan", "voucher",
        "welcome", "wifi", "wifidog", "wifidogauth", "wlan",
    ]

    public static func summary(of hops: [Hop], app: String, system: String) -> String {
        var lines = [
            "Wi-Fi Refill \(app) on \(system) met this login page.",
            "Only page structure is listed. Unfamiliar names are replaced with *.",
            "",
        ]
        for (index, hop) in hops.enumerated() {
            lines.append("\(index + 1). \(hop.status) \(describe(hop.url))")
            if let location = hop.location { lines.append("   next: \(describe(location))") }
            for form in hop.body.matches(of: /(?is)<form\b([^>]*)>(.*?)<\/form>/) {
                let attributes = String(form.1)
                let method = (attribute("method", in: attributes) ?? "get").lowercased()
                let action = attribute("action", in: attributes).flatMap { URL(string: $0, relativeTo: hop.url) }.map(describe) ?? "same page"
                let fields = form.2.matches(of: /(?is)<(?:input|select|textarea)\b([^>]*)>/).map { field -> String in
                    let attributes = String(field.1)
                    let type = (attribute("type", in: attributes) ?? "text").lowercased()
                    return "\(known(attribute("name", in: attributes) ?? "")) (\(words.contains(type) ? type : "*"))"
                }
                lines.append("   form: \(["get", "post"].contains(method) ? method.uppercased() : "*") \(action); fields: \(fields.isEmpty ? "none" : fields.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Scheme, host, port, path and parameter names, each kept only when it is safe to share.
    static func describe(_ url: URL) -> String {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let port = parts?.port.map { ":\($0)" } ?? ""
        let path = (parts?.path ?? "").split(separator: "/", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : known(String($0)) }.joined(separator: "/")
        let names = parts?.queryItems?.map { known($0.name) } ?? []
        let scheme = ["http", "https"].contains(parts?.scheme) ? parts!.scheme! : "*"
        return "\(scheme)://\(hideHost(parts?.host ?? "*"))\(port)\(path)" + (names.isEmpty ? "" : "?" + names.joined(separator: "&"))
    }

    static func known(_ word: String) -> String {
        words.contains(word.lowercased()) ? word : "*"
    }

    /// Router addresses in private ranges help a driver author and identify nobody; other IP addresses could.
    /// Of a host name only the last two labels stay, the domain that names the vendor; labels before them become *.
    public static func hideHost(_ host: String) -> String {
        if host.contains(":") { return "ip-address" }
        if let match = host.wholeMatch(of: /(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}/) {
            let first = Int(match.1) ?? 0, second = Int(match.2) ?? 0
            let isPrivate = first == 10 || (first == 192 && second == 168) || (first == 172 && (16...31).contains(second))
            return isPrivate ? host : "ip-address"
        }
        let labels = host.split(separator: ".").map(String.init)
        return (labels.dropLast(2).map { _ in "*" } + labels.suffix(2)).joined(separator: ".")
    }

    static func attribute(_ name: String, in attributes: String) -> String? {
        for match in attributes.matches(of: /(?is)([a-z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/) where match.1.lowercased() == name {
            return String(match.2 ?? match.3 ?? match.4 ?? "")
        }
        return nil
    }

    /// A new-issue address with the summary filled in. GitHub receives the text as soon as the page opens; it is
    /// only published when the person submits the issue.
    public static func issueURL(repository: String, title: String, body: String) -> URL {
        var parts = URLComponents(string: "https://github.com/\(repository)/issues/new")!
        parts.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "labels", value: "login page"),
            URLQueryItem(name: "body", value: String(body.prefix(6000))),
        ]
        return parts.url!
    }
}
