# YTArr

A Sonarr/Radarr-style manager for YouTube channels and playlists (and anything else yt-dlp supports), as a native macOS menu-bar app with a built-in web UI. No Docker.

Add channels and playlists in the browser, pick a media profile for each (best MP4, MP3-only for podcast players, and so on), and YTArr checks them on a schedule and downloads new videos. yt-dlp keeps itself up to date.

- `ytarr.xcodeproj` and `MyApp/`: the menu-bar app (SwiftUI, macOS 14+)
- `YTArr/`: the Swift package with the engine, web server (Hummingbird) and tests. See [YTArr/README.md](YTArr/README.md) for concepts, Settings, security notes and prerequisites.

## Build
1. `brew install ffmpeg` (and `deno` if YouTube extraction asks for a JavaScript runtime).
2. Open `ytarr.xcodeproj` in Xcode, set your own signing team, and build or archive.
3. Tests: `cd YTArr && swift test`.

Distributed outside the App Store (Developer ID + notarization): a yt-dlp front end isn't App Store material, and the app runs unsandboxed.

Use it only for content you have the right to download.
