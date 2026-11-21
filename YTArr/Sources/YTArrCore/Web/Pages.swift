import Foundation

enum Pages {
    // MARK: Sources
    static func sources(_ st: Store.State, _ status: Engine.Status) -> String {
        let rows = st.sources.map { s -> String in
            let p = st.profiles.first { $0.id == s.profileID }?.name ?? "(missing)"
            let bad = s.lastStatus.hasPrefix("Error") || s.lastStatus.hasPrefix("Blocked")
            let running = status.running == s.name
            return """
            <tr><td><a href="/sources/\(s.id)">\(H.esc(s.name))</a><br><small>\(H.esc(s.url))</small></td>
            <td>\(H.esc(p))</td><td>\(s.enabled ? "every \(s.intervalMinutes) min" : "<span class=mut>paused</span>")</td>
            <td>\(H.date(s.lastChecked))<br><small>next: \(s.enabled ? H.date(s.nextCheck) : "-")</small></td>
            <td class="\(bad ? "bad" : "")">\(running ? "<b>\(H.esc(status.progress))</b>" : H.esc(s.lastStatus))</td>
            <td class="row"><a class="btn" href="/sources/\(s.id)/browse">Browse</a><form method="post" action="/sources/\(s.id)/check"><button>Check now</button></form></td></tr>
            """
        }.joined()
        return """
        <div class="row"><h1 style="margin:0">Sources</h1><span style="flex:1"></span>
        <form method="post" action="/check-all"><button>Check all</button></form>
        <a class="btn p" href="/sources/new">Add source</a></div>
        \(st.sources.isEmpty ? "<p class=mut>No sources yet. Add a YouTube channel or playlist to start monitoring it.</p>" :
        "<table><tr><th>Source</th><th>Profile</th><th>Schedule</th><th>Last / next check</th><th>Status</th><th></th></tr>\(rows)</table>")
        """
    }

    // MARK: Browse (Sonarr-style picker)
    static func browse(_ src: Source, videos: [CatalogEntry], playlists: [CatalogEntry], busy: Bool, progress: String) -> String {
        let id = src.id
        let isChannel = src.kind == .channel
        let busyNote = busy ? "<p><b>\(H.esc(progress))</b> <small>(this page refreshes itself)</small></p>" : ""

        let plSection: String
        if !isChannel {
            plSection = ""
        } else if playlists.isEmpty {
            plSection = "<h2>Playlists</h2><p class=mut>No playlists scanned yet. Use \"Scan playlists\" above.</p>"
        } else {
            let rows = playlists.map {
                "<tr data-t=\"\(H.esc($0.title.lowercased()))\"><td><input type=\"checkbox\" name=\"pl\" value=\"\(H.esc($0.id))\"></td><td>\(H.esc($0.title))<br><small>\(H.esc($0.url))</small></td></tr>"
            }.joined()
            plSection = """
            <h2>Playlists (\(playlists.count))</h2>
            <form method="post" action="/sources/\(id)/playlists/add">
            \(pagerControls("pls", submit: "Add selected as sources"))
            <table id="pls"><tr><th></th><th>Playlist</th></tr>\(rows)</table>
            <div class="pg pg-pls"></div>
            <p><small>Each is added as "Index only", so nothing downloads until you pick videos. It uses this source's profile.</small></p>
            </form>
            """
        }

        let vidSection: String
        if videos.isEmpty {
            vidSection = "<h2>Videos</h2><p class=mut>No videos listed yet. Use \"Scan videos\" above; nothing is downloaded by scanning.</p>"
        } else {
            let have = videos.filter(\.downloaded).count
            let fresh = videos.filter { $0.isNew == true }.count
            let rows = videos.map { v in
                """
                <tr data-t="\(H.esc(v.title.lowercased()))"><td><input type="checkbox" name="v" value="\(H.esc(v.id))"></td>\
                <td>\(H.esc(v.title))</td><td>\(H.esc(v.duration))</td>\
                <td>\(v.downloaded ? "<span class=\"pill ok\">downloaded</span>" : (v.isNew == true ? "<span class=\"pill\">new</span>" : ""))</td></tr>
                """
            }.joined()
            vidSection = """
            <h2>Videos (\(videos.count), \(have) downloaded\(fresh > 0 ? ", \(fresh) new" : ""))</h2>
            \(fresh > 0 ? "<form method=\"post\" action=\"/sources/\(id)/seen\" style=\"margin-bottom:8px\"><button>Mark all as seen</button></form>" : "")
            <form method="post" action="/sources/\(id)/download">
            \(pagerControls("vids", submit: "Download selected"))
            <table id="vids"><tr><th></th><th>Title</th><th>Length</th><th></th></tr>\(rows)</table>
            <div class="pg pg-vids"></div>
            </form>
            """
        }
        let script = (playlists.isEmpty || !isChannel ? "" : "initPager('pls');") + (videos.isEmpty ? "" : "initPager('vids');")

        return """
        <div class="row"><h1 style="margin:0">\(H.esc(src.name))</h1><span style="flex:1"></span>
        <a class="btn" href="/sources/\(id)">Settings</a>
        <form method="post" action="/sources/\(id)/scan"><button>Scan videos</button></form>
        \(isChannel ? "<form method=\"post\" action=\"/sources/\(id)/scan-playlists\"><button>Scan playlists</button></form>" : "")
        \(isChannel ? "<form method=\"post\" action=\"/sources/\(id)/cover\"><button>Refresh channel cover</button></form>" : "")</div>
        <p class="mut">Browse what's available and choose what to download. Scanning only lists titles; it never downloads.</p>
        \(busyNote)\(plSection)\(vidSection)
        <script>\(pagerScript)\(script)</script>
        """
    }

