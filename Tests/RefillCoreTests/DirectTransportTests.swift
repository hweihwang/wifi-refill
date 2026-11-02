import Foundation
import Testing
@testable import RefillCore

struct DirectTransportTests {
    typealias Framing = DirectTransport.Framing

    func frame(_ text: String, closed: Bool = false, full: Bool = false) -> Framing {
        DirectTransport.frame(Data(text.utf8), closed: closed, full: full)
    }

    func body(_ framing: Framing) -> String? {
        guard case .complete(_, _, let body) = framing else { return nil }
        return String(decoding: body, as: UTF8.self)
    }

    /// Kestrel, which serves Awing's pages, answers in chunks and keeps the connection open.
    @Test func readsAChunkedAnswer() {
        let answer = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n7\r\n{\"a\":1,\r\n6\r\n\"b\":2}\r\n0\r\n\r\n"
        #expect(body(frame(answer)) == #"{"a":1,"b":2}"#)
        #expect(frame(String(answer.dropLast(5))) == .incomplete)
        guard case .complete(200, let headers, _) = frame(answer) else { Issue.record("not complete"); return }
        #expect(headers["content-type"] == "application/json")
    }

    /// The Wi-Fi controller and many routers answer in HTTP/1.0 and end the answer by closing the connection.
    @Test func readsAnAnswerThatEndsWithTheConnection() {
        let answer = "HTTP/1.0 302 Found\r\nLocation: /weblogin.htm\r\nContent-type: text/html\r\n\r\n<a>"
        #expect(frame(answer) == .incomplete)
        guard case .complete(302, let headers, let content) = frame(answer, closed: true) else { Issue.record("not complete"); return }
        #expect(headers["location"] == "/weblogin.htm")
        #expect(content == Data("<a>".utf8))
    }

    @Test func stopsAtContentLength() {
        #expect(body(frame("HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nSuccessextra")) == "Success")
    }

    @Test func readsNoBodyForNotModifiedWhateverItsLengthSays() {
        #expect(body(frame("HTTP/1.1 304 Not Modified\r\nContent-Length: 42\r\n\r\n")) == "")
        #expect(body(frame("HTTP/1.1 204 No Content\r\nTransfer-Encoding: chunked\r\n\r\n")) == "")
    }

    @Test func skipsInterimAnswers() {
        guard case .complete(200, _, _) = frame("HTTP/1.1 103 Early Hints\r\nLink: </a.css>\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok") else {
            Issue.record("the 103 was taken as the answer"); return
        }
    }

    /// A short body is not the answer: a network could otherwise pass off a fragment of Apple's page as being online.
    @Test func refusesAnAnswerCutShort() {
        #expect(frame("HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\n<TITLE>Success</TITLE>", closed: true) == .malformed)
        #expect(frame("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n16\r\n<TITLE>Success</TITLE>\r\n", closed: true) == .malformed)
        #expect(frame("HTTP/1.1 200 OK\r\nContent-Length: 2", closed: true) == .malformed)
    }

    /// Lengths from a hostile network must never crash the app.
    @Test(arguments: [
        "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\nx",
        "HTTP/1.1 200 OK\r\nContent-Length: 99999999999999999999\r\n\r\nx",
        "HTTP/1.1 200 OK\r\nContent-Length: 5, 7\r\n\r\nx",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\nx",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\nx",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nokXX0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\nok",
        "HTTP/1.1 -200 OK\r\n\r\n",
        "SSH-2.0-OpenSSH\r\n\r\n",
    ])
    func refusesMalformedAnswers(answer: String) {
        #expect(frame(answer, closed: true) == .malformed)
    }

    @Test func keepsWhatArrivedWhenTheBodyPassesTheLimit() {
        #expect(body(frame("HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n\r\nabc", full: true)) == "abc")
    }

    @Test func writesTheRequestABrowserWould() {
        var request = URLRequest(url: URL(string: "http://10.29.64.2:880/cgi-bin/hslogin.cgi?a=b%20c")!)
        request.httpMethod = "POST"
        request.httpBody = Data("f=1".utf8)
        request.setValue("http://v1.awingconnect.vn/\r\nX-Injected: 1", forHTTPHeaderField: "Referer")
        let message = String(decoding: DirectTransport.message(for: request, url: request.url!), as: UTF8.self)
        #expect(message.hasPrefix("POST /cgi-bin/hslogin.cgi?a=b%20c HTTP/1.1\r\n"))
        #expect(message.contains("\r\nHost: 10.29.64.2:880\r\n"))
        #expect(message.contains("\r\nContent-Length: 3\r\n"))
        #expect(message.contains("\r\nAccept-Encoding: identity\r\n"))
        #expect(message.contains("\r\nConnection: close\r\n"))
        #expect(!message.contains("X-Injected"), "a header value cannot start a new header")
        #expect(message.hasSuffix("\r\n\r\nf=1"))
    }
}
