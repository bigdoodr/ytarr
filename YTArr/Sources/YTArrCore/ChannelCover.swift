import Foundation

/// Saves a channel's picture as `cover.jpg` (what Audiobookshelf and Jellyfin show for a show's folder).
public enum ChannelCover {
    private static func area(_ t: [String: Any]) -> Int { ((t["width"] as? Int) ?? 0) * ((t["height"] as? Int) ?? 0) }

    /// Picks the avatar from yt-dlp's channel `thumbnails`: avatar_uncropped, then anything called avatar,
    /// then the largest non-banner profile picture.
    static func pickAvatar(_ thumbs: [[String: Any]]) -> String? {
        let items = thumbs.compactMap { t -> (id: String, url: String, raw: [String: Any])? in
            guard let u = t["url"] as? String, !u.isEmpty else { return nil }
            return ((t["id"] as? String) ?? "", u, t)
        }
        if let t = items.first(where: { $0.id == "avatar_uncropped" }) { return t.url }
        if let t = items.first(where: { $0.id.lowercased().contains("avatar") }) { return t.url }
        let pics = items.filter {
            !$0.id.lowercased().contains("banner") && ($0.url.contains("yt3.googleusercontent.com") || $0.url.contains("yt3.ggpht.com"))
        }
        return pics.max { area($0.raw) < area($1.raw) }?.url
    }

    /// Googleusercontent URLs end in `=s<size>...`; ask for a large square.
    static func hiRes(_ url: String) -> String {
        url.replacingOccurrences(of: "=s\\d+(-[^=/]*)?$", with: "=s1000", options: .regularExpression)
    }

    static func isJPEG(_ d: Data) -> Bool { d.count > 3 && d[d.startIndex] == 0xFF && d[d.startIndex + 1] == 0xD8 }

    /// Asks yt-dlp for the channel's picture URL. Nothing is downloaded.
    static func avatarURL(exe: URL, channelURL: String, settings: Settings, ffmpegDir: String?) async -> String? {
        var base = channelURL
        while base.hasSuffix("/") { base.removeLast() }
        for url in [base, base + "/videos"] {
            var args = ArgBuilder.commonArgs(settings: settings, ffmpegDir: ffmpegDir)
            args += ["-J", "--flat-playlist", "--playlist-items", "1", "--no-warnings", url]
            guard let r = try? await ProcessRunner.capture(exe, args), r.status == 0,
                  let line = r.lines.first(where: { $0.hasPrefix("{") }),
                  let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let found = pickAvatar(json["thumbnails"] as? [[String: Any]] ?? []) else { continue }
            return found
        }
        return nil
    }

    /// Downloads the picture and writes `<dir>/cover.jpg` (replacing any existing one).
    static func save(avatarURL: String, to dir: URL, ffmpegDir: String?) async -> Bool {
        var data: Data?
        var tried: [String] = []
        for candidate in [hiRes(avatarURL), avatarURL] where !tried.contains(candidate) {
            tried.append(candidate)
            guard let u = URL(string: candidate),
                  let (d, resp) = try? await URLSession.shared.data(for: URLRequest(url: u, timeoutInterval: 20)),
                  (resp as? HTTPURLResponse)?.statusCode == 200, !d.isEmpty else { continue }
            data = d; break
        }
        guard let data else { return false }
        let dest = dir.appendingPathComponent("cover.jpg")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if isJPEG(data) { return (try? data.write(to: dest, options: .atomic)) != nil }

        // PNG / WebP and friends: convert with ffmpeg.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ytarr-cover-\(UUID().uuidString)")
        let raw = tmp.appendingPathExtension("raw"), out = tmp.appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: raw); try? FileManager.default.removeItem(at: out) }
        guard (try? data.write(to: raw)) != nil else { return false }
        let ff = ffmpegDir.map { URL(fileURLWithPath: $0).appendingPathComponent("ffmpeg") }
        let direct = ff.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
        let exe = direct ?? URL(fileURLWithPath: "/usr/bin/env")      // env finds ffmpeg on the Homebrew PATH ProcessRunner adds
        let args = (direct == nil ? ["ffmpeg"] : []) + ["-y", "-loglevel", "error", "-i", raw.path, "-frames:v", "1", "-q:v", "2", out.path]
        guard let r = try? await ProcessRunner.capture(exe, args), r.status == 0,
              FileManager.default.fileExists(atPath: out.path) else { return false }
        try? FileManager.default.removeItem(at: dest)
        return (try? FileManager.default.copyItem(at: out, to: dest)) != nil
    }
}
