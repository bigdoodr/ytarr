import Foundation
import Testing
@testable import YTArrCore

/// Drives the real web server over HTTP: login page, session cookie, sign out, Basic for scripts.
/// Uses a throwaway state file and never starts the engine, so no sources are checked or downloaded.
struct SignInFlowTests {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                        newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    private struct Reply { var status: Int; var headers: [String: String]; var body: String }

    private static func send(_ method: String, _ url: String, headers: [String: String] = [:], form: String? = nil) async throws -> Reply {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let form {
            req.httpBody = Data(form.utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false; cfg.httpCookieStorage = nil
        let session = URLSession(configuration: cfg, delegate: NoRedirect(), delegateQueue: nil)
        let (data, resp) = try await session.data(for: req)
        let http = resp as! HTTPURLResponse
        var h: [String: String] = [:]
        for (k, v) in http.allHeaderFields { h[String(describing: k).lowercased()] = String(describing: v) }
        return Reply(status: http.statusCode, headers: h, body: String(decoding: data, as: UTF8.self))
    }

    @Test func formsLoginEndToEnd() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ytarr-signin-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let port = 18_731
        let base = "http://127.0.0.1:\(port)"
        let origin = ["Origin": base]
        let server = Task {
            try await runWebServer(store: Store(url: tmp), engine: Engine(store: Store(url: tmp)),
                                   config: WebConfig(bind: "127.0.0.1", port: port, password: "s3cret pass", username: "casey"))
        }
        defer { server.cancel() }

        // wait for the server to come up
        var up = false
        for _ in 0..<50 {
            if (try? await Self.send("GET", base + "/login")) != nil { up = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try #require(up, "server did not start")

        // not signed in: browsers go to the login page and come back afterwards; the API says 401
        let gate = try await Self.send("GET", base + "/sources/abc/browse?x=1")
        #expect(gate.status == 303)
        #expect(gate.headers["location"] == "/login?next=/sources/abc/browse%3Fx%3D1")
        #expect(try await Self.send("GET", base + "/api/status").status == 401)
        #expect(try await Self.send("POST", base + "/sources/abc/delete", headers: origin).status == 401)

        let page = try await Self.send("GET", base + "/login")
        #expect(page.status == 200)
        #expect(page.body.contains("name=\"username\"") && page.body.contains("type=\"password\""))

        // wrong password, and a cross-site post is refused before anything is checked
        let bad = try await Self.send("POST", base + "/login", headers: origin, form: "username=casey&password=nope&next=%2F")
        #expect(bad.status == 401)
        #expect(bad.body.contains("Incorrect username or password"))
        #expect(bad.headers["set-cookie"] == nil)
        let foreign = try await Self.send("POST", base + "/login", headers: ["Origin": "http://evil.example"],
                                          form: "username=casey&password=s3cret%20pass")
        #expect(foreign.status == 403)

        // right credentials: a session cookie, HttpOnly + SameSite=Lax, and an open-redirect attempt is ignored
        let ok = try await Self.send("POST", base + "/login", headers: origin,
                                     form: "username=casey&password=s3cret%20pass&remember=on&next=https%3A%2F%2Fevil.example%2F")
        #expect(ok.status == 303)
        #expect(ok.headers["location"] == "/")
        let cookie = try #require(ok.headers["set-cookie"])
        #expect(cookie.contains("ytarr_session=") && cookie.contains("HttpOnly") && cookie.contains("SameSite=Lax") && cookie.contains("Max-Age="))
        let token = String(cookie.dropFirst("ytarr_session=".count).prefix(while: { $0 != ";" }))
        let session = ["Cookie": "ytarr_session=\(token)"]

        let home = try await Self.send("GET", base + "/", headers: session)
        #expect(home.status == 200)
        #expect(home.body.contains("Sign out"))
        #expect(try await Self.send("GET", base + "/login", headers: session).status == 303)   // already signed in

        // scripts can still use HTTP Basic with the same username and password
        func basic(_ u: String, _ p: String) -> [String: String] { ["Authorization": "Basic " + Data("\(u):\(p)".utf8).base64EncodedString()] }
        #expect(try await Self.send("GET", base + "/api/status", headers: basic("casey", "s3cret pass")).status == 200)
        #expect(try await Self.send("GET", base + "/api/status", headers: basic("someone", "s3cret pass")).status == 401)

        // sign out ends the session
        let out = try await Self.send("POST", base + "/logout", headers: origin.merging(session) { a, _ in a })
        #expect(out.status == 303 && out.headers["location"] == "/login")
        #expect(try await Self.send("GET", base + "/", headers: session).status == 303)
    }
}
