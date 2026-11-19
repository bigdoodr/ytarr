import Foundation

/// A library on a media server (Jellyfin "virtual folder" or Audiobookshelf library).
public struct MediaLibrary: Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: String      // e.g. movies, tvshows, book, podcast; may be empty
}

/// Talks to Jellyfin and Audiobookshelf: lists their libraries (so nothing is hardcoded) and asks them to rescan.
public enum MediaServers {
    public enum Failure: LocalizedError {
        case notConfigured, badURL, http(Int), unexpected
        public var errorDescription: String? {
            switch self {
            case .notConfigured: return "not configured"
            case .badURL: return "the server address isn't a valid URL"
            case .http(let c) where c == 401 || c == 403: return "the server rejected the API key (HTTP \(c))"
            case .http(let c): return "the server answered HTTP \(c)"
            case .unexpected: return "unexpected response from the server"
            }
        }
    }

    public static func jellyfinConfigured(_ s: Settings) -> Bool { !blank(s.jellyfinURL) && !blank(s.jellyfinAPIKey) }
    public static func absConfigured(_ s: Settings) -> Bool { !blank(s.absURL) && !blank(s.absAPIToken) }
    private static func blank(_ s: String?) -> Bool { (s ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: Jellyfin

    public static func jellyfinLibraries(_ s: Settings) async throws -> [MediaLibrary] {
        let data = try await send(base: s.jellyfinURL, path: "/Library/VirtualFolders", method: "GET", headers: jellyfinHeaders(s))
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Failure.unexpected }
        return list.compactMap { d in
            guard let id = d["ItemId"] as? String, let name = d["Name"] as? String else { return nil }
            return MediaLibrary(id: id, name: name, kind: d["CollectionType"] as? String ?? "")
        }
    }

    /// Rescans one Jellyfin library (new files, plus any new .nfo / artwork next to them).
    public static func refreshJellyfin(_ s: Settings, libraryID: String) async throws {
        let id = libraryID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? libraryID
        _ = try await send(base: s.jellyfinURL,
                           path: "/Items/\(id)/Refresh?Recursive=true&ImageRefreshMode=Default&MetadataRefreshMode=Default",
                           method: "POST", headers: jellyfinHeaders(s))
    }

    private static func jellyfinHeaders(_ s: Settings) -> [String: String] {
        let key = (s.jellyfinAPIKey ?? "").trimmingCharacters(in: .whitespaces)
        return ["X-Emby-Token": key, "Authorization": "MediaBrowser Token=\"\(key)\""]
    }

    // MARK: Audiobookshelf

    public static func absLibraries(_ s: Settings) async throws -> [MediaLibrary] {
        let data = try await send(base: s.absURL, path: "/api/libraries", method: "GET", headers: absHeaders(s))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["libraries"] as? [[String: Any]] else { throw Failure.unexpected }
        return list.compactMap { d in
            guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
            return MediaLibrary(id: id, name: name, kind: d["mediaType"] as? String ?? "")
        }
    }

    /// Scans one Audiobookshelf library for new files (the API token's user must be an admin).
    public static func scanAudiobookshelf(_ s: Settings, libraryID: String) async throws {
        let id = libraryID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? libraryID
        _ = try await send(base: s.absURL, path: "/api/libraries/\(id)/scan", method: "POST", headers: absHeaders(s))
    }

    private static func absHeaders(_ s: Settings) -> [String: String] {
        ["Authorization": "Bearer \((s.absAPIToken ?? "").trimmingCharacters(in: .whitespaces))"]
    }

    // MARK: Plumbing

    private static func send(base: String?, path: String, method: String, headers: [String: String]) async throws -> Data {
        var b = (base ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { throw Failure.notConfigured }
        if !b.contains("://") { b = "http://" + b }
        while b.hasSuffix("/") { b.removeLast() }
        guard let url = URL(string: b + path) else { throw Failure.badURL }
        var req = URLRequest(url: url, timeoutInterval: 8)   // short: the web UI waits on this when drawing forms
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Failure.unexpected }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
        return data
    }
}
