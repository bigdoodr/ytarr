import Foundation
import CryptoKit

/// Finds, installs and self-updates the yt-dlp binary the engine uses.
public actor YtDlpManager {
    public static let releaseBase = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
    public static let assetName = "yt-dlp_macos"      // universal (arm64 + x86_64) standalone build

    public init() {}

    public nonisolated var managedBinary: URL { AppPaths.bin.appendingPathComponent("yt-dlp") }

    /// Resolution order: explicit override > managed copy > Homebrew.
    public func executable(_ settings: Settings) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if !settings.ytdlpPathOverride.isEmpty { candidates.append(AppPaths.expand(settings.ytdlpPathOverride)) }
        candidates += [managedBinary.path, "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public func isManaged(_ exe: URL) -> Bool { exe.path == managedBinary.path }

    public nonisolated func ffmpegDirectory() -> String? {
        let fm = FileManager.default
        for dir in [AppPaths.bin.path, "/opt/homebrew/bin", "/usr/local/bin"] where fm.isExecutableFile(atPath: dir + "/ffmpeg") {
            return dir
        }
        return nil
    }

    public func version(_ exe: URL) async -> String? {
        guard let r = try? await ProcessRunner.capture(exe, ["--version"]), r.status == 0 else { return nil }
        return r.lines.first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Downloads the standalone binary, verifies its SHA-256 against the release's SHA2-256SUMS, and installs it.
    public func install() async throws -> String {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ytarr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let (binTmp, binResp) = try await URLSession.shared.download(from: URL(string: Self.releaseBase + Self.assetName)!)
        guard (binResp as? HTTPURLResponse)?.statusCode == 200 else { throw ManagerError.http("yt-dlp download failed") }
        let (sumData, sumResp) = try await URLSession.shared.data(from: URL(string: Self.releaseBase + "SHA2-256SUMS")!)
        guard (sumResp as? HTTPURLResponse)?.statusCode == 200 else { throw ManagerError.http("checksum download failed") }

        let sums = String(decoding: sumData, as: UTF8.self)
        guard let expected = sums.split(separator: "\n")
            .map({ $0.split(separator: " ", omittingEmptySubsequences: true) })
            .first(where: { $0.count == 2 && $0[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == Self.assetName })?[0]
        else { throw ManagerError.checksum("no checksum listed for \(Self.assetName)") }

        let data = try Data(contentsOf: binTmp)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw ManagerError.checksum("SHA-256 mismatch; refusing to install") }

        let staged = tmp.appendingPathComponent("yt-dlp")
        try data.write(to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        guard let v = await version(staged) else { throw ManagerError.checksum("downloaded binary does not run") }

        if FileManager.default.fileExists(atPath: managedBinary.path) {
            _ = try FileManager.default.replaceItemAt(managedBinary, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: managedBinary)
        }
        return v
    }

    /// Self-updates a managed binary with `yt-dlp --update-to`, keeping a backup and rolling back if it breaks.
    /// Binaries owned by Homebrew or an override path are left alone (their owner updates them).
    public func update(settings: Settings) async throws -> String {
        guard let exe = executable(settings) else { return try await install() }
        guard isManaged(exe) else {
            let v = await version(exe) ?? "unknown"
            return "Using external yt-dlp \(v) at \(exe.path); update it with its own package manager."
        }
        let before = await version(exe) ?? "unknown"
        let backup = AppPaths.bin.appendingPathComponent("yt-dlp.prev")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: exe, to: backup)

        let r = try await ProcessRunner.capture(exe, ["--update-to", settings.updateChannel])
        if let after = await version(exe) {
            return after == before ? "yt-dlp \(after) is up to date" : "Updated yt-dlp \(before) -> \(after)"
        }
        // Binary no longer runs: restore the backup.
        _ = try? FileManager.default.replaceItemAt(exe, withItemAt: backup)
        throw ManagerError.checksum("update broke yt-dlp (exit \(r.status)); rolled back to \(before)")
    }

    public enum ManagerError: Error, LocalizedError {
        case http(String), checksum(String)
        public var errorDescription: String? {
            switch self { case .http(let s), .checksum(let s): return s }
        }
    }
}
