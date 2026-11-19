import SwiftUI
import AppKit
import ServiceManagement
import YTArrCore

/// Menu-bar host: runs the YTArr server in-process.
@main
struct MyApp: App {
    @State private var host = ServerHost()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(host: host)
        } label: {
            Image(systemName: host.status?.running != nil ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .menuBarExtraStyle(.menu)
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

    var url: URL { URL(string: "http://\(config.bind == "0.0.0.0" ? "localhost" : config.bind):\(config.port)")! }

    init() {
        let d = UserDefaults.standard
        let lan = d.bool(forKey: "listenOnLAN")
        config = WebConfig(bind: lan ? "0.0.0.0" : "127.0.0.1",
                           port: d.integer(forKey: "port") == 0 ? 8686 : d.integer(forKey: "port"),
                           password: d.string(forKey: "password"))
        engine = Engine(store: store)
        // Stay responsive for scheduled checks (no App Nap) but still let the Mac idle-sleep.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "YTArr scheduled downloads")
        start()
    }

    private func start() {
        let (store, engine, config) = (store, engine, config)
        serverTask = Task {
            await engine.start()
            do { try await runWebServer(store: store, engine: engine, config: config) }
            catch { await MainActor.run { self.error = "Server stopped: \(error.localizedDescription)" } }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let s = await engine.status()
                await MainActor.run { self?.status = s }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func checkAll() { Task { await engine.checkAll() } }
    func updateYtDlp() { Task { await engine.updateYtDlpNow() } }
    func openUI() { NSWorkspace.shared.open(url) }
}

struct MenuContent: View {
    let host: ServerHost
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        if let e = host.error { Text(e) }
        if let s = host.status {
            if s.updating { Text("Updating yt-dlp...") }
            else if let r = s.running { Text("Downloading: \(r)"); if !s.progress.isEmpty { Text(s.progress) } }
            else { Text("Idle") }
            if !s.queued.isEmpty { Text("Queued: \(s.queued.count)") }
            Text(s.ytdlpVersion.map { "yt-dlp \($0)" } ?? "yt-dlp not installed yet")
        }
        Divider()
        Button("Open Web UI") { host.openUI() }.keyboardShortcut("o")
        Button("Check All Sources Now") { host.checkAll() }
        Button("Update yt-dlp Now") { host.updateYtDlp() }
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
