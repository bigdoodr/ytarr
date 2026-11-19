import Foundation

public enum ProfileKind: String, Codable, CaseIterable, Sendable { case video, audio }
public enum SourceKind: String, Codable, CaseIterable, Sendable { case channel, playlist, other }

/// Which kind of Jellyfin .nfo sidecar to write next to a downloaded video.
public enum NFOStyle: String, Codable, CaseIterable, Sendable {
    case off
    case movie     // <movie>: for Movies / Home Videos libraries
    case episode   // <episodedetails>: for TV Shows libraries
}

/// What to do the first time a source is checked.
public enum BackfillMode: String, Codable, CaseIterable, Sendable {
    case fromNow   // mark everything currently there as "already have it"; only grab new uploads
    case latest    // grab the newest N, mark the rest as already had
    case all       // grab everything
    case nothing   // list everything into the catalog and mark it as "had"; videos are picked by hand later
}

/// Which saved listing of a source we mean.
public enum CatalogKind: String, Codable, Sendable { case videos, playlists }

/// One video (or, for the playlists listing, one playlist) found by a scan, shown on the Browse page.
public struct CatalogEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String          // video / playlist id
    public var key: String         // yt-dlp extractor key
    public var title: String
    public var duration: String
    public var url: String
    public var downloaded = false
}

/// A media profile: how yt-dlp should fetch and name things (like a Sonarr quality profile).
public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProfileKind
    public var format: String            // yt-dlp -f
    public var mergeFormat: String       // --merge-output-format (video), "" = default
    public var audioFormat: String       // --audio-format (audio), e.g. mp3, m4a
    public var audioQuality: String      // --audio-quality, "0" best
    public var outputTemplate: String    // relative to the destination folder
    public var embedMetadata: Bool
    public var embedThumbnail: Bool
    public var writeInfoJSON: Bool
    public var embedSubs: Bool
    public var sponsorblockRemove: String // e.g. "sponsor,selfpromo"; "" = off
    public var extraArgs: String
    // Optional so state.json files saved before these existed still load (nil = off).
    public var writeThumbnail: Bool?      // save the thumbnail as a .jpg next to the video (Jellyfin artwork)
    public var nfoStyle: NFOStyle?        // write a Jellyfin .nfo (title, description, date, channel)

    public init(id: UUID = UUID(), name: String, kind: ProfileKind, format: String,
                mergeFormat: String = "", audioFormat: String = "", audioQuality: String = "0",
                outputTemplate: String, embedMetadata: Bool = true, embedThumbnail: Bool = false,
                writeInfoJSON: Bool = false, embedSubs: Bool = false,
                sponsorblockRemove: String = "", extraArgs: String = "",
                writeThumbnail: Bool? = nil, nfoStyle: NFOStyle? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.format = format
        self.mergeFormat = mergeFormat; self.audioFormat = audioFormat; self.audioQuality = audioQuality
        self.outputTemplate = outputTemplate; self.embedMetadata = embedMetadata
        self.embedThumbnail = embedThumbnail; self.writeInfoJSON = writeInfoJSON
        self.embedSubs = embedSubs; self.sponsorblockRemove = sponsorblockRemove; self.extraArgs = extraArgs
        self.writeThumbnail = writeThumbnail; self.nfoStyle = nfoStyle
    }

    public static let builtins: [Profile] = [
        Profile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "Video - 1080p MP4", kind: .video,
                format: "bestvideo[ext=mp4][vcodec^=avc1][height<=1080]+bestaudio[ext=m4a]/best[ext=mp4][height<=1080]/best[height<=1080]/best",
                mergeFormat: "mp4",
                outputTemplate: "%(channel,uploader)s/%(upload_date)s - %(title)s [%(id)s].%(ext)s",
                writeInfoJSON: true, writeThumbnail: true, nfoStyle: .movie),
        Profile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                name: "Video - Best quality", kind: .video, format: "bv*+ba/b", mergeFormat: "mkv",
                outputTemplate: "%(channel,uploader)s/%(upload_date)s - %(title)s [%(id)s].%(ext)s",
                writeInfoJSON: true, writeThumbnail: true, nfoStyle: .movie),
        Profile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                name: "Audio - MP3", kind: .audio, format: "bestaudio/best", audioFormat: "mp3",
                outputTemplate: "%(channel,uploader)s/%(title)s [%(id)s].%(ext)s",
                embedThumbnail: true),
        Profile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                name: "Podcast - M4A", kind: .audio, format: "bestaudio[ext=m4a]/bestaudio/best", audioFormat: "m4a",
                outputTemplate: "%(channel,uploader)s/%(upload_date)s - %(title)s.%(ext)s",
                embedThumbnail: true),
    ]
}

/// A monitored channel / playlist / URL (like a Sonarr series).
public struct Source: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var url: String
    public var kind: SourceKind = .channel
    public var profileID: UUID
    public var destination: String = ""      // "" = <libraryRoot>/<profile name>
    public var enabled = true
    public var intervalMinutes = 360
    public var backfillMode: BackfillMode = .fromNow
    public var backfillCount = 10
    public var skipShorts = true
    public var skipLive = true
    public var titleRegex = ""
    public var extraArgs = ""
    public var initialSyncDone = false
    public var lastChecked: Date?
    public var lastStatus = ""
    // Library to rescan after new downloads (ids come from the media server's own library list).
    public var jellyfinLibraryID: String?
    public var absLibraryID: String?

    public var nextCheck: Date {
        (lastChecked ?? .distantPast).addingTimeInterval(Double(intervalMinutes) * 60)
    }

    public static func detectKind(_ url: String) -> SourceKind {
        let u = url.lowercased()
        if u.contains("list=") || u.contains("/playlist") { return .playlist }
        if u.contains("youtube.com/@") || u.contains("/channel/") || u.contains("/c/") || u.contains("/user/") { return .channel }
        return .other
    }
}

public struct DownloadRecord: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var date: Date
    public var sourceName: String
    public var videoID: String
    public var title: String
    public var path: String
}

public struct Settings: Codable, Hashable, Sendable {
    public var libraryRoot: String = "~/Movies/YTArr"
    public var cookiesBrowser: String = ""      // e.g. safari, chrome, firefox
    public var cookiesFile: String = ""
    public var sleepMinSeconds = 5
    public var sleepMaxSeconds = 15
    public var globalExtraArgs: String = ""
    public var ytdlpPathOverride: String = ""
    public var autoUpdate = true
    public var updateIntervalHours = 24
    public var updateChannel: String = "stable"  // stable | nightly | master
    public var lastUpdateCheck: Date?
    public var lastUpdateResult: String = ""
    // Media servers to ask for a library rescan after downloads (optional, so old state files still load).
    public var jellyfinURL: String?
    public var jellyfinAPIKey: String?
    public var absURL: String?
    public var absAPIToken: String?
}
