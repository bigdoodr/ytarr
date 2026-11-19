import Foundation

enum H {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let css = """
    :root{color-scheme:light dark;--bg:#fff;--fg:#1d1d1f;--mut:#6e6e73;--line:#d2d2d7;--acc:#0a66ff;--card:#f5f5f7;--bad:#c62828;--ok:#2e7d32}
    @media(prefers-color-scheme:dark){:root{--bg:#1c1c1e;--fg:#f5f5f7;--mut:#98989d;--line:#3a3a3c;--acc:#4c9aff;--card:#2c2c2e;--bad:#ef5350;--ok:#66bb6a}}
    *{box-sizing:border-box}body{margin:0;font:15px/1.45 -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--fg)}
    header{display:flex;gap:18px;align-items:center;padding:12px 24px;border-bottom:1px solid var(--line);background:var(--card);flex-wrap:wrap}
    header b{font-size:17px}header a{color:var(--fg);text-decoration:none;padding:4px 2px}header a.on{color:var(--acc);border-bottom:2px solid var(--acc)}
    header .r{margin-left:auto;color:var(--mut);font-size:13px}
    main{max-width:1100px;margin:0 auto;padding:20px 24px}
    h1{font-size:22px;margin:0 0 14px}h2{font-size:17px;margin:26px 0 8px}
    table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top}
    th{color:var(--mut);font-weight:600;font-size:13px}
    a{color:var(--acc)}.mut{color:var(--mut)}.bad{color:var(--bad)}.ok{color:var(--ok)}
    .btn,button{font:inherit;padding:6px 14px;border-radius:8px;border:1px solid var(--line);background:var(--card);color:var(--fg);cursor:pointer;text-decoration:none;display:inline-block}
    .btn.p,button.p{background:var(--acc);border-color:var(--acc);color:#fff}button.d{color:var(--bad)}
    form.f{display:grid;grid-template-columns:200px 1fr;gap:10px 14px;max-width:820px;align-items:center}
    form.f label{color:var(--mut)}input[type=text],input[type=number],input[type=password],select,textarea{font:inherit;width:100%;padding:6px 8px;border-radius:8px;border:1px solid var(--line);background:var(--bg);color:var(--fg)}
    form.f .full{grid-column:1/-1}.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
    pre{background:var(--card);padding:12px;border-radius:8px;overflow:auto;font-size:12.5px;max-height:420px}
    .pill{display:inline-block;padding:1px 8px;border-radius:99px;background:var(--card);border:1px solid var(--line);font-size:12px}
    small{color:var(--mut)}
    .signout{display:inline;margin:0}.signout button{padding:2px 10px;font-size:13px}
    .login{max-width:340px;margin:12vh auto;padding:0 20px}.login h1{text-align:center;margin-bottom:18px}
    .login form{display:grid;gap:12px}.login input[type=text],.login input[type=password]{padding:10px}
    .pg{margin:8px 0;color:var(--mut);font-size:13px}.pg b{color:var(--fg)}.pg a{margin:0 2px}
    """

    /// Set when a password is configured, so every page offers Sign out.
    nonisolated(unsafe) static var showSignOut = false

    static func page(_ title: String, active: String, status: Engine.Status, refresh: Bool = false, _ body: String) -> String {
        func nav(_ id: String, _ label: String, _ href: String) -> String {
            "<a href=\"\(href)\"\(active == id ? " class=\"on\"" : "")>\(label)</a>"
        }
        let state: String
        if status.updating { state = "Updating yt-dlp..." }
        else if let p = status.pausedUntil { state = "Paused until \(date(p)) (YouTube rate limit)" }
        else if let r = status.running { state = "Running: \(esc(r))" }
        else { state = "Idle" }
        let ver = status.ytdlpVersion.map { "yt-dlp \(esc($0))" } ?? "yt-dlp not installed"
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        \(refresh ? "<meta http-equiv=\"refresh\" content=\"5\">" : "")
        <title>\(esc(title)) - YTArr</title><style>\(css)</style></head><body>
        <header><b>YTArr</b>\(nav("sources", "Sources", "/"))\(nav("profiles", "Profiles", "/profiles"))\(nav("activity", "Activity", "/activity"))\(nav("settings", "Settings", "/settings"))
        <span class="r">\(state) &middot; \(ver)\(showSignOut ? " &middot; <form class=\"signout\" method=\"post\" action=\"/logout\"><button>Sign out</button></form>" : "")</span></header><main>\(body)</main></body></html>
        """
    }

    static func loginPage(error: String?, next: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Sign in - YTArr</title><style>\(css)</style></head><body>
        <div class="login"><h1>YTArr</h1>
        \(error.map { "<p class=\"bad\">\(esc($0))</p>" } ?? "")
        <form method="post" action="/login">
        <input type="hidden" name="next" value="\(esc(next))">
        <input type="text" name="username" placeholder="Username" autocomplete="username" autocapitalize="none" autocorrect="off" autofocus required>
        <input type="password" name="password" placeholder="Password" autocomplete="current-password" required>
        <label class="row"><input type="checkbox" name="remember" checked> Remember me</label>
        <button class="p">Sign in</button>
        </form></div></body></html>
        """
    }

    static let df: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f }()
    static func date(_ d: Date?) -> String { d.map { df.string(from: $0) } ?? "never" }

    static func input(_ label: String, _ name: String, _ value: String, hint: String = "", type: String = "text") -> String {
        "<label>\(label)</label><div><input type=\"\(type)\" name=\"\(name)\" value=\"\(esc(value))\">\(hint.isEmpty ? "" : "<small>\(hint)</small>")</div>"
    }
    static func check(_ label: String, _ name: String, _ on: Bool) -> String {
        "<label>\(label)</label><div><input type=\"checkbox\" name=\"\(name)\"\(on ? " checked" : "")></div>"
    }
    static func select(_ label: String, _ name: String, _ options: [(String, String)], selected: String) -> String {
        let opts = options.map { "<option value=\"\(esc($0.0))\"\($0.0 == selected ? " selected" : "")>\(esc($0.1))</option>" }.joined()
        return "<label>\(label)</label><div><select name=\"\(name)\">\(opts)</select></div>"
    }
}

/// Parses application/x-www-form-urlencoded bodies.
struct Form {
    private var values: [String: String] = [:]
    private var multi: [String: [String]] = [:]
    init(_ body: String) {
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let k = kv.first else { continue }
            func dec(_ s: Substring) -> String {
                s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(s)
            }
            let v = kv.count > 1 ? dec(kv[1]) : ""
            values[dec(k)] = v
            multi[dec(k), default: []].append(v)
        }
    }
    /// Every value submitted under this name (e.g. a list of checked boxes).
    func all(_ k: String) -> [String] { multi[k] ?? [] }
    /// The value exactly as submitted (passwords must not be trimmed).
    func raw(_ k: String) -> String { values[k] ?? "" }
    func str(_ k: String) -> String { (values[k] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    func bool(_ k: String) -> Bool { values[k] != nil }
    func int(_ k: String, default d: Int) -> Int { Int(str(k)) ?? d }
}
