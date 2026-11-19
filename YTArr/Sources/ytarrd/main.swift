import Foundation
import YTArrCore

// Headless server: `ytarrd` (use this under launchd on the Mac mini, or run the menu-bar app instead).
//   YTARR_BIND=0.0.0.0   listen on the LAN (default 127.0.0.1)
//   YTARR_PORT=8686
//   YTARR_USER=...       login name for the web UI's sign-in page (default: admin)
//   YTARR_PASSWORD=...   require sign-in (login page; HTTP Basic also works for scripts) - set this if you bind to the LAN
let env = ProcessInfo.processInfo.environment
let config = WebConfig(bind: env["YTARR_BIND"] ?? "127.0.0.1",
                       port: Int(env["YTARR_PORT"] ?? "") ?? 8686,
                       password: env["YTARR_PASSWORD"],
                       username: env["YTARR_USER"] ?? "admin")
if config.bind != "127.0.0.1" && (config.password ?? "").isEmpty {
    FileHandle.standardError.write(Data("WARNING: listening on \(config.bind) without YTARR_PASSWORD; anyone on the network can use YTArr.\n".utf8))
}

let store = Store()
let engine = Engine(store: store)
await engine.start()
print("YTArr listening on http://\(config.bind):\(config.port)")
try await runWebServer(store: store, engine: engine, config: config)
