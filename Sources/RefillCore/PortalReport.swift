import Foundation

/// A description of a login page Wi-Fi Refill does not know yet, detailed enough to write a driver and nothing more.
///
/// It is built from an allowlist: status codes, host names, paths, the names of query parameters and form fields,
/// page titles and button labels. It never contains query values, cookies, headers, raw page bodies, or the Mac's
/// addresses. Path segments that look like identifiers are replaced.
public enum PortalReport {
    public static func summary(of hops: [Hop], app: String, system: String) -> String {
        var lines = [
            "Wi-Fi Refill \(app) on \(system) met this login page.",
            "Only page structure is listed: no parameter values, cookies, page text or addresses of this Mac.",
            "",
        ]
        for (index, hop) in hops.enumerated() {
            lines.append("\(index + 1). \(hop.status) \(describe(hop.url))")
            if let location = hop.location { lines.append("   next: \(describe(location))") }
            if let title = hop.body.firstMatch(of: /(?is)<title[^>]*>(.*?)<\/title>/)?.1 {
                lines.append("   title: \(clean(String(title)))")
            }
            for form in hop.body.matches(of: /(?is)<form\b([^>]*)>(.*?)<\/form>/) {
                let attributes = String(form.1)
                let method = attribute("method", in: attributes) ?? "get"
                let action = attribute("action", in: attributes).flatMap { URL(string: $0, relativeTo: hop.url) }.map(describe) ?? "same page"
                let fields = form.2.matches(of: /(?is)<(?:input|select|textarea)\b([^>]*)>/).compactMap { field -> String? in
                    let attributes = String(field.1)
                    guard let name = attribute("name", in: attributes) else { return nil }
                    return "\(clean(name)) (\(attribute("type", in: attributes) ?? "text"))"
                }
                lines.append("   form: \(method.uppercased()) \(action); fields: \(fields.isEmpty ? "none" : fields.joined(separator: ", "))")
            }
            let buttons = hop.body.matches(of: /(?is)<button\b[^>]*>(.*?)<\/button>/).map { clean(String($0.1)) }.filter { !$0.isEmpty }
            if !buttons.isEmpty { lines.append("   buttons: \(buttons.prefix(8).joined(separator: " | "))") }
        }
        return lines.joined(separator: "\n")
    }

    /// Host, path with identifier-like segments replaced, and query parameter names without values.
    static func describe(_ url: URL) -> String {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let host = parts?.host.map(hideAddress) ?? "?"
        let port = parts?.port.map { ":\($0)" } ?? ""
        let path = (parts?.path ?? "").split(separator: "/", omittingEmptySubsequences: false).map { segment in
            segment.count >= 12 && segment.contains(where: \.isNumber) ? "{id}" : String(segment)
        }.joined(separator: "/")
        let names = parts?.queryItems?.map(\.name) ?? []
        return "\(parts?.scheme ?? "?")://\(host)\(port)\(path)" + (names.isEmpty ? "" : "?" + names.joined(separator: "&"))
    }

    /// Public IP addresses can locate a person; private router addresses cannot and help a driver author.
    public static func hideAddress(_ host: String) -> String {
        guard let match = host.wholeMatch(of: /(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}/) else { return host }
        let first = Int(match.1) ?? 0, second = Int(match.2) ?? 0
        let isPrivate = first == 10 || (first == 192 && second == 168) || (first == 172 && (16...31).contains(second))
        return isPrivate ? host : "public-ip"
    }

    static func attribute(_ name: String, in attributes: String) -> String? {
        for match in attributes.matches(of: /(?is)([a-z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/) where match.1.lowercased() == name {
            return String(match.2 ?? match.3 ?? match.4 ?? "")
        }
        return nil
    }

    static func clean(_ text: String) -> String {
        let plain = text.replacing(/<[^>]*>/, with: " ").replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
        return String(plain.prefix(80))
    }

    /// A new-issue address with the summary filled in.
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
