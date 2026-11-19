import Foundation
import Hummingbird
import HTTPTypes

/// Sessions for the "Forms (Login Page)" sign-in. Kept in memory, so restarting YTArr signs everyone out.
final class AuthState: @unchecked Sendable {
    static let cookieName = "ytarr_session"
    private let lock = NSLock()
    private var sessions: [String: Date] = [:]     // token -> expiry
    private var failures: [Date] = []              // recent failed sign-ins

    static func newToken() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &g)) }.joined()
    }

    /// Compares without stopping at the first difference, so response time doesn't leak how much matched.
    static func secureEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(truncatingIfNeeded: x.count ^ y.count)
        for i in 0..<max(x.count, y.count) { diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0) }
        return diff == 0
    }

    func startSession(lifetime: TimeInterval) -> String {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        sessions = sessions.filter { $0.value > now }
        let t = Self.newToken()
        sessions[t] = now.addingTimeInterval(lifetime)
        return t
    }

    func isValid(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let exp = sessions[token] else { return false }
        if exp <= Date() { sessions[token] = nil; return false }
        return true
    }

    func endSession(_ token: String) { lock.lock(); sessions[token] = nil; lock.unlock() }

    func recordFailure() {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-60)
        failures = failures.filter { $0 > cutoff } + [Date()]
    }

    /// Seconds until another attempt is allowed, or nil. Five failures inside a minute lock sign-in for the rest of it.
    func lockoutRemaining() -> Int? {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-60)
        let recent = failures.filter { $0 > cutoff }
        guard recent.count >= 5, let oldest = recent.first else { return nil }
        return max(1, Int(oldest.addingTimeInterval(60).timeIntervalSinceNow.rounded(.up)))
    }
}

/// Requires a signed-in session. Browsers are sent to the login page; scripts can still use HTTP Basic.
struct FormsAuth<Context: RequestContext>: RouterMiddleware {
    let username: String
    let password: String
    let state: AuthState

    private func basicMatches(_ request: Request) -> Bool {
        guard let h = request.headers[.authorization], h.hasPrefix("Basic "),
              let data = Data(base64Encoded: String(h.dropFirst(6))),
              let cred = String(data: data, encoding: .utf8),
              let colon = cred.firstIndex(of: ":") else { return false }
        let user = String(cred[cred.startIndex..<colon]), pass = String(cred[cred.index(after: colon)...])
        return AuthState.secureEqual(user, username) && AuthState.secureEqual(pass, password)
    }

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        if path == "/login" { return try await next(request, context) }
        if let token = request.cookies[AuthState.cookieName]?.value, state.isValid(token) { return try await next(request, context) }
        if basicMatches(request) { return try await next(request, context) }

        if path.hasPrefix("/api/") {
            return Response(status: .unauthorized, headers: [.wwwAuthenticate: "Basic realm=\"YTArr\""])
        }
        if request.method == .get || request.method == .head {
            let target = path + (request.uri.query.map { "?" + $0 } ?? "")
            let enc = target.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))) ?? "/"
            return Response(status: .seeOther, headers: [.location: "/login?next=\(enc)"])
        }
        return Response(status: .unauthorized)
    }
}

/// Only same-site paths: never bounce someone to another host after they sign in.
func safeNextPath(_ n: String) -> String {
    n.hasPrefix("/") && !n.hasPrefix("//") && !n.contains("\\") && !n.hasPrefix("/login") ? n : "/"
}
