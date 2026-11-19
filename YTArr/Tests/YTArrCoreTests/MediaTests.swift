import Foundation
import Testing
@testable import YTArrCore

struct MediaTests {
    @Test func nfoMovieEscapesAndFormats() throws {
        let info: [String: Any] = [
            "id": "abc123", "title": "Tom & Jerry <HD>", "description": "Line 1\nLine \"2\"",
            "channel": "Some Channel", "upload_date": "20240131", "duration": 125.0, "tags": ["a", "b"],
        ]
        let xml = try #require(NFO.xml(from: info, style: .movie))
        #expect(xml.contains("<movie>"))
        #expect(xml.contains("<title>Tom &amp; Jerry &lt;HD&gt;</title>"))
        #expect(xml.contains("<plot>Line 1\nLine &quot;2&quot;</plot>"))
        #expect(xml.contains("<premiered>2024-01-31</premiered>"))
        #expect(xml.contains("<year>2024</year>"))
        #expect(xml.contains("<runtime>2</runtime>"))
        #expect(xml.contains("<uniqueid type=\"youtube\" default=\"true\">abc123</uniqueid>"))
    }

    @Test func nfoEpisodeUsesAiredAndShowTitle() throws {
        let xml = try #require(NFO.xml(from: ["title": "T", "channel": "C", "upload_date": "20240131"], style: .episode))
        #expect(xml.contains("<episodedetails>"))
        #expect(xml.contains("<aired>2024-01-31</aired>"))
        #expect(xml.contains("<showtitle>C</showtitle>"))
    }

    @Test func nfoOffWritesNothing() {
        #expect(NFO.xml(from: ["title": "T"], style: .off) == nil)
    }

    @Test func sidecarIsWrittenAndInfoJSONRemovedUnlessKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ytarr-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("My Video [abc].mp4")
        let json = dir.appendingPathComponent("My Video [abc].info.json")
        try Data("{\"id\":\"abc\",\"title\":\"My Video\"}".utf8).write(to: json)

        #expect(NFO.writeSidecar(forVideoAt: video.path, style: .movie, keepInfoJSON: false))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("My Video [abc].nfo").path))
        #expect(!FileManager.default.fileExists(atPath: json.path))
    }

    @Test func profileArgsAddInfoJSONThumbnailAndNFOSupport() {
        var p = Profile(name: "p", kind: .video, format: "b", outputTemplate: "%(title)s.%(ext)s")
        let s = Source(name: "n", url: "https://www.youtube.com/@x", profileID: p.id)
        func args() -> [String] {
            ArgBuilder.downloadArgs(source: s, profile: p, settings: Settings(), archive: nil,
                                    destination: URL(fileURLWithPath: "/tmp/d"), ffmpegDir: nil)
        }
        #expect(!args().contains("--write-info-json"))
        #expect(!args().contains("--write-thumbnail"))
        p.nfoStyle = .movie            // the .nfo is built from the info.json, so it must be fetched
        p.writeThumbnail = true
        #expect(args().contains("--write-info-json"))
        #expect(args().contains("--write-thumbnail"))
        #expect(args()[args().firstIndex(of: "--convert-thumbnails")! + 1] == "jpg")
    }

    @Test func pickedVideosIgnoreArchiveAndFilters() {
        let p = Profile(name: "p", kind: .video, format: "b", outputTemplate: "%(title)s.%(ext)s")
        let s = Source(name: "n", url: "https://www.youtube.com/@x", profileID: p.id)
        let a = ArgBuilder.downloadArgs(source: s, profile: p, settings: Settings(), archive: nil,
                                        destination: URL(fileURLWithPath: "/tmp/d"), ffmpegDir: nil,
                                        urls: ["https://www.youtube.com/watch?v=1"])
        #expect(!a.contains("--download-archive"))
        #expect(!a.contains("--break-on-existing"))
        #expect(!a.contains("--match-filters"))
        #expect(a.last == "https://www.youtube.com/watch?v=1")
    }

    /// state.json written before the media-server fields existed must still load (not be replaced as "corrupt").
    @Test func oldStateWithoutNewFieldsStillDecodes() throws {
        let enc = JSONEncoder()
        let full = try JSONSerialization.jsonObject(with: enc.encode(Store.State())) as! [String: Any]
        var old = full
        var settings = old["settings"] as! [String: Any]
        for k in ["jellyfinURL", "jellyfinAPIKey", "absURL", "absAPIToken"] { settings.removeValue(forKey: k) }
        old["settings"] = settings
        old["profiles"] = (old["profiles"] as! [[String: Any]]).map { p -> [String: Any] in
            var p = p; p.removeValue(forKey: "nfoStyle"); p.removeValue(forKey: "writeThumbnail"); return p
        }
        let data = try JSONSerialization.data(withJSONObject: old)
        let state = try JSONDecoder().decode(Store.State.self, from: data)
        #expect(state.settings.jellyfinURL == nil)
        #expect(state.profiles.count == Profile.builtins.count)
    }

    @Test func mediaServersNeedAddressAndKey() {
        var s = Settings()
        #expect(!MediaServers.jellyfinConfigured(s))
        s.jellyfinURL = "http://host:8096"
        #expect(!MediaServers.jellyfinConfigured(s))
        s.jellyfinAPIKey = "key"
        #expect(MediaServers.jellyfinConfigured(s))
    }

    @Test func youtubeThrottlingIsRecognised() {
        let limited = Engine.throttleReason("ERROR: [youtube] Rz0fXo-aIi0: Video unavailable. This content isn't available, try again later. The current session has been rate-limited by YouTube for up to an hour.")
        #expect(limited?.minutes == 60)
        #expect(Engine.throttleReason("ERROR: [youtube] abc: Sign in to confirm you're not a bot")?.minutes == 30)
        // Ordinary failures must not pause everything.
        #expect(Engine.throttleReason("ERROR: [youtube] abc: Video unavailable. This video is private") == nil)
        #expect(Engine.throttleReason("[download] Destination: x.mp4") == nil)
    }
}

