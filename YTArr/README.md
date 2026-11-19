# YTArr

A Sonarr/Radarr-style manager for YouTube channels and playlists (and anything else yt-dlp supports).
Native Swift, no Docker. It runs a small web server; you add sources in the browser and it
downloads new videos on a schedule using media profiles.

## Concepts
- **Source**: a channel, playlist or URL to monitor (like a Sonarr series).
- **Profile**: how to download and name things (like a quality profile). Built in:
  Video 1080p MP4, Video best (MKV), Audio MP3, Podcast M4A. Fully editable (`-f` format, merge
  container, audio format, output template, metadata/thumbnail/subtitles, SponsorBlock, extra args).
- **First check** per source: *only new videos from now on* (existing videos are pre-marked as
  downloaded), *newest N*, or *everything*.
- Each source has its own yt-dlp download archive, so nothing is downloaded twice.
  Channels stop scanning at the first video already downloaded; playlists rely on the archive only.
- **yt-dlp self-updates**: the app installs the official standalone `yt-dlp_macos` (SHA-256 verified)
  into `~/Library/Application Support/YTArr/bin/`, then runs `yt-dlp --update-to <channel>` every N
  hours (default 24, stable/nightly/master selectable). A backup is kept and restored if an update
  breaks the binary. A yt-dlp you point to yourself or one from Homebrew is left for its owner to update.

## Run it
Requirements: macOS 14+, `brew install ffmpeg` (needed to merge streams and convert audio).
YouTube extraction may also want a JavaScript runtime in recent yt-dlp releases (`brew install deno`);
the engine adds `/opt/homebrew/bin` to the child PATH so it's found.

**Menu-bar app (recommended on the Mac mini):** create a macOS App target in Xcode, add
`MenuBarApp/YTArrMenuApp.swift`, add this folder as a local Swift package and link `YTArrCore`,
set `LSUIElement` = YES, App Sandbox OFF, sign with Developer ID. Menu: Open Web UI, Check All,
Update yt-dlp, Launch at Login, Quit. Defaults are stored under `listenOnLAN`, `port`, `password`
(`defaults write <bundle-id> listenOnLAN -bool true`; `defaults write <bundle-id> password -string ...`).

**Headless:** `swift build -c release` then `.build/release/ytarrd`. For the LAN:
`YTARR_BIND=0.0.0.0 YTARR_PASSWORD=... ytarrd`. A launchd template is in `deploy/`.

Web UI: http://localhost:8686 (Sources, Profiles, Activity, Settings).

## Security notes
- Default bind is `127.0.0.1`. If you bind to the LAN, set a password (HTTP Basic, sent in clear text
  over your LAN, so don't expose the port beyond it).
- The UI can run arbitrary yt-dlp arguments (extra args), which is effectively command execution for
  anyone who can log in. Keep the password strong and the port off the internet.

## Browsing and picking videos
A source's first check can be **Index only**: it lists everything, marks it all as already had (nothing downloads),
and later checks still grab new uploads. **Browse** on a source lists its videos (and a channel's playlists) with paging,
a title filter and checkboxes: *Download selected* fetches just those, and playlists can be added as their own sources.

## Where files go
Each source has a **Folder** (blank = library root / profile name; any full path or `~/...` works, so a source can
write straight into a Jellyfin or Audiobookshelf library folder). The profile's file name template adds subfolders inside it.

## Jellyfin and Audiobookshelf
Settings > Media servers takes each server's address and API key/token (use **Test saved media server connections**
after saving). The libraries are read live from the servers, and each source picks which one to refresh; after a source
downloads something, YTArr asks that library to rescan. Audiobookshelf's token must belong to an admin to trigger scans.
The keys are stored in plain text in `state.json`, like the web password; keep that file private.
Note: plain `http://` to a LAN address is fine, but macOS App Transport Security can block plain http to a custom
domain name from the menu-bar app (use the IP, a `.local` name, or https).

## Metadata
Every built-in profile embeds yt-dlp's metadata (title, uploader, date, description) in the file's tags. Video profiles
can also **save the thumbnail as a .jpg** and write a **Jellyfin .nfo** (`movie` for Movies / Home Videos libraries,
`episode` for TV Shows libraries) holding the title, description, date and channel. Audio profiles embed the thumbnail
as cover art. The two built-in video profiles have the .jpg and a `movie` .nfo on by default.

## State
`~/Library/Application Support/YTArr/state.json` (settings, profiles, sources, history), `archives/` and `catalogs/`
(the Browse lists). If state.json can't be read, a `.corrupt-<timestamp>` copy is kept before a fresh one is created.

## Status
`swift test` covers argument building, URL normalisation, form parsing, .nfo output and loading older state files.
Not built yet: web-UI add-from-URL title lookup, a calendar/"wanted" view, notifications, per-source progress history.
