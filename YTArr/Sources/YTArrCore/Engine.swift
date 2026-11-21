import Foundation

/// The "Sonarr" part: schedules checks, runs yt-dlp one source at a time, keeps yt-dlp fresh.
public actor Engine {
    public struct Status: Codable, Sendable {
        public var running: String?
        public var progress: String
        public var queued: [String]
        public var updating: Bool
        public var ytdlpVersion: String?
        public var ytdlpPath: String?
        public var ffmpegDir: String?
        public var pausedUntil: Date?      // set while waiting out a YouTube rate limit
    }

    /// Something worth telling the person about (new downloads, or a source that started failing).
    public struct Notice: Sendable {
        public enum Kind: Sendable { case downloaded, problem, newVideos }
        public var kind: Kind
        public var title: String
        public var body: String
    }

    public let store: Store
    public let ytdlp: YtDlpManager
    private var notifier: (@Sendable (Notice) -> Void)?

    /// One-off work requested from the Browse page; runs ahead of scheduled checks, one at a time.
    private enum Job: Equatable {
        case scanVideos(UUID)
        case scanPlaylists(UUID)
        case download(UUID, [String])
        case refreshCover(UUID)
    }

    private var queue: [UUID] = []
    private var jobs: [Job] = []
    private var currentID: UUID?
    private var currentName: String?
    private var progress = ""
    private var updating = false
    private var draining = false
    private var cancelled = false
    // YouTube throttling: when yt-dlp reports it we stop the run and wait, instead of failing through every video.
    private var throttled: (reason: String, minutes: Int)?
    private var pausedUntil: Date?
    private var log: [String] = []
    private var loopTask: Task<Void, Never>?
    private let box = ProcessBox()
    private var cachedVersion: String?
    private var cachedPath: String?
    private var versionDirty = true

    public init(store: Store, ytdlp: YtDlpManager = YtDlpManager()) {
        self.store = store
        self.ytdlp = ytdlp
    }

    // MARK: Lifecycle

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    /// The host app sets this to show system notifications. Engine-only use (ytarrd) can leave it unset.
    public func setNotifier(_ f: (@Sendable (Notice) -> Void)?) { notifier = f }

    public func stop() { loopTask?.cancel(); loopTask = nil; box.terminate() }

    // MARK: Public commands

    public func checkNow(_ id: UUID) {
        if !queue.contains(id) && currentID != id { queue.append(id) }
        Task { await self.drain() }
    }

    public func checkAll() async {
        for s in await store.snapshot().sources where s.enabled { if !queue.contains(s.id) && currentID != s.id { queue.append(s.id) } }
        Task { await self.drain() }
    }

    /// Lists a source's videos into its catalog (no downloading).
    public func scanVideos(_ id: UUID) { enqueue(.scanVideos(id)) }
    /// Lists a channel's playlists (no downloading).
    public func scanPlaylists(_ id: UUID) { enqueue(.scanPlaylists(id)) }
    /// Re-fetches the channel picture as cover.jpg (replacing the current one) in the folders this source's videos are in.
    public func refreshCover(_ id: UUID) { enqueue(.refreshCover(id)) }
    /// Downloads the chosen catalog videos now, using the source's profile.
    public func download(_ id: UUID, videoIDs: [String]) { if !videoIDs.isEmpty { enqueue(.download(id, videoIDs)) } }

    private func enqueue(_ job: Job) {
        if !jobs.contains(job) { jobs.append(job) }
        Task { await self.drain() }
    }

    public func cancelCurrent() { cancelled = true; box.terminate() }

    public func updateYtDlpNow() { Task { await self.maybeUpdate(force: true) } }

    public func status() async -> Status {
        let st = await store.snapshot()
        let exe = await ytdlp.executable(st.settings)
        if versionDirty || cachedPath != exe?.path {
            cachedPath = exe?.path
            if let exe { cachedVersion = await ytdlp.version(exe) } else { cachedVersion = nil }
            versionDirty = false
        }
        let names = queue.compactMap { id in st.sources.first { $0.id == id }?.name }
        return Status(running: currentName, progress: progress, queued: names, updating: updating,
                      ytdlpVersion: cachedVersion, ytdlpPath: cachedPath, ffmpegDir: ytdlp.ffmpegDirectory(),
                      pausedUntil: pausedUntil.flatMap { $0 > Date() ? $0 : nil })
    }

    public func recentLog() -> [String] { Array(log.suffix(200).reversed()) }

    // MARK: Scheduling

    private func tick() async {
        await maybeUpdate(force: false)
        let st = await store.snapshot()
        let now = Date()
        if let p = pausedUntil, p > now { return }   // wait out the YouTube limit
        for s in st.sources where s.enabled && s.nextCheck <= now && !queue.contains(s.id) && currentID != s.id {
            queue.append(s.id)
        }
        Task { await self.drain() }
    }

    private func drain() async {
        if draining { return }
        draining = true
        defer { draining = false }
        while !jobs.isEmpty || !queue.isEmpty {
            if let until = pausedUntil, until > Date() {
                appendLog("Paused until \(Self.clock(until)) because YouTube is limiting requests; dropped \(queue.count + jobs.count) queued item(s). Scheduled checks resume on their own.")
                queue.removeAll(); jobs.removeAll()
                break
            }
            if !jobs.isEmpty { await runJob(jobs.removeFirst()) }
            else { await runCheck(queue.removeFirst()) }
        }
    }

    private func maybeUpdate(force: Bool) async {
        let s = await store.snapshot().settings
        let hasExe = await ytdlp.executable(s) != nil
        if !force {
            if currentID != nil || updating { return }
            if hasExe && !s.autoUpdate { return }
            let interval: TimeInterval = hasExe ? Double(max(s.updateIntervalHours, 1)) * 3600 : 600
            if let last = s.lastUpdateCheck, Date().timeIntervalSince(last) < interval { return }
        } else if updating { return }
        updating = true
        defer { updating = false; versionDirty = true }
        let result: String
        do { result = try await ytdlp.update(settings: s) } catch { result = "Update failed: \(error.localizedDescription)" }
        await store.mutateSettings { $0.lastUpdateCheck = Date(); $0.lastUpdateResult = result }
        appendLog("yt-dlp: \(result)")
    }

    /// For paths under /Volumes, returns the volume root if it isn't mounted (so we never write to the boot disk by accident).
    static func missingVolume(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        let root = "/Volumes/" + parts[1]
        return FileManager.default.fileExists(atPath: root) ? nil : root
    }

    // MARK: Running a check

    private func appendLog(_ s: String) {
        log.append("\(Self.stamp.string(from: Date()))  \(s)")
        if log.count > 600 { log.removeFirst(log.count - 600) }
    }
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
    }()

    private func setProgress(_ s: String) { progress = s }

    // MARK: YouTube throttling

    /// yt-dlp output meaning YouTube is limiting us, with how long to back off (it says rate limits last up to an hour).
    static func throttleReason(_ line: String) -> (reason: String, minutes: Int)? {
        let l = line.lowercased()
        if l.contains("rate-limited by youtube") { return ("YouTube is rate-limiting this connection", 60) }
        if l.contains("not a bot") || l.contains("sign in to confirm") { return ("YouTube asked to confirm you're not a bot (try browser cookies in Settings)", 30) }
        return nil
    }

    private static let clockFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
    static func clock(_ d: Date) -> String { clockFormat.string(from: d) }

    /// Stops all work until the back-off ends. Anything that didn't finish is not marked as downloaded.
    private func startPause(_ t: (reason: String, minutes: Int)) {
        if let p = pausedUntil, p > Date() { return }
        let until = Date().addingTimeInterval(Double(t.minutes) * 60)
        pausedUntil = until
        appendLog("Stopped: \(t.reason). Pausing all downloads until \(Self.clock(until)); videos that hadn't finished are not marked as downloaded.")
        notifier?(Notice(kind: .problem, title: "YTArr paused", body: "\(t.reason). Resuming around \(Self.clock(until))."))
    }

    private func finish(_ id: UUID, _ status: String, markInitial: Bool = false, keepSchedule: Bool = false) async {
        appendLog("[\(currentName ?? "?")] \(status)")
        let previous = await store.source(id)?.lastStatus
        let name = currentName ?? "YTArr"
        if status.hasPrefix("Error") || status.hasPrefix("Blocked") {
            // Only on a change, so a source that keeps failing doesn't notify on every check.
            if previous != status { notifier?(Notice(kind: .problem, title: "YTArr: \(name)", body: String(status.prefix(160)))) }
        } else if status.hasPrefix("OK - "), !status.hasPrefix("OK - nothing new") {
            let n = status.dropFirst(5).split(separator: " ").first.flatMap { Int($0) } ?? 0
            notifier?(Notice(kind: .downloaded, title: "YTArr: \(name)", body: n == 1 ? "1 new video downloaded" : "\(max(n, 1)) new videos downloaded"))
        }
        await store.mutateSource(id) { if !keepSchedule { $0.lastChecked = Date() }; $0.lastStatus = status; if markInitial { $0.initialSyncDone = true } }
    }

    private func runCheck(_ id: UUID) async {
        guard let src = await store.source(id) else { return }
        let st = await store.snapshot()
        currentID = id; currentName = src.name; progress = "Starting..."; cancelled = false; throttled = nil
        defer { currentID = nil; currentName = nil; progress = "" }

        guard let profile = st.profiles.first(where: { $0.id == src.profileID }) else {
            await finish(id, "Error: profile no longer exists"); return
        }
        var exeOpt = await ytdlp.executable(st.settings)
        if exeOpt == nil {
            progress = "Installing yt-dlp..."
            if let v = try? await ytdlp.install() { appendLog("Installed yt-dlp \(v)"); versionDirty = true }
            exeOpt = await ytdlp.executable(st.settings)
        }
        guard let exe = exeOpt else { await finish(id, "Error: yt-dlp is not installed (see Settings)"); return }
        let ffmpegDir = ytdlp.ffmpegDirectory()

        // Monitor only: list new uploads into the catalog and notify; never download.
        if src.monitorOnly == true {
            await runMonitor(src, exe: exe, settings: st.settings, ffmpegDir: ffmpegDir)
            return
        }

        let root = AppPaths.expand(st.settings.libraryRoot)
        let dest = URL(fileURLWithPath: src.destination.isEmpty
                       ? root + "/" + AppPaths.sanitize(profile.name) : AppPaths.expand(src.destination))
        if let vol = Self.missingVolume(dest.path) {
            await finish(id, "Error: \(vol) is not mounted - skipped (nothing was written)"); return
        }
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let archive = store.archiveURL(for: id)

        // "Index only": list everything into the catalog and mark it all as had, so nothing downloads
        // until videos are picked on the Browse page (new uploads still come in on later checks).
        if !src.initialSyncDone && src.backfillMode == .nothing {
            progress = "Indexing videos (nothing will be downloaded)..."
            appendLog("[\(src.name)] Indexing videos (nothing will be downloaded)...")
            let r = await listEntries(exe, ArgBuilder.catalogArgs(source: src, settings: st.settings, ffmpegDir: ffmpegDir, playlists: false), noun: "videos")
            if cancelled { await finish(id, "Cancelled"); return }
            if let e = r.error { await finish(id, "Error: could not index source: \(e)"); return }
            await store.saveCatalog(id, .videos, r.entries)
            let lines = r.entries.map { $0.key.lowercased() + " " + $0.id + "\n" }.joined()
            let existing = (try? String(contentsOf: archive, encoding: .utf8)) ?? ""
            try? (existing + lines).write(to: archive, atomically: true, encoding: .utf8)
            await finish(id, "Indexed \(r.entries.count) videos - nothing downloaded", markInitial: true)
            return
        }

        // First check: pre-fill the archive so we only download what the backfill choice asks for.
        if !src.initialSyncDone && src.backfillMode != .all {
            progress = "Indexing existing videos..."
            let startAt: Int? = src.backfillMode == .latest ? max(src.backfillCount, 0) + 1 : nil
            let sink = LineSink()
            let status = (try? await ProcessRunner.run(exe, ArgBuilder.seedArgs(source: src, settings: st.settings, ffmpegDir: ffmpegDir, startAt: startAt), box: box) { sink.add($0) }) ?? -1
            if cancelled { await finish(id, "Cancelled"); return }
            guard status == 0 else {
                await finish(id, "Error: could not index source (exit \(status)): \(sink.lines.last(where: { $0.hasPrefix("ERROR") }) ?? "see log")")
                return
            }
            var entries = ""
            for line in sink.lines {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2, !parts[0].contains(":"), !parts[1].contains(" ") else { continue }
                entries += parts[0].lowercased() + " " + parts[1] + "\n"
            }
            if !entries.isEmpty {
                let existing = (try? String(contentsOf: archive, encoding: .utf8)) ?? ""
                try? (existing + entries).write(to: archive, atomically: true, encoding: .utf8)
            }
            await store.mutateSource(id) { $0.initialSyncDone = true }
        }

        progress = "Checking for new videos..."
        appendLog("[\(src.name)] Checking for new videos...")
        let args = ArgBuilder.downloadArgs(source: src, profile: profile, settings: st.settings,
                                           archive: archive, destination: dest, ffmpegDir: ffmpegDir)
        let sink = LineSink()
        let status: Int32
        do {
            status = try await ProcessRunner.run(exe, args, box: box) { [weak self] line in
                sink.add(line)
                Task { await self?.ingestLive(line) }
            }
        } catch {
            await finish(id, "Error: could not run yt-dlp: \(error.localizedDescription)"); return
        }

        var done = 0, errors: [String] = [], doneIDs: [String] = [], donePaths: [String] = []
        for line in sink.lines {
            if line.hasPrefix("YTARR_DONE\t") {
                let f = line.components(separatedBy: "\t")
                if f.count >= 4 {
                    await store.append(DownloadRecord(date: Date(), sourceName: src.name, videoID: f[1], title: f[2], path: f[3]))
                    done += 1
                    doneIDs.append(f[1]); donePaths.append(f[3])
                    appendLog("  Downloaded: \(f[2])")
                }
            } else if line.hasPrefix("ERROR:") {
                errors.append(line)
            }
        }

        await store.markDownloaded(id, ids: doneIDs)
        writeSidecars(paths: donePaths, profile: profile)
        if !doneIDs.isEmpty { await notifyServers(src, st.settings) }
        if src.saveChannelCover == true, throttled == nil, !donePaths.isEmpty {
            await saveCovers(src, dirs: Self.parentFolders(of: donePaths), exe: exe, ffmpegDir: ffmpegDir, settings: st.settings, force: false)
        }
        let result: String
        if let t = throttled { startPause(t); result = "Paused - \(t.reason); retrying after \(Self.clock(pausedUntil ?? Date()))" }
        else if cancelled { result = "Cancelled" }
        else if done > 0 { result = "OK - \(done) new" + (status == 101 ? " - limit reached, more on the next check" : "") + (errors.isEmpty ? "" : " (\(errors.count) errors)") }
        else if status == 0 || errors.isEmpty { result = "OK - nothing new" }
        else if errors.contains(where: { $0.localizedCaseInsensitiveContains("not a bot") || $0.localizedCaseInsensitiveContains("sign in") }) {
            result = "Blocked by YouTube - set browser cookies in Settings"
        } else { result = "Error: " + String(errors.last!.prefix(200)) }
        await finish(id, result, keepSchedule: throttled != nil)
    }

    // MARK: Monitor only

    /// Looks for uploads we haven't seen and lists them on the Browse page flagged "new". Downloads nothing.
    private func runMonitor(_ src: Source, exe: URL, settings: Settings, ffmpegDir: String?) async {
        let id = src.id
        let baseline = await store.catalog(id, .videos).isEmpty
        progress = baseline ? "Indexing videos (nothing will be downloaded)..." : "Looking for new videos..."
        appendLog("[\(src.name)] \(progress)")
        // After the first listing, a channel's newest uploads are enough (it lists newest first).
        let newest: Int? = (!baseline && src.kind == .channel) ? 100 : nil
        let r = await listEntries(exe, ArgBuilder.catalogArgs(source: src, settings: settings, ffmpegDir: ffmpegDir,
                                                              playlists: false, newest: newest), noun: "videos")
        if cancelled { await finish(id, "Cancelled"); return }
        if let e = r.error { await finish(id, "Error: could not list videos: \(e)"); return }

        if baseline {
            await store.saveCatalog(id, .videos, r.entries)
            if !src.initialSyncDone {
                // Mark everything as had, so switching Monitor only off later doesn't download the whole backlog.
                let archive = store.archiveURL(for: id)
                let lines = r.entries.map { $0.key.lowercased() + " " + $0.id + "\n" }.joined()
                let existing = (try? String(contentsOf: archive, encoding: .utf8)) ?? ""
                try? (existing + lines).write(to: archive, atomically: true, encoding: .utf8)
            }
            await finish(id, "Monitoring - indexed \(r.entries.count) videos", markInitial: true)
            return
        }

        let fresh = await store.mergeNew(id, r.entries)
        guard !fresh.isEmpty else { await finish(id, "Monitor - nothing new"); return }
        let n = fresh.count
        let titles = fresh.prefix(3).map(\.title).joined(separator: "; ")
        notifier?(Notice(kind: .newVideos, title: "YTArr: \(src.name)",
                         body: (n == 1 ? "1 new video: " : "\(n) new videos: ") + String(titles.prefix(140))))
        await finish(id, "Monitor - \(n) new video\(n == 1 ? "" : "s") (not downloaded)")
    }

    // MARK: After downloads

    /// Writes the profile's .nfo sidecar for each finished download.
    private func writeSidecars(paths: [String], profile: Profile) {
        guard let style = profile.nfoStyle, style != .off else { return }
        for p in paths { NFO.writeSidecar(forVideoAt: p, style: style, keepInfoJSON: profile.writeInfoJSON) }
    }

    /// Asks the media servers to rescan the libraries chosen for this source.
    private func notifyServers(_ src: Source, _ settings: Settings) async {
        let tag = "[\(src.name)]"
        if let lib = src.jellyfinLibraryID, !lib.isEmpty {
            if MediaServers.jellyfinConfigured(settings) {
                do { try await MediaServers.refreshJellyfin(settings, libraryID: lib); appendLog("\(tag) Asked Jellyfin to rescan its library") }
                catch { appendLog("\(tag) Jellyfin rescan failed: \(error.localizedDescription)") }
            } else { appendLog("\(tag) A Jellyfin library is set, but Jellyfin isn't configured in Settings") }
        }
        if let lib = src.absLibraryID, !lib.isEmpty {
            if MediaServers.absConfigured(settings) {
                do { try await MediaServers.scanAudiobookshelf(settings, libraryID: lib); appendLog("\(tag) Asked Audiobookshelf to scan its library") }
                catch { appendLog("\(tag) Audiobookshelf scan failed: \(error.localizedDescription)") }
            } else { appendLog("\(tag) An Audiobookshelf library is set, but Audiobookshelf isn't configured in Settings") }
        }
    }

    // MARK: Channel cover

    static func parentFolders(of paths: [String]) -> [URL] {
        var out: [URL] = []
        for p in paths { let d = URL(fileURLWithPath: p).deletingLastPathComponent(); if !out.contains(d) { out.append(d) } }
        return out
    }

    /// Saves the channel picture as cover.jpg in each folder. Without `force`, folders that already have one are left alone.
    private func saveCovers(_ src: Source, dirs: [URL], exe: URL, ffmpegDir: String?, settings: Settings, force: Bool) async {
        let tag = "[\(src.name)]"
        let todo = dirs.filter { force || !FileManager.default.fileExists(atPath: $0.appendingPathComponent("cover.jpg").path) }
        guard !todo.isEmpty else { return }
        guard src.kind == .channel else { appendLog("\(tag) The channel cover needs a channel source (a youtube.com/@name URL)"); return }
        progress = "Fetching channel cover..."
        guard let url = await ChannelCover.avatarURL(exe: exe, channelURL: ArgBuilder.channelBase(src), settings: settings, ffmpegDir: ffmpegDir) else {
            appendLog("\(tag) Couldn't find the channel's picture"); return
        }
        for d in todo {
            if await ChannelCover.save(avatarURL: url, to: d, ffmpegDir: ffmpegDir) { appendLog("\(tag) Saved channel cover: \(d.lastPathComponent)/cover.jpg") }
            else { appendLog("\(tag) Couldn't save the channel cover in \(d.path)") }
        }
    }

    // MARK: Browse-page jobs

    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    /// Runs a `catalogArgs` listing and parses the `YTARR_ENT` lines. `error` is set when nothing usable came back.
    private func listEntries(_ exe: URL, _ args: [String], noun: String) async -> (entries: [CatalogEntry], error: String?) {
        let sink = LineSink(), tally = Tally()
        let status: Int32
        do {
            status = try await ProcessRunner.run(exe, args, box: box) { [weak self] line in
                sink.add(line)
                if line.hasPrefix("YTARR_ENT\t") {
                    let n = tally.bump()
                    if n % 25 == 0 { Task { await self?.setProgress("Scanning: \(n) \(noun) found...") } }
                }
            }
        } catch { return ([], "could not run yt-dlp: \(error.localizedDescription)") }
        if cancelled { return ([], "cancelled") }

        var entries: [CatalogEntry] = [], seen = Set<String>()
        for line in sink.lines {
            guard line.hasPrefix("YTARR_ENT\t") else {
                if !line.isEmpty { appendLog("  \(line)") }
                continue
            }
            let f = line.components(separatedBy: "\t")
            guard f.count >= 6, seen.insert(f[2]).inserted else { continue }
            var url = f[5]
            if (url == "NA" || url.isEmpty) && f[1].hasPrefix("Youtube") { url = "https://www.youtube.com/watch?v=\(f[2])" }
            entries.append(CatalogEntry(id: f[2], key: f[1], title: f[3] == "NA" ? f[2] : f[3],
                                        duration: f[4] == "NA" ? "" : f[4], url: url))
        }
        if entries.isEmpty {
            return ([], sink.lines.last(where: { $0.hasPrefix("ERROR") }) ?? "nothing found (exit \(status))")
        }
        return (entries, nil)
    }

    private func runJob(_ job: Job) async {
        let sid: UUID
        switch job {
        case .scanVideos(let i), .scanPlaylists(let i), .download(let i, _), .refreshCover(let i): sid = i
        }
        guard let src = await store.source(sid) else { return }
        let st = await store.snapshot()
        currentID = sid; currentName = src.name; progress = "Starting..."; cancelled = false; throttled = nil
        defer { currentID = nil; currentName = nil; progress = "" }
        let tag = "[\(src.name)]"

        var exeOpt = await ytdlp.executable(st.settings)
        if exeOpt == nil {
            progress = "Installing yt-dlp..."
            if let v = try? await ytdlp.install() { appendLog("Installed yt-dlp \(v)"); versionDirty = true }
            exeOpt = await ytdlp.executable(st.settings)
        }
        guard let exe = exeOpt else { appendLog("\(tag) Error: yt-dlp is not installed (see Settings)"); return }
        let ffmpegDir = ytdlp.ffmpegDirectory()

        switch job {
        case .scanVideos, .scanPlaylists:
            let playlists: Bool
            if case .scanPlaylists = job { playlists = true } else { playlists = false }
            let noun = playlists ? "playlists" : "videos"
            progress = "Scanning \(noun)..."
            appendLog("\(tag) Scanning \(noun) (nothing will be downloaded)...")
            let r = await listEntries(exe, ArgBuilder.catalogArgs(source: src, settings: st.settings, ffmpegDir: ffmpegDir, playlists: playlists), noun: noun)
            if let e = r.error { appendLog("\(tag) Scan \(e == "cancelled" ? "cancelled" : "failed: \(e)")"); return }
            await store.saveCatalog(sid, playlists ? .playlists : .videos, r.entries)
            appendLog("\(tag) Found \(r.entries.count) \(noun)")

        case .refreshCover:
            // Where this source's videos actually are (newest downloads first), else its download folder.
            var dirs: [URL] = []
            for r in st.history.filter({ $0.sourceName == src.name }).prefix(50) {
                let d = URL(fileURLWithPath: r.path).deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: d.path), !dirs.contains(d) { dirs.append(d) }
            }
            if dirs.isEmpty, let profile = st.profiles.first(where: { $0.id == src.profileID }) {
                let root = AppPaths.expand(st.settings.libraryRoot)
                dirs = [URL(fileURLWithPath: src.destination.isEmpty ? root + "/" + AppPaths.sanitize(profile.name) : AppPaths.expand(src.destination))]
            }
            await saveCovers(src, dirs: dirs, exe: exe, ffmpegDir: ffmpegDir, settings: st.settings, force: true)

        case .download(_, let ids):
            let wanted = Set(ids)
            let picked = await store.catalog(sid, .videos).filter { wanted.contains($0.id) }
            guard !picked.isEmpty, let profile = st.profiles.first(where: { $0.id == src.profileID }) else {
                appendLog("\(tag) Error: nothing to download (profile missing or videos not in the catalog)"); return
            }
            let root = AppPaths.expand(st.settings.libraryRoot)
            let dest = URL(fileURLWithPath: src.destination.isEmpty
                           ? root + "/" + AppPaths.sanitize(profile.name) : AppPaths.expand(src.destination))
            if let vol = Self.missingVolume(dest.path) { appendLog("\(tag) Error: \(vol) is not mounted - nothing downloaded"); return }
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            progress = "Downloading \(picked.count) selected video(s)..."
            appendLog("\(tag) Downloading \(picked.count) selected video(s)...")
            let args = ArgBuilder.downloadArgs(source: src, profile: profile, settings: st.settings, archive: nil,
                                               destination: dest, ffmpegDir: ffmpegDir, urls: picked.map(\.url))
            let sink = LineSink()
            do {
                try await ProcessRunner.run(exe, args, box: box) { [weak self] line in
                    sink.add(line)
                    Task { await self?.ingestLive(line) }
                }
            } catch { appendLog("\(tag) Error: could not run yt-dlp: \(error.localizedDescription)"); return }

            var doneIDs: [String] = [], donePaths: [String] = []
            for line in sink.lines where line.hasPrefix("YTARR_DONE\t") {
                let f = line.components(separatedBy: "\t")
                guard f.count >= 4 else { continue }
                await store.append(DownloadRecord(date: Date(), sourceName: src.name, videoID: f[1], title: f[2], path: f[3]))
                doneIDs.append(f[1]); donePaths.append(f[3])
                appendLog("  Downloaded: \(f[2])")
            }
            await store.markDownloaded(sid, ids: doneIDs)
            writeSidecars(paths: donePaths, profile: profile)
            if !doneIDs.isEmpty { await notifyServers(src, st.settings) }
            if src.saveChannelCover == true, throttled == nil, !donePaths.isEmpty {
                await saveCovers(src, dirs: Self.parentFolders(of: donePaths), exe: exe, ffmpegDir: ffmpegDir, settings: st.settings, force: false)
            }
            if let t = throttled { startPause(t) }
            appendLog("\(tag) \(cancelled ? "Cancelled" : throttled != nil ? "Stopped (YouTube throttling)" : "Finished"): \(doneIDs.count) of \(picked.count) downloaded")
            if !doneIDs.isEmpty {
                notifier?(Notice(kind: .downloaded, title: "YTArr: \(src.name)", body: doneIDs.count == 1 ? "1 video downloaded" : "\(doneIDs.count) videos downloaded"))
            }
        }
    }

    /// Live progress line from yt-dlp's progress template.
    private func ingestLive(_ line: String) {
        // Stop at the first sign of throttling; carrying on only makes YouTube's block last longer.
        if throttled == nil, let t = Self.throttleReason(line) { throttled = t; box.terminate() }
        // Stream yt-dlp's own output into the log as it happens (progress/done markers are handled separately).
        if !line.isEmpty && !line.hasPrefix("YTARR_PROG") && !line.hasPrefix("YTARR_DONE") { appendLog("  \(line)") }
        if line.hasPrefix("YTARR_PROG\t") {
            let f = line.components(separatedBy: "\t")
            if f.count >= 4 {
                progress = "Downloading \(f[1].trimmingCharacters(in: .whitespaces)) at \(f[2].trimmingCharacters(in: .whitespaces)), ETA \(f[3].trimmingCharacters(in: .whitespaces))"
            }
        } else if line.hasPrefix("[download] Destination:") || line.hasPrefix("[Merger]") || line.hasPrefix("[ExtractAudio]")
                    || line.hasPrefix("[download] Downloading item") || line.hasPrefix("[youtube]") {
            progress = String(line.prefix(160))
        }
    }
}
