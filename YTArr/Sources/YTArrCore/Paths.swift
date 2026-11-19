import Foundation

public enum AppPaths {
    public static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("YTArr", isDirectory: true))
    }
    public static var bin: URL { ensure(support.appendingPathComponent("bin", isDirectory: true)) }
    public static var archives: URL { ensure(support.appendingPathComponent("archives", isDirectory: true)) }
    public static var catalogs: URL { ensure(support.appendingPathComponent("catalogs", isDirectory: true)) }
    public static var stateFile: URL { support.appendingPathComponent("state.json") }

    public static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    public static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\")
        return s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    }
}
