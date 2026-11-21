import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Blocks cross-site form posts (CSRF) and DNS-rebinding: the Host must be a loopback name when bound to
/// loopback, and every state-changing request must come from a page on this same host.
struct OriginGuard<Context: RequestContext>: RouterMiddleware {
    let loopbackOnly: Bool
    static func hostOnly(_ h: String) -> String {
        var x = h.lowercased()
        if x.hasPrefix("[") { if let e = x.firstIndex(of: "]") { return String(x[x.startIndex...e]) } }
        if let c = x.firstIndex(of: ":") { x = String(x[x.startIndex..<c]) }
        return x
    }
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let host = request.head.authority.map(Self.hostOnly) ?? ""
        if loopbackOnly, !["localhost", "127.0.0.1", "[::1]"].contains(host) {
            return Response(status: .forbidden)
        }
        if request.method != .get && request.method != .head {
            let src = request.headers[.origin] ?? request.headers[.referer]
            guard let src, let u = URL(string: src), let h = u.host else { return Response(status: .forbidden) }
            let sh = h.contains(":") ? "[\(h.lowercased())]" : h.lowercased()
            if sh != host { return Response(status: .forbidden) }
        }
        return try await next(request, context)
    }
}

public struct WebConfig: Sendable {
    public var bind: String
    public var port: Int
    public var password: String?
    public var username: String
    public init(bind: String = "127.0.0.1", port: Int = 8686, password: String? = nil, username: String = "admin") {
        self.bind = bind; self.port = port; self.password = password; self.username = username
    }
}

private func html(_ s: String, status: HTTPResponse.Status = .ok) -> Response {
    Response(status: status, headers: [.contentType: "text/html; charset=utf-8"],
             body: ResponseBody(byteBuffer: ByteBuffer(string: s)))
}
private func redirect(_ to: String) -> Response { Response(status: .seeOther, headers: [.location: to]) }
private func notFound() -> Response { html("<h1>Not found</h1>", status: .notFound) }

private func form(_ request: Request) async throws -> Form {
    let buf = try await request.body.collect(upTo: 1 << 20)
    return Form(String(buffer: buf))
}

