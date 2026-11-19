import Foundation

/// Builds Jellyfin .nfo sidecars from the metadata yt-dlp saves in a video's .info.json.
public enum NFO {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// `upload_date` arrives as YYYYMMDD; NFO wants YYYY-MM-DD.
    static func isoDate(_ yyyymmdd: String) -> String? {
        guard yyyymmdd.count == 8, yyyymmdd.allSatisfy(\.isNumber) else { return nil }
        let d = Array(yyyymmdd)
        return "\(String(d[0..<4]))-\(String(d[4..<6]))-\(String(d[6..<8]))"
    }

    /// Returns nil for `.off`.
    public static func xml(from info: [String: Any], style: NFOStyle) -> String? {
        guard style != .off else { return nil }
        func str(_ k: String) -> String { (info[k] as? String) ?? "" }
        let title = str("title")
        let channel = str("channel").isEmpty ? str("uploader") : str("channel")
        let date = isoDate(str("upload_date"))
        let root = style == .movie ? "movie" : "episodedetails"

        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>", "<\(root)>"]
        lines.append("  <title>\(escape(title))</title>")
        if style == .episode, !channel.isEmpty { lines.append("  <showtitle>\(escape(channel))</showtitle>") }
        lines.append("  <plot>\(escape(str("description")))</plot>")
        if let date {
            lines.append(style == .movie ? "  <premiered>\(date)</premiered>" : "  <aired>\(date)</aired>")
            lines.append("  <year>\(date.prefix(4))</year>")
        }
        if !channel.isEmpty { lines.append("  <studio>\(escape(channel))</studio>") }
        if let secs = (info["duration"] as? NSNumber)?.doubleValue, secs > 0 {
            lines.append("  <runtime>\(max(1, Int((secs / 60).rounded())))</runtime>")
        }
        for tag in (info["tags"] as? [String] ?? []).prefix(25) { lines.append("  <tag>\(escape(tag))</tag>") }
        let id = str("id")
        if !id.isEmpty { lines.append("  <uniqueid type=\"youtube\" default=\"true\">\(escape(id))</uniqueid>") }
        lines.append("</\(root)>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads `<video>.info.json` and writes `<video>.nfo` beside the video. Returns true if an .nfo was written.
    @discardableResult
    public static func writeSidecar(forVideoAt path: String, style: NFOStyle, keepInfoJSON: Bool) -> Bool {
        let video = URL(fileURLWithPath: path)
        let json = video.deletingPathExtension().appendingPathExtension("info.json")
        guard let data = try? Data(contentsOf: json),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let xml = xml(from: info, style: style) else { return false }
        let nfo = video.deletingPathExtension().appendingPathExtension("nfo")
        let wrote = (try? xml.write(to: nfo, atomically: true, encoding: .utf8)) != nil
        // The .info.json was only fetched for the .nfo unless the profile asked to keep it.
        if wrote && !keepInfoJSON { try? FileManager.default.removeItem(at: json) }
        return wrote
    }
}