    /// Filter box, selection helpers and a submit button for a paged table (`id` = table id).
    private static func pagerControls(_ id: String, submit: String) -> String {
        """
        <div class="row" style="margin-bottom:6px">
        <input type="text" placeholder="Filter by title" oninput="pagers.\(id).filter(this.value)" style="max-width:320px">
        <button type="button" onclick="pagers.\(id).selectPage(true)">Select page</button>
        <button type="button" onclick="pagers.\(id).selectAll()">Select all matching</button>
        <button type="button" onclick="pagers.\(id).clear()">Clear</button>
        <button class="p">\(submit)</button></div>
        <div class="pg pg-\(id)"></div>
        """
    }

    /// Client-side paging so ticked boxes survive page changes and the filter covers every row.
    /// Rows are `tr[data-t]` (lowercased title); each table's page size is remembered in localStorage.
    private static let pagerScript = """
    var pagers={};
    function initPager(id){
      var rows=[].slice.call(document.querySelectorAll('#'+id+' tr[data-t]'));
      var key='ytarr.'+id+'.size';
      var st={size:parseInt(localStorage.getItem(key))||25,page:0,q:'',m:rows};
      function checked(r){return r.querySelector('input').checked}
      function render(){
        st.m=rows.filter(function(r){return r.dataset.t.indexOf(st.q)>=0});
        var pages=Math.max(1,Math.ceil(st.m.length/st.size));
        st.page=Math.min(Math.max(st.page,0),pages-1);
        var a=st.page*st.size,b=Math.min(a+st.size,st.m.length);
        var on=new Set(st.m.slice(a,b));
        rows.forEach(function(r){r.style.display=on.has(r)?'':'none'});
        var sizes=[10,25,50,100].map(function(n){return n==st.size?'<b>'+n+'</b>':'<a href="#" data-n="'+n+'">'+n+'</a>'}).join(' | ');
        var h='Showing '+(st.m.length?a+1:0)+'&ndash;'+b+' of '+st.m.length+(st.m.length<rows.length?' (filtered from '+rows.length+')':'');
        h+=' &middot; View '+sizes;
        h+=' &middot; <a href="#" data-go="first">First</a> <a href="#" data-go="prev">Prev</a> Page '+(st.page+1)+' of '+pages+' <a href="#" data-go="next">Next</a> <a href="#" data-go="last">Last</a>';
        h+=' &middot; <b>'+rows.filter(checked).length+'</b> selected';
        document.querySelectorAll('.pg-'+id).forEach(function(el){el.innerHTML=h});
      }
      document.addEventListener('click',function(e){
        var el=e.target.closest('.pg-'+id+' a');
        if(!el)return;
        e.preventDefault();
        if(el.dataset.n){st.size=parseInt(el.dataset.n);localStorage.setItem(key,st.size);st.page=0}
        var go=el.dataset.go,pages=Math.max(1,Math.ceil(st.m.length/st.size));
        if(go=='first')st.page=0;else if(go=='prev')st.page--;else if(go=='next')st.page++;else if(go=='last')st.page=pages-1;
        render();
      });
      document.getElementById(id).addEventListener('change',render);
      pagers[id]={
        filter:function(q){st.q=q.toLowerCase();st.page=0;render()},
        selectPage:function(on){rows.forEach(function(r){if(r.style.display!=='none')r.querySelector('input').checked=on});render()},
        selectAll:function(){st.m.forEach(function(r){r.querySelector('input').checked=true});render()},
        clear:function(){rows.forEach(function(r){r.querySelector('input').checked=false});render()}
      };
      render();
    }
    """