struct SignInAndMetadataTests {
    @Test func secureEqualComparesWholeStrings() {
        #expect(AuthState.secureEqual("correct horse", "correct horse"))
        #expect(!AuthState.secureEqual("correct horse", "correct horsf"))
        #expect(!AuthState.secureEqual("abc", "abcd"))
        #expect(!AuthState.secureEqual("", "x"))
        #expect(AuthState.secureEqual("", ""))
    }

    @Test func sessionsStartEndAndExpire() {
        let a = AuthState()
        let t = a.startSession(lifetime: 60)
        #expect(t.count == 64)
        #expect(a.isValid(t))
        #expect(!a.isValid("not-a-token"))
        a.endSession(t)
        #expect(!a.isValid(t))
        #expect(!a.isValid(a.startSession(lifetime: -1)))      // already expired
        #expect(AuthState.newToken() != AuthState.newToken())
    }

    @Test func fiveFailuresLockSignInTemporarily() {
        let a = AuthState()
        for _ in 0..<4 { a.recordFailure() }
        #expect(a.lockoutRemaining() == nil)
        a.recordFailure()
        let wait = a.lockoutRemaining()
        #expect(wait != nil && wait! >= 1 && wait! <= 60)
    }

    @Test func nextPathStaysOnThisSite() {
        #expect(safeNextPath("/sources/abc/browse") == "/sources/abc/browse")
        #expect(safeNextPath("https://evil.example/") == "/")
        #expect(safeNextPath("//evil.example/") == "/")
        #expect(safeNextPath("/\\evil.example") == "/")
        #expect(safeNextPath("/login") == "/")
        #expect(safeNextPath("") == "/")
    }

    @Test func newSourcesDefaultToIndexOnly() {
        #expect(Source(name: "n", url: "u", profileID: UUID()).backfillMode == .nothing)
    }

    @Test func perCheckCapSwitchesToArchiveOnlyAndLimitsDownloads() {
        let p = Profile(name: "p", kind: .video, format: "b", outputTemplate: "%(title)s.%(ext)s")
        var s = Source(name: "n", url: "https://www.youtube.com/@x", profileID: p.id)
        func args() -> [String] {
            ArgBuilder.downloadArgs(source: s, profile: p, settings: Settings(), archive: URL(fileURLWithPath: "/tmp/a.txt"),
                                    destination: URL(fileURLWithPath: "/tmp/d"), ffmpegDir: nil)
        }
        #expect(args().contains("--break-on-existing"))
        #expect(!args().contains("--max-downloads"))
        s.maxPerCheck = 10
        // Stopping at the first downloaded video would strand whatever the cap left over.
        #expect(!args().contains("--break-on-existing"))
        #expect(args()[args().firstIndex(of: "--max-downloads")! + 1] == "10")
        s.maxPerCheck = 0
        #expect(args().contains("--break-on-existing"))
    }

    @Test func albumAndArtistTagsBecomeParseMetadata() {
        var p = Profile(name: "p", kind: .audio, format: "b", outputTemplate: "%(title)s.%(ext)s",
                        albumTag: "%(channel,uploader)s", artistTag: "Some: Artist")
        let s = Source(name: "n", url: "https://www.youtube.com/@x", profileID: p.id)
        func args() -> [String] {
            ArgBuilder.downloadArgs(source: s, profile: p, settings: Settings(), archive: nil,
                                    destination: URL(fileURLWithPath: "/tmp/d"), ffmpegDir: nil)
        }
        #expect(args().contains("%(channel,uploader)s:%(meta_album)s"))
        #expect(!args().contains { $0.hasSuffix(":%(meta_artist)s") })     // a colon would split the option
        p.embedMetadata = false
        #expect(!args().contains("--parse-metadata"))
    }

    @Test func builtInAudioProfilesTagTheChannelAsAlbumAndArtist() {
        for p in Profile.builtins where p.kind == .audio {
            #expect(p.albumTag == "%(channel,uploader)s")
            #expect(p.artistTag == "%(channel,uploader)s")
        }
    }

    @Test func avatarPickerPrefersTheUncroppedAvatar() {
        let thumbs: [[String: Any]] = [
            ["id": "banner_uncropped", "url": "https://yt3.googleusercontent.com/banner=s1000"],
            ["id": "avatar_uncropped", "url": "https://yt3.googleusercontent.com/avatar=s900"],
            ["id": "0", "url": "https://yt3.googleusercontent.com/x=s88", "width": 88, "height": 88],
        ]
        #expect(ChannelCover.pickAvatar(thumbs) == "https://yt3.googleusercontent.com/avatar=s900")
        let noIDs: [[String: Any]] = [
            ["id": "1", "url": "https://yt3.googleusercontent.com/small=s88", "width": 88, "height": 88],
            ["id": "2", "url": "https://yt3.googleusercontent.com/big=s400", "width": 400, "height": 400],
            ["id": "banner", "url": "https://yt3.googleusercontent.com/b=w2560", "width": 2560, "height": 424],
        ]
        #expect(ChannelCover.pickAvatar(noIDs) == "https://yt3.googleusercontent.com/big=s400")
        #expect(ChannelCover.pickAvatar([]) == nil)
        #expect(ChannelCover.hiRes("https://yt3.googleusercontent.com/a=s88-c-k-c0x00ffffff-no-rj") == "https://yt3.googleusercontent.com/a=s1000")
    }
}
