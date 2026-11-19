import XCTest
@testable import YTArrCore

final class ArgBuilderTests: XCTestCase {
    func testTokenizeRespectsQuotes() {
        XCTAssertEqual(ArgBuilder.tokenize("--a 1 --b \"two words\" --c 'x y'"), ["--a", "1", "--b", "two words", "--c", "x y"])
        XCTAssertEqual(ArgBuilder.tokenize("   "), [])
    }

    func testChannelURLGetsVideosTab() {
        var s = Source(name: "n", url: "https://www.youtube.com/@Example/", profileID: UUID())
        s.kind = .channel
        XCTAssertEqual(ArgBuilder.normalizedURL(s), "https://www.youtube.com/@Example/videos")
        s.url = "https://www.youtube.com/@Example/streams"
        XCTAssertEqual(ArgBuilder.normalizedURL(s), "https://www.youtube.com/@Example/streams")
        s.kind = .playlist; s.url = "https://www.youtube.com/playlist?list=PLx"
        XCTAssertEqual(ArgBuilder.normalizedURL(s), "https://www.youtube.com/playlist?list=PLx")
    }

    func testKindDetection() {
        XCTAssertEqual(Source.detectKind("https://www.youtube.com/playlist?list=PLabc"), .playlist)
        XCTAssertEqual(Source.detectKind("https://www.youtube.com/@Example"), .channel)
        XCTAssertEqual(Source.detectKind("https://vimeo.com/user123"), .other)
    }

    func testAudioProfileArgs() {
        let p = Profile.builtins.first { $0.kind == .audio && $0.audioFormat == "mp3" }!
        let s = Source(name: "n", url: "https://www.youtube.com/@Example", profileID: p.id)
        let args = ArgBuilder.downloadArgs(source: s, profile: p, settings: Settings(),
                                           archive: URL(fileURLWithPath: "/tmp/a.txt"),
                                           destination: URL(fileURLWithPath: "/tmp/dest"), ffmpegDir: "/opt/homebrew/bin")
        XCTAssertTrue(args.contains("-x"))
        XCTAssertEqual(args[args.firstIndex(of: "--audio-format")! + 1], "mp3")
        XCTAssertTrue(args.contains("--break-on-existing"))          // channel
        XCTAssertEqual(args.last, "https://www.youtube.com/@Example/videos")
        XCTAssertEqual(args[args.firstIndex(of: "--match-filters")! + 1], "original_url!*=/shorts/ & !is_live")
    }

    func testPlaylistDoesNotBreakOnExisting() {
        let p = Profile.builtins[0]
        var s = Source(name: "n", url: "https://www.youtube.com/playlist?list=PLx", profileID: p.id)
        s.kind = .playlist
        let args = ArgBuilder.downloadArgs(source: s, profile: p, settings: Settings(),
                                           archive: URL(fileURLWithPath: "/tmp/a.txt"),
                                           destination: URL(fileURLWithPath: "/tmp/d"), ffmpegDir: nil)
        XCTAssertFalse(args.contains("--break-on-existing"))
    }

    func testFormParsing() {
        let f = Form("name=My+Show&url=https%3A%2F%2Fexample.com%2F%3Fa%3D1&skipShorts=on")
        XCTAssertEqual(f.str("name"), "My Show")
        XCTAssertEqual(f.str("url"), "https://example.com/?a=1")
        XCTAssertTrue(f.bool("skipShorts"))
        XCTAssertFalse(f.bool("skipLive"))
    }
}

final class SafeTokensTests: XCTestCase {
    func testBlocksExecAndConfig() {
        XCTAssertEqual(ArgBuilder.safeTokens("--exec 'rm -rf x' --no-mtime"), ["--no-mtime"])
        XCTAssertEqual(ArgBuilder.safeTokens("--exec=foo --limit-rate 1M"), ["--limit-rate", "1M"])
        XCTAssertEqual(ArgBuilder.safeTokens("--exe foo --config-locations /tmp/x -f best"), ["-f", "best"])
        XCTAssertEqual(ArgBuilder.safeTokens("--extract-audio --embed-chapters"), ["--extract-audio", "--embed-chapters"])
    }
}