    /// What the source form needs to draw a media-server library picker.
    struct MediaChoices {
        var configured = false
        var libraries: [MediaLibrary] = []
        var error: String?
    }

    /// Library picker for one media server. Always submits a value (hidden when the list can't be shown),
    /// so saving the form never wipes a library that was chosen earlier.
    private static func mediaField(_ label: String, _ name: String, _ server: String, current: String?, _ c: MediaChoices) -> String {
        let cur = current ?? ""
        let keep = "<input type=\"hidden\" name=\"\(name)\" value=\"\(H.esc(cur))\">"
        if !c.configured {
            return "<label>\(label)</label><div>\(keep)<small>Not connected. Add \(server) under Settings to pick a library.</small></div>"
        }
        if let e = c.error {
            return "<label>\(label)</label><div>\(keep)<small class=\"bad\">Couldn't load \(server) libraries: \(H.esc(e))</small></div>"
        }
        var opts = [("", "Don't notify \(server)")] + c.libraries.map { ($0.id, $0.kind.isEmpty ? $0.name : "\($0.name) (\($0.kind))") }
        if !cur.isEmpty && !c.libraries.contains(where: { $0.id == cur }) { opts.append((cur, "(no longer on \(server)) \(cur)")) }
        return H.select(label, name, opts, selected: cur)
    }

