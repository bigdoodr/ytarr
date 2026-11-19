import SwiftUI
import AppKit
import Security

/// Tiny Keychain wrapper for the web-UI password (kept out of UserDefaults / state.json).
enum Keychain {
    private static let service = "rocks.scruggsfam.ytarr"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func get(_ account: String) -> String? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ account: String, _ value: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account); q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// Server settings the menu-bar app reads at launch (LAN access, port, password).
enum ServerPrefs {
    static let passwordAccount = "web-ui-password"
    static var listenOnLAN: Bool { UserDefaults.standard.bool(forKey: "listenOnLAN") }
    static var port: Int { let p = UserDefaults.standard.integer(forKey: "port"); return p == 0 ? 8686 : p }
    static var password: String { Keychain.get(passwordAccount) ?? "" }
    /// The name for the web UI's login page ("admin" until changed).
    static var username: String {
        let u = (UserDefaults.standard.string(forKey: "username") ?? "").trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? "admin" : u
    }

    /// Older builds kept the password in UserDefaults; move it into the Keychain once.
    static func migrateLegacyPassword() {
        let d = UserDefaults.standard
        if let old = d.string(forKey: "password"), !old.isEmpty {
            if Keychain.get(passwordAccount) == nil { Keychain.set(passwordAccount, old) }
            d.removeObject(forKey: "password")
        }
    }
}

struct SettingsView: View {
    @State private var lan = ServerPrefs.listenOnLAN
    @State private var port = String(ServerPrefs.port)
    @State private var username = ServerPrefs.username
    @State private var password = ServerPrefs.password
    @State private var saved = false
    @AppStorage("notify") private var notify = true

    private var portValue: Int? { Int(port).flatMap { (1024...65535).contains($0) ? $0 : nil } }
    private var valid: Bool { portValue != nil && (!lan || (!password.isEmpty && !username.trimmingCharacters(in: .whitespaces).isEmpty)) }

    var body: some View {
        Form {
            Toggle("Notify about new downloads and errors", isOn: $notify)
            Toggle("Allow other devices on my network", isOn: $lan)
            TextField("Port", text: $port)
            TextField("Web UI username", text: $username)
            SecureField("Web UI password", text: $password)
            if lan && password.isEmpty {
                Text("A password is required when other devices can connect.").foregroundStyle(.red).font(.caption)
            } else if !lan {
                Text("Only this Mac can open the web UI. A password is optional.").foregroundStyle(.secondary).font(.caption)
            }
            if portValue == nil { Text("Port must be 1024-65535.").foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Save") {
                    UserDefaults.standard.set(lan, forKey: "listenOnLAN")
                    UserDefaults.standard.set(portValue ?? 8686, forKey: "port")
                    UserDefaults.standard.set(username.trimmingCharacters(in: .whitespaces), forKey: "username")
                    Keychain.set(ServerPrefs.passwordAccount, password)
                    saved = true
                }.disabled(!valid)
                if saved {
                    Text("Saved. Restart YTArr to apply.").foregroundStyle(.secondary)
                    Button("Restart Now") { Relauncher.relaunch() }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
    }
}

enum Relauncher {
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        NSApplication.shared.terminate(nil)
    }
}
