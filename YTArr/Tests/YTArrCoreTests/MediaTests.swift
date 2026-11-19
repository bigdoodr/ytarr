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
}