    static func sourceForm(_ st: Store.State, _ s: Source?, isNew: Bool,
                           jellyfin: MediaChoices, audiobookshelf: MediaChoices) -> String {
        let src = s ?? Source(name: "", url: "", profileID: st.profiles.first?.id ?? UUID())
        let profiles = st.profiles.map { ($0.id.uuidString, $0.name) }
        let intervals = [(30, "30 minutes"), (60, "1 hour"), (180, "3 hours"), (360, "6 hours"), (720, "12 hours"), (1440, "Daily")]
        let ivOpts = intervals.map { (String($0.0), $0.1) }
        let action = isNew ? "/sources" : "/sources/\(src.id)"
        return """
        <h1>\(isNew ? "Add source" : H.esc(src.name))</h1>
        \(isNew ? "" : "<p><a class=\"btn\" href=\"/sources/\(src.id)/browse\">Browse videos &amp; playlists</a></p>")
        <form class="f" method="post" action="\(action)">
        \(H.input("Name", "name", src.name, hint: "A label for this source"))
        \(H.input("URL", "url", src.url, hint: "Channel (youtube.com/@name), playlist, or any site yt-dlp supports"))
        \(H.select("Profile", "profile", profiles, selected: src.profileID.uuidString))
        \(H.input("Folder", "destination", src.destination, hint: "Where this source's files go. Blank = library root / profile name. Use a full path (or ~/...) to put them anywhere, e.g. a Jellyfin or Audiobookshelf library folder; the profile's file name template adds subfolders inside it."))
        \(mediaField("Jellyfin library", "jellyfinLibrary", "Jellyfin", current: src.jellyfinLibraryID, jellyfin))
        \(mediaField("Audiobookshelf library", "absLibrary", "Audiobookshelf", current: src.absLibraryID, audiobookshelf))
        \(H.check("Monitor only (no auto-download)", "monitorOnly", src.monitorOnly ?? false))
        \(H.select("Check every", "interval", ivOpts, selected: String(src.intervalMinutes)))
        \(H.select("First check", "backfill", [("nothing", "Index only - download nothing, I'll pick videos"), ("fromNow", "Only new videos from now on"), ("latest", "Newest N videos, then new ones"), ("all", "Everything")], selected: src.backfillMode.rawValue))
        \(H.input("N (for 'Newest N')", "count", String(src.backfillCount), type: "number"))
        \(H.input("Max downloads per check", "maxPerCheck", src.maxPerCheck.map(String.init) ?? "", hint: "Blank = no limit. A cap keeps a big backlog from hammering YouTube: the rest follows on later checks (each check then looks through the whole channel, not only the newest videos).", type: "number"))
        \(H.check("Save channel picture as cover.jpg", "channelCover", src.saveChannelCover ?? false))
        \(H.check("Skip Shorts", "skipShorts", src.skipShorts))
        \(H.check("Skip live streams", "skipLive", src.skipLive))
        \(H.input("Title must match", "titleRegex", src.titleRegex, hint: "Optional regex, case-insensitive"))
        \(H.input("Extra yt-dlp args", "extraArgs", src.extraArgs))
        \(H.check("Enabled", "enabled", src.enabled))
        <div class="full row"><button class="p">Save</button><a class="btn" href="/">Cancel</a></div>
        </form>
        \(isNew ? "" : "<form method=\"post\" action=\"/sources/\(src.id)/delete\" onsubmit=\"return confirm('Remove this source? Downloaded files are kept.')\" style=\"margin-top:20px\"><button class=\"d\">Remove source</button></form>")
        """
    }

    // MARK: Profiles
    static func profiles(_ st: Store.State) -> String {
        let rows = st.profiles.map { p in
            let used = st.sources.filter { $0.profileID == p.id }.count
            return "<tr><td><a href=\"/profiles/\(p.id)\">\(H.esc(p.name))</a></td><td>\(p.kind.rawValue)</td><td><small>\(H.esc(p.format))</small></td><td>\(used)</td></tr>"
        }.joined()
        return """
        <div class="row"><h1 style="margin:0">Profiles</h1><span style="flex:1"></span><a class="btn p" href="/profiles/new">New profile</a></div>
        <p class="mut">A profile decides what yt-dlp downloads and how files are named, like a quality profile in Sonarr.</p>
        <table><tr><th>Name</th><th>Type</th><th>Format</th><th>Sources</th></tr>\(rows)</table>
        """
    }