/// Builds the router for the web UI.
public func makeRouter(store: Store, engine: Engine, password: String?, username: String = "admin", loopbackOnly: Bool = true) -> Router<BasicRequestContext> {
    let router = Router(context: BasicRequestContext.self)
    router.add(middleware: OriginGuard(loopbackOnly: loopbackOnly))
    let auth = AuthState()
    let authOn = !(password ?? "").isEmpty
    let loginName = username.isEmpty ? "admin" : username
    H.showSignOut = authOn
    if authOn { router.add(middleware: FormsAuth(username: loginName, password: password ?? "", state: auth)) }

    @Sendable func uuid(_ ctx: BasicRequestContext) -> UUID? { ctx.parameters.get("id").flatMap(UUID.init(uuidString:)) }

    // ---- Sign in / out ("Forms (Login Page)")
    router.get("/login") { request, _ in
        let next = safeNextPath(request.uri.queryParameters["next"].map(String.init) ?? "/")
        if !authOn { return redirect("/") }
        if let t = request.cookies[AuthState.cookieName]?.value, auth.isValid(t) { return redirect(next) }
        return html(H.loginPage(error: nil, next: next))
    }
    router.post("/login") { request, _ in
        guard authOn else { return redirect("/") }
        let f = try await form(request)
        let next = safeNextPath(f.str("next"))
        if let wait = auth.lockoutRemaining() {
            return html(H.loginPage(error: "Too many failed attempts. Try again in \(wait) seconds.", next: next), status: .tooManyRequests)
        }
        let userOK = AuthState.secureEqual(f.str("username"), loginName)
        let passOK = AuthState.secureEqual(f.raw("password"), password ?? "")
        guard userOK && passOK else {
            auth.recordFailure()
            try? await Task.sleep(nanoseconds: 1_000_000_000)   // slows down guessing
            return html(H.loginPage(error: "Incorrect username or password.", next: next), status: .unauthorized)
        }
        let remember = f.bool("remember")
        let lifetime: TimeInterval = remember ? 30 * 86400 : 12 * 3600
        var res = redirect(next)
        res.setCookie(Cookie(name: AuthState.cookieName, value: auth.startSession(lifetime: lifetime),
                             maxAge: remember ? Int(lifetime) : nil, path: "/", httpOnly: true, sameSite: .lax))
        return res
    }
    router.post("/logout") { request, _ in
        if let t = request.cookies[AuthState.cookieName]?.value { auth.endSession(t) }
        var res = redirect("/login")
        res.setCookie(Cookie(name: AuthState.cookieName, value: "", maxAge: 0, path: "/", httpOnly: true, sameSite: .lax))
        return res
    }

    // ---- Sources
    router.get("/") { _, _ in
        html(H.page("Sources", active: "sources", status: await engine.status(), refresh: true,
                    Pages.sources(await store.snapshot(), await engine.status())))
    }
    // Library lists come live from the media servers (nothing hardcoded); a failure just disables that picker.
    @Sendable func choices(_ configured: Bool, _ fetch: @Sendable () async throws -> [MediaLibrary]) async -> Pages.MediaChoices {
        guard configured else { return Pages.MediaChoices() }
        do { return Pages.MediaChoices(configured: true, libraries: try await fetch(), error: nil) }
        catch { return Pages.MediaChoices(configured: true, libraries: [], error: error.localizedDescription) }
    }
    @Sendable func mediaChoices() async -> (jellyfin: Pages.MediaChoices, abs: Pages.MediaChoices) {
        let s = await store.snapshot().settings
        async let jf = choices(MediaServers.jellyfinConfigured(s)) { try await MediaServers.jellyfinLibraries(s) }
        async let ab = choices(MediaServers.absConfigured(s)) { try await MediaServers.absLibraries(s) }
        return await (jf, ab)
    }
    router.get("/sources/new") { _, _ in
        let st = await store.snapshot()
        let m = await mediaChoices()
        return html(H.page("Add source", active: "sources", status: await engine.status(),
                           Pages.sourceForm(st, nil, isNew: true, jellyfin: m.jellyfin, audiobookshelf: m.abs)))
    }
    router.get("/sources/:id") { _, ctx in
        guard let id = uuid(ctx), let s = await store.source(id) else { return notFound() }
        let m = await mediaChoices()
        return html(H.page(s.name, active: "sources", status: await engine.status(),
                           Pages.sourceForm(await store.snapshot(), s, isNew: false, jellyfin: m.jellyfin, audiobookshelf: m.abs)))
    }
    @Sendable func apply(_ f: Form, to s: inout Source) {
        s.name = f.str("name"); s.url = f.str("url")
        if let p = UUID(uuidString: f.str("profile")) { s.profileID = p }
        s.destination = f.str("destination")
        s.jellyfinLibraryID = f.str("jellyfinLibrary").isEmpty ? nil : f.str("jellyfinLibrary")
        s.absLibraryID = f.str("absLibrary").isEmpty ? nil : f.str("absLibrary")
        s.intervalMinutes = max(15, f.int("interval", default: 360))
        s.backfillMode = BackfillMode(rawValue: f.str("backfill")) ?? .nothing
        s.backfillCount = max(0, f.int("count", default: 10))
        s.maxPerCheck = f.int("maxPerCheck", default: 0) > 0 ? f.int("maxPerCheck", default: 0) : nil
        s.monitorOnly = f.bool("monitorOnly")
        s.saveChannelCover = f.bool("channelCover")
        s.skipShorts = f.bool("skipShorts"); s.skipLive = f.bool("skipLive")
        s.titleRegex = f.str("titleRegex"); s.extraArgs = f.str("extraArgs")
        s.enabled = f.bool("enabled")
        s.kind = Source.detectKind(s.url)
        if s.name.isEmpty { s.name = s.url }
    }
    router.post("/sources") { request, _ in
        let f = try await form(request)
        guard !f.str("url").isEmpty else { return redirect("/sources/new") }
        var s = Source(name: "", url: "", profileID: UUID())
        apply(f, to: &s)
        await store.upsert(s)
        await engine.checkNow(s.id)          // first check right away
        // "Index only" sources go straight to the picker; it fills in once the scan finishes.
        return redirect(s.backfillMode == .nothing || s.monitorOnly == true ? "/sources/\(s.id)/browse" : "/")
    }
    router.post("/sources/:id") { request, ctx in
        guard let id = uuid(ctx), var s = await store.source(id) else { return notFound() }
        apply(try await form(request), to: &s)
        await store.upsert(s)
        return redirect("/")
    }
    router.post("/sources/:id/delete") { _, ctx in
        if let id = uuid(ctx) { await store.deleteSource(id) }
        return redirect("/")
    }
    router.post("/sources/:id/check") { _, ctx in
        if let id = uuid(ctx) { await engine.checkNow(id) }
        return redirect("/activity")
    }

    // ---- Browse: pick videos / playlists without downloading everything
    router.post("/sources/:id/seen") { _, ctx in
        guard let id = uuid(ctx) else { return notFound() }
        await store.clearNew(id)
        return redirect("/sources/\(id)/browse")
    }
    router.get("/sources/:id/browse") { _, ctx in
        guard let id = uuid(ctx), let s = await store.source(id) else { return notFound() }
        let status = await engine.status()
        let busy = status.running == s.name
        return html(H.page(s.name, active: "sources", status: status, refresh: busy,
                           Pages.browse(s, videos: await store.catalog(id, .videos), playlists: await store.catalog(id, .playlists),
                                        busy: busy, progress: status.progress)))
    }
    router.post("/sources/:id/cover") { _, ctx in
        guard let id = uuid(ctx) else { return notFound() }
        await engine.refreshCover(id)
        return redirect("/sources/\(id)/browse")
    }
    router.post("/sources/:id/scan") { _, ctx in
        guard let id = uuid(ctx) else { return notFound() }
        await engine.scanVideos(id)
        return redirect("/sources/\(id)/browse")
    }
    router.post("/sources/:id/scan-playlists") { _, ctx in
        guard let id = uuid(ctx) else { return notFound() }
        await engine.scanPlaylists(id)
        return redirect("/sources/\(id)/browse")
    }
    router.post("/sources/:id/download") { request, ctx in
        guard let id = uuid(ctx) else { return notFound() }
        await engine.download(id, videoIDs: try await form(request).all("v"))
        return redirect("/activity")
    }
    router.post("/sources/:id/playlists/add") { request, ctx in
        guard let id = uuid(ctx), let parent = await store.source(id) else { return notFound() }
        let wanted = Set(try await form(request).all("pl"))
        let known = Set(await store.snapshot().sources.map(\.url))
        for pl in await store.catalog(id, .playlists) where wanted.contains(pl.id) && !known.contains(pl.url) {
            var s = Source(name: pl.title, url: pl.url, profileID: parent.profileID)
            s.kind = Source.detectKind(pl.url)
            s.destination = parent.destination
            s.intervalMinutes = parent.intervalMinutes
            s.backfillMode = .nothing                 // index only: nothing downloads until picked
            s.skipShorts = parent.skipShorts; s.skipLive = parent.skipLive
            await store.upsert(s)
            await engine.checkNow(s.id)
        }
        return redirect("/")
    }
    router.post("/check-all") { _, _ in await engine.checkAll(); return redirect("/activity") }

    // ---- Profiles
    router.get("/profiles") { _, _ in
        html(H.page("Profiles", active: "profiles", status: await engine.status(), Pages.profiles(await store.snapshot())))
    }
    router.get("/profiles/new") { _, _ in
        html(H.page("New profile", active: "profiles", status: await engine.status(), Pages.profileForm(nil, isNew: true, inUse: false)))
    }
    router.get("/profiles/:id") { _, ctx in
        guard let id = uuid(ctx), let p = await store.profile(id) else { return notFound() }
        let used = await store.snapshot().sources.contains { $0.profileID == id }
        return html(H.page(p.name, active: "profiles", status: await engine.status(), Pages.profileForm(p, isNew: false, inUse: used)))
    }
    @Sendable func apply(_ f: Form, to p: inout Profile) {
        p.name = f.str("name"); p.kind = ProfileKind(rawValue: f.str("kind")) ?? .video
        p.format = f.str("format"); p.mergeFormat = f.str("mergeFormat")
        p.audioFormat = f.str("audioFormat"); p.audioQuality = f.str("audioQuality")
        p.outputTemplate = f.str("outputTemplate")
        p.embedMetadata = f.bool("embedMetadata"); p.embedThumbnail = f.bool("embedThumbnail")
        p.writeInfoJSON = f.bool("writeInfoJSON"); p.embedSubs = f.bool("embedSubs")
        p.writeThumbnail = f.bool("writeThumbnail"); p.nfoStyle = NFOStyle(rawValue: f.str("nfoStyle")) ?? NFOStyle.off
        p.albumTag = f.str("albumTag").isEmpty ? nil : f.str("albumTag")
        p.artistTag = f.str("artistTag").isEmpty ? nil : f.str("artistTag")
        p.sponsorblockRemove = f.str("sponsorblock"); p.extraArgs = f.str("extraArgs")
        if p.name.isEmpty { p.name = "Untitled profile" }
        if p.format.isEmpty { p.format = "bv*+ba/b" }
        if p.outputTemplate.isEmpty { p.outputTemplate = "%(title)s [%(id)s].%(ext)s" }
    }
    router.post("/profiles") { request, _ in
        var p = Profile(name: "", kind: .video, format: "", outputTemplate: "")
        apply(try await form(request), to: &p)
        await store.upsert(p)
        return redirect("/profiles")
    }
    router.post("/profiles/:id") { request, ctx in
        guard let id = uuid(ctx), var p = await store.profile(id) else { return notFound() }
        apply(try await form(request), to: &p)
        await store.upsert(p)
        return redirect("/profiles")
    }
    router.post("/profiles/:id/delete") { _, ctx in
        if let id = uuid(ctx) { _ = await store.deleteProfile(id) }
        return redirect("/profiles")
    }

    // ---- Activity
    router.get("/activity") { _, _ in
        let status = await engine.status()
        return html(H.page("Activity", active: "activity", status: status, refresh: true,
                           Pages.activity(await store.snapshot(), status, await engine.recentLog())))
    }
    router.post("/activity/cancel") { _, _ in await engine.cancelCurrent(); return redirect("/activity") }

    // ---- Settings
    router.get("/settings") { _, _ in
        let status = await engine.status()
        return html(H.page("Settings", active: "settings", status: status, refresh: status.updating,
                           Pages.settings(await store.snapshot(), status)))
    }
    router.post("/settings") { request, _ in
        let f = try await form(request)
        await store.mutateSettings { s in
            s.libraryRoot = f.str("libraryRoot").isEmpty ? s.libraryRoot : f.str("libraryRoot")
            s.autoUpdate = f.bool("autoUpdate")
            s.updateIntervalHours = max(1, f.int("updateIntervalHours", default: 24))
            s.updateChannel = ["stable", "nightly", "master"].contains(f.str("updateChannel")) ? f.str("updateChannel") : "stable"
            s.cookiesBrowser = f.str("cookiesBrowser"); s.cookiesFile = f.str("cookiesFile")
            s.sleepMinSeconds = max(0, f.int("sleepMin", default: 5))
            s.sleepMaxSeconds = max(s.sleepMinSeconds, f.int("sleepMax", default: 15))
            s.globalExtraArgs = f.str("globalExtraArgs"); s.ytdlpPathOverride = f.str("ytdlpPathOverride")
            // Keys are never sent back to the browser, so a blank key field means "keep the saved one".
            s.jellyfinURL = f.str("jellyfinURL")
            if !f.str("jellyfinAPIKey").isEmpty { s.jellyfinAPIKey = f.str("jellyfinAPIKey") }
            if s.jellyfinURL?.isEmpty == true { s.jellyfinAPIKey = nil }
            s.absURL = f.str("absURL")
            if !f.str("absAPIToken").isEmpty { s.absAPIToken = f.str("absAPIToken") }
            if s.absURL?.isEmpty == true { s.absAPIToken = nil }
        }
        return redirect("/settings")
    }
    router.post("/settings/media-test") { _, _ in
        let s = await store.snapshot().settings
        var out = ""
        if MediaServers.jellyfinConfigured(s) {
            do {
                let libs = try await MediaServers.jellyfinLibraries(s)
                out += "<p class=ok>Jellyfin: connected. \(libs.count) libraries: \(H.esc(libs.map(\.name).joined(separator: ", ")))</p>"
            } catch { out += "<p class=bad>Jellyfin: \(H.esc(error.localizedDescription))</p>" }
        } else { out += "<p class=mut>Jellyfin: not configured.</p>" }
        if MediaServers.absConfigured(s) {
            do {
                let libs = try await MediaServers.absLibraries(s)
                out += "<p class=ok>Audiobookshelf: connected. \(libs.count) libraries: \(H.esc(libs.map(\.name).joined(separator: ", ")))</p>"
            } catch { out += "<p class=bad>Audiobookshelf: \(H.esc(error.localizedDescription))</p>" }
        } else { out += "<p class=mut>Audiobookshelf: not configured.</p>" }
        return html(H.page("Media servers", active: "settings", status: await engine.status(),
                           "<h1>Media servers</h1>\(out)<p><a class=\"btn\" href=\"/settings\">Back to Settings</a></p>"))
    }
    router.post("/settings/ytdlp-update") { _, _ in await engine.updateYtDlpNow(); return redirect("/settings") }

    // ---- JSON status (handy for the menu-bar app / scripts)
    router.get("/api/status") { _, _ in
        let data = try JSONEncoder().encode(await engine.status())
        return Response(status: .ok, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
    return router
}

/// Runs the web UI until the surrounding task is cancelled.
public func runWebServer(store: Store, engine: Engine, config: WebConfig) async throws {
    let router = makeRouter(store: store, engine: engine, password: config.password, username: config.username,
                            loopbackOnly: ["127.0.0.1", "localhost", "::1"].contains(config.bind))
    let app = Application(router: router,
                          configuration: .init(address: .hostname(config.bind, port: config.port), serverName: "YTArr"))
    try await app.runService()
}
