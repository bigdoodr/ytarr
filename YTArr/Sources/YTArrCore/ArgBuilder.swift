import Foundation

public enum ArgBuilder {
    /// Shell-like split that respects single/double quotes (no escapes, no expansion).
    public static func tokenize(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character? = nil, has = false
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; has = true
            } else if ch == " " || ch == "\t" || ch == "\n" {
                if has || !cur.isEmpty { out.append(cur); cur = ""; has = false }
            } else { cur.append(ch) }
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Options that can run commands or load code. Extra args may not use them (abbreviations included).
    static let forbiddenOptions = ["--exec", "--exec-before-download", "--config-locations", "--config-location",
                                   "--plugin-dirs", "--netrc-cmd", "--use-postprocessor"]

    /// `tokenize`, minus any forbidden option (and its separate value).
    public static func safeTokens(_ s: String) -> [String] {
        let toks = tokenize(s)
        var out: [String] = [], skipNext = false
        for t in toks {
            if skipNext { skipNext = false; if !t.hasPrefix("-") { continue } }
            if t.hasPrefix("--") {
                let name = String(t.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
                if name.count >= 4, forbiddenOptions.contains(where: { $0.hasPrefix(name) }) {
                    if !t.contains("=") { skipNext = true }
                    continue
                }
            }
            out.append(t)
        }
        return out
    }

    /// Channel URLs without a tab get "/videos" so yt-dlp doesn't return the tab list.
    public static func normalizedURL(_ source: Source) -> String {
        var u = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.kind == .channel else { return u }
        while u.hasSuffix("/") { u.removeLast() }
        let tabs = ["/videos", "/shorts", "/streams", "/live", "/playlists", "/featured", "/releases", "/podcasts"]
        if !tabs.contains(where: { u.lowercased().hasSuffix($0) }) { u += "/videos" }
        return u
    }

    /// Options shared by every yt-dlp call (auth, politeness, global extras).
    public static func commonArgs(settings s: Settings, ffmpegDir: String?) -> [String] {
        var a: [String] = ["--no-colors"]
        if !s.cookiesFile.isEmpty { a += ["--cookies", AppPaths.expand(s.cookiesFile)] }
        else if !s.cookiesBrowser.isEmpty { a += ["--cookies-from-browser", s.cookiesBrowser] }
        if let d = ffmpegDir { a += ["--ffmpeg-location", d] }
        a += safeTokens(s.globalExtraArgs)
        return a
    }

    /// With `urls`, downloads exactly those videos: no archive, no early stop, no filters (they were picked by hand).
    public static func downloadArgs(source: Source, profile: Profile, settings s: Settings,
                                    archive: URL?, destination: URL, ffmpegDir: String?, urls: [String]? = nil) -> [String] {
        var a = commonArgs(settings: s, ffmpegDir: ffmpegDir)
        a += ["--ignore-errors", "--newline", "--no-overwrites",
              "--sleep-requests", "1",
              "--sleep-interval", String(s.sleepMinSeconds),
              "--max-sleep-interval", String(max(s.sleepMaxSeconds, s.sleepMinSeconds))]
        a += ["-P", destination.path, "-o", profile.outputTemplate]
        a += ["-f", profile.format]
        switch profile.kind {
        case .video:
            if !profile.mergeFormat.isEmpty { a += ["--merge-output-format", profile.mergeFormat] }
        case .audio:
            a += ["-x"]
            if !profile.audioFormat.isEmpty { a += ["--audio-format", profile.audioFormat] }
            if !profile.audioQuality.isEmpty { a += ["--audio-quality", profile.audioQuality] }
        }
        if profile.embedMetadata {
            a += ["--embed-metadata"]
            // Album / Artist tags from a yt-dlp template (a colon would split the option, so those are ignored).
            for (tag, template) in [("album", profile.albumTag), ("artist", profile.artistTag)] {
                if let t = template?.trimmingCharacters(in: .whitespaces), !t.isEmpty, !t.contains(":") {
                    a += ["--parse-metadata", "\(t):%(meta_\(tag))s"]
                }
            }
        }
        if profile.embedThumbnail { a += ["--embed-thumbnail"] }
        // The .nfo is built from the .info.json, so fetch it even if the profile doesn't keep it.
        if profile.writeInfoJSON || (profile.nfoStyle ?? .off) != .off { a += ["--write-info-json"] }
        if profile.writeThumbnail == true { a += ["--write-thumbnail", "--convert-thumbnails", "jpg"] }
        if profile.embedSubs { a += ["--write-subs", "--sub-langs", "en", "--embed-subs"] }
        if !profile.sponsorblockRemove.isEmpty { a += ["--sponsorblock-remove", profile.sponsorblockRemove] }

        // A per-check cap means videos can be left over for the next check, so the archive alone must decide
        // what's still wanted: stopping at the first already-downloaded video would skip the leftovers for good.
        let cap = urls == nil ? max(source.maxPerCheck ?? 0, 0) : 0
        if let archive {
            a += ["--download-archive", archive.path]
            // Newest-first channels: stop at the first video we already have. Playlists can gain items
            // anywhere, so they rely on the archive alone.
            if source.kind == .channel && cap == 0 { a += ["--break-on-existing", "--lazy-playlist"] }
        }
        if cap > 0 { a += ["--max-downloads", String(cap)] }     // yt-dlp exits with status 101 when it stops at the cap

        var filters: [String] = []
        if urls == nil {
            if source.skipShorts { filters.append("original_url!*=/shorts/") }
            if source.skipLive { filters.append("!is_live") }
            let rx = source.titleRegex.trimmingCharacters(in: .whitespaces)
            if !rx.isEmpty { filters.append("title~=(?i)\(rx)") }
        }
        if !filters.isEmpty { a += ["--match-filters", filters.joined(separator: " & ")] }

        // Machine-readable progress + completion lines for the engine to parse.
        a += ["--progress-template", "download:YTARR_PROG\t%(progress._percent_str)s\t%(progress._speed_str)s\t%(progress._eta_str)s",
              "--print", "after_move:YTARR_DONE\t%(id)s\t%(title)s\t%(filepath)s"]

        a += safeTokens(profile.extraArgs)
        a += safeTokens(source.extraArgs)
        if let urls { a += urls } else { a.append(normalizedURL(source)) }
        return a
    }

    /// Channel URL with any tab suffix (/videos, /playlists, ...) removed.
    static func channelBase(_ source: Source) -> String {
        var u = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        let tabs = ["/videos", "/shorts", "/streams", "/live", "/playlists", "/featured", "/releases", "/podcasts"]
        if let t = tabs.first(where: { u.lowercased().hasSuffix($0) }) { u.removeLast(t.count) }
        return u
    }

    /// Lists every entry of the source (or of the channel's Playlists tab) without downloading anything.
    /// Output lines: `YTARR_ENT <TAB> extractor <TAB> id <TAB> title <TAB> duration <TAB> url`.
    public static func catalogArgs(source: Source, settings s: Settings, ffmpegDir: String?, playlists: Bool, newest: Int? = nil) -> [String] {
        var a = commonArgs(settings: s, ffmpegDir: ffmpegDir)
        a += ["--flat-playlist", "--no-warnings", "--ignore-errors",
              "--print", "YTARR_ENT\t%(extractor_key)s\t%(id)s\t%(title)s\t%(duration_string)s\t%(url)s"]
        if let n = newest, n > 0 { a += ["--playlist-end", String(n)] }
        a += safeTokens(source.extraArgs)
        a.append(playlists ? channelBase(source) + "/playlists" : normalizedURL(source))
        return a
    }

    /// Lists entry ids ("extractor id") without downloading, to pre-fill the archive.
    public static func seedArgs(source: Source, settings s: Settings, ffmpegDir: String?, startAt: Int?) -> [String] {
        var a = commonArgs(settings: s, ffmpegDir: ffmpegDir)
        a += ["--flat-playlist", "--no-warnings", "--print", "%(extractor_key)s %(id)s"]
        if let n = startAt { a += ["--playlist-start", String(n)] }
        a += safeTokens(source.extraArgs)
        a.append(normalizedURL(source))
        return a
    }
}