    static func profileForm(_ p: Profile?, isNew: Bool, inUse: Bool) -> String {
        let pr = p ?? Profile(name: "", kind: .video, format: "bv*+ba/b", mergeFormat: "mp4",
                              outputTemplate: "%(channel,uploader)s/%(upload_date)s - %(title)s [%(id)s].%(ext)s")
        let action = isNew ? "/profiles" : "/profiles/\(pr.id)"
        return """
        <h1>\(isNew ? "New profile" : H.esc(pr.name))</h1>
        <form class="f" method="post" action="\(action)">
        \(H.input("Name", "name", pr.name))
        \(H.select("Type", "kind", [("video", "Video"), ("audio", "Audio only")], selected: pr.kind.rawValue))
        \(H.input("Format (-f)", "format", pr.format, hint: "yt-dlp format selector"))
        \(H.input("Merge container", "mergeFormat", pr.mergeFormat, hint: "Video: mp4, mkv, ... (blank = yt-dlp default)"))
        \(H.input("Audio format", "audioFormat", pr.audioFormat, hint: "Audio: mp3, m4a, opus, flac, ..."))
        \(H.input("Audio quality", "audioQuality", pr.audioQuality, hint: "0 = best ... 10 = worst, or a bitrate like 192K"))
        \(H.input("File name template", "outputTemplate", pr.outputTemplate, hint: "yt-dlp output template, relative to the folder"))
        \(H.check("Embed metadata", "embedMetadata", pr.embedMetadata))
        \(H.input("Album tag", "albumTag", pr.albumTag ?? "", hint: "yt-dlp template such as %(channel,uploader)s (no colons). Needs Embed metadata. Blank = leave as is."))
        \(H.input("Artist tag", "artistTag", pr.artistTag ?? "", hint: "Same idea for the Artist tag."))
        \(H.check("Embed thumbnail", "embedThumbnail", pr.embedThumbnail))
        \(H.check("Write .info.json", "writeInfoJSON", pr.writeInfoJSON))
        \(H.check("Save thumbnail file (.jpg)", "writeThumbnail", pr.writeThumbnail ?? false))
        \(H.select("Jellyfin .nfo file", "nfoStyle", [("off", "None"), ("movie", "Movie (Movies / Home Videos libraries)"), ("episode", "Episode (TV Shows libraries)")], selected: (pr.nfoStyle ?? .off).rawValue))
        \(H.check("Embed English subtitles", "embedSubs", pr.embedSubs))
        \(H.input("SponsorBlock remove", "sponsorblock", pr.sponsorblockRemove, hint: "e.g. sponsor,selfpromo (blank = off)"))
        \(H.input("Extra yt-dlp args", "extraArgs", pr.extraArgs))
        <div class="full row"><button class="p">Save</button><a class="btn" href="/profiles">Cancel</a></div>
        </form>
        \(isNew ? "" : inUse ? "<p class=mut>This profile is used by a source and can't be deleted.</p>" :
        "<form method=\"post\" action=\"/profiles/\(pr.id)/delete\" style=\"margin-top:20px\"><button class=\"d\">Delete profile</button></form>")
        """
    }

    // MARK: Activity
    static func activity(_ st: Store.State, _ status: Engine.Status, _ log: [String]) -> String {
        let now: String
        if let r = status.running {
            now = "<p><b>\(H.esc(r))</b>: \(H.esc(status.progress)) <form style=\"display:inline\" method=\"post\" action=\"/activity/cancel\"><button class=\"d\">Cancel</button></form></p>"
        } else { now = "<p class=mut>Nothing running.</p>" }
        let queued = status.queued.isEmpty ? "" : "<p class=mut>Queued: \(status.queued.map(H.esc).joined(separator: ", "))</p>"
        let rows = st.history.prefix(100).map {
            "<tr><td>\(H.date($0.date))</td><td>\(H.esc($0.sourceName))</td><td>\(H.esc($0.title))<br><small>\(H.esc($0.path))</small></td></tr>"
        }.joined()
        return """
        <h1>Activity</h1>\(now)\(queued)
        <h2>Recent downloads</h2>
        \(st.history.isEmpty ? "<p class=mut>Nothing downloaded yet.</p>" : "<table><tr><th>When</th><th>Source</th><th>Video</th></tr>\(rows)</table>")
        <h2>Log</h2><pre>\(H.esc(log.joined(separator: "\n")))</pre>
        """
    }

