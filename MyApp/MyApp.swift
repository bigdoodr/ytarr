import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import YTArrCore

/// Menu-bar host: runs the YTArr server in-process.
@main
struct MyApp: App {
    @State private var host = ServerHost()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(host: host)
        } label: {
            Image("MenuBarIcon")
        }
        .menuBarExtraStyle(.menu)

        Window("YTArr Settings", id: "settings") { SettingsView() }
            .windowResizability(.contentSize)
    }
}

@MainActor
@Observable
final class ServerHost {
    var status: Engine.Status?
    var error: String?

    @ObservationIgnored let config: WebConfig
    @ObservationIgnored private let store = Store()
    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private var serverTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var downloadActivity: NSObjectProtocol?

    var url: URL { URL(string: "http://\(config.bind == "0.0.0.0" ? "localhost" : config.bind):\(config.port)")! }

    init() {
        ServerPrefs.migrateLegacyPassword()
        Notifier.requestAuthorization()
        let lan = ServerPrefs.listenOnLAN
        // LAN access without a password is never allowed.
        let pw = ServerPrefs.password
        let bindLAN = lan && !pw.isEmpty
        config = WebConfig(bind: bindLAN ? "0.0.0.0" : "127.0.0.1", port: ServerPrefs.port, password: pw.isEmpty ? nil : pw, username: ServerPrefs.username)
        engine = Engine(store: store)
        // Stay responsive for scheduled checks (no App Nap) but still let the Mac idle-sleep.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "YTArr scheduled downloads")
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [engine] _ in
            // Stop yt-dlp children before we exit (wait briefly; the engine is its own actor).
            let sem = DispatchSemaphore(value: 0)
            Task.detached { await engine.stop(); sem.signal() }
            _ = sem.wait(timeout: .now() + 2)
        }
        start()
    }

    private func start() {
        let (store, engine, config) = (store, engine, config)
        serverTask = Task {
            await engine.setNotifier { notice in Notifier.send(notice) }
            await engine.start()
            do { try await runWebServer(store: store, engine: engine, config: config) }
            catch { await MainActor.run { self.error = "Server stopped: \(error.localizedDescription)" } }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let s = await engine.status()
                await MainActor.run { self?.status = s; self?.updateSleepAssertion(busy: s.running != nil || s.updating) }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// While a download is running, keep the Mac from idle-sleeping so it finishes.
    private func updateSleepAssertion(busy: Bool) {
        if busy, downloadActivity == nil {
            downloadActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "YTArr downloading")
        } else if !busy, let a = downloadActivity {
            ProcessInfo.processInfo.endActivity(a); downloadActivity = nil
        }
    }

    func checkAll() { Task { await engine.checkAll() } }
    func updateYtDlp() { Task { await engine.updateYtDlpNow() } }
    func openUI() { NSWorkspace.shared.open(url) }
}

struct MenuContent: View {
    let host: ServerHost
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        if let e = host.error { Text(e) }
        if let s = host.status {
            if s.updating { Text("Updating yt-dlp...") }
            else if let r = s.running { Text("Downloading: \(r)"); if !s.progress.isEmpty { Text(s.progress) } }
            else { Text("Idle") }
            if !s.queued.isEmpty { Text("Queued: \(s.queued.count)") }
            Text(s.ytdlpVersion.map { "yt-dlp \($0)" } ?? "yt-dlp not installed yet")
            if s.ffmpegDir == nil { Text("Warning: ffmpeg not found (brew install ffmpeg)") }
        }
        Divider()
        Button("Open Web UI") { host.openUI() }.keyboardShortcut("o")
        Button("Check All Sources Now") { host.checkAll() }
        Button("Update yt-dlp Now") { host.updateYtDlp() }
        Button("Settings...") { NSApplication.shared.activate(ignoringOtherApps: true); openWindow(id: "settings") }.keyboardShortcut(",")
        Divider()
        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, on in
                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
            }
        Divider()
        Button("Quit YTArr") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Posts system notifications for the engine's notices (new downloads, sources that start failing).
enum Notifier {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "notify") as? Bool ?? true }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(_ notice: Engine.Notice) {
        guard enabled else { return }
        let c = UNMutableNotificationContent()
        c.title = notice.title
        c.body = notice.body
        if notice.kind == .problem { c.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
