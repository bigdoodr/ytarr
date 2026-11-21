# YTArr 1.0

First release. A native macOS menu-bar app that watches YouTube channels and playlists (and other sites yt-dlp supports) and downloads new videos on a schedule, managed from a web UI.

## Highlights
- Add channels and playlists in the browser; per-source media profiles (MP4, MKV, MP3, M4A, fully editable).
- First check can be Index only, new videos only, newest N, or everything. Browse a source and download only the videos you pick.
- yt-dlp installs and updates itself (SHA-256 verified, with rollback).
- Jellyfin and Audiobookshelf rescans, `.nfo` sidecars, thumbnails and channel covers.
- Login page for LAN use, Keychain-stored password, notifications for new downloads and errors.
- Backs off automatically when YouTube rate-limits or asks for a bot check.

## Install
1. Download `YTArr.zip` from the release assets, unzip, and drag YTArr to Applications.
2. Open it. Right-click > Open the first time if Gatekeeper asks.
3. `brew install ffmpeg` (and `deno` if YouTube extraction asks for a JavaScript runtime).
4. Click the menu-bar icon > Open Web UI (http://localhost:8686).

Requires macOS 14 or later. Only for content you have the right to download.