    // MARK: Settings
    static func settings(_ st: Store.State, _ status: Engine.Status) -> String {
        let s = st.settings
        let ff = status.ffmpegDir.map { "found in \(H.esc($0))" } ?? "<span class=bad>not found - run <code>brew install ffmpeg</code> (needed to merge video/audio and convert audio)</span>"
        return """
        <h1>Settings</h1>
        <p class="mut">The web sign-in (username and password), port and network access are in the YTArr menu bar icon, under Settings...</p>
        <h2>yt-dlp</h2>
        <p>Version: <b>\(H.esc(status.ytdlpVersion ?? "not installed"))</b> <small>\(H.esc(status.ytdlpPath ?? ""))</small><br>
        ffmpeg: \(ff)<br>
        <small>Last update check: \(H.date(s.lastUpdateCheck)) \(H.esc(s.lastUpdateResult))</small></p>
        <div class="row">
        <form method="post" action="/settings/ytdlp-update"><button class="p">\(status.ytdlpVersion == nil ? "Install yt-dlp" : "Update now")</button></form>
        \(status.updating ? "<span class=mut>Working...</span>" : "")</div>
        <h2>General</h2>
        <form class="f" method="post" action="/settings">
        \(H.input("Library folder", "libraryRoot", s.libraryRoot, hint: "Default download location; each profile gets a subfolder"))
        \(H.check("Update yt-dlp automatically", "autoUpdate", s.autoUpdate))
        \(H.input("Check for updates every (hours)", "updateIntervalHours", String(s.updateIntervalHours), type: "number"))
        \(H.select("Update channel", "updateChannel", [("stable", "stable"), ("nightly", "nightly"), ("master", "master")], selected: s.updateChannel))
        \(H.input("Cookies from browser", "cookiesBrowser", s.cookiesBrowser, hint: "safari, chrome, firefox... Helps when YouTube asks to prove you're not a bot"))
        \(H.input("Cookies file", "cookiesFile", s.cookiesFile, hint: "Netscape cookies.txt (overrides the browser option)"))
        \(H.input("Sleep between videos: min (s)", "sleepMin", String(s.sleepMinSeconds), type: "number"))
        \(H.input("Sleep between videos: max (s)", "sleepMax", String(s.sleepMaxSeconds), type: "number"))
        \(H.input("Global extra yt-dlp args", "globalExtraArgs", s.globalExtraArgs))
        \(H.input("yt-dlp path override", "ytdlpPathOverride", s.ytdlpPathOverride, hint: "Blank = managed copy, then Homebrew"))
        <h2 class="full" style="margin:14px 0 0">Media servers</h2>
        <p class="full mut" style="margin:0">Optional. After a source downloads something, YTArr asks the server to rescan the library you pick for that source (on the source's page, once connected here).</p>
        \(H.input("Jellyfin address", "jellyfinURL", s.jellyfinURL ?? "", hint: "e.g. http://mac-mini.local:8096"))
        \(H.input("Jellyfin API key", "jellyfinAPIKey", "", hint: (s.jellyfinAPIKey ?? "").isEmpty ? "Create one in Jellyfin: Dashboard, API Keys" : "A key is saved. Leave blank to keep it.", type: "password"))
        \(H.input("Audiobookshelf address", "absURL", s.absURL ?? "", hint: "e.g. http://mac-mini.local:13378"))
        \(H.input("Audiobookshelf API token", "absAPIToken", "", hint: (s.absAPIToken ?? "").isEmpty ? "A user's API token in Audiobookshelf (an admin user is needed to scan)" : "A token is saved. Leave blank to keep it.", type: "password"))
        <div class="full row"><button class="p">Save</button></div>
        </form>
        <form method="post" action="/settings/media-test" style="margin-top:14px"><button>Test saved media server connections</button></form>
        """
    }
}
