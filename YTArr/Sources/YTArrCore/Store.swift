import Foundation

/// JSON-backed persistent state. Personal-scale data, so a single atomic file is plenty.
public actor Store {
    public struct State: Codable, Sendable {
        public var version = 1
        public var settings = Settings()
        public var profiles: [Profile] = Profile.builtins
        public var sources: [Source] = []
        public var history: [DownloadRecord] = []
    }

    private var state: State
    private let url: URL

    public init(url: URL = AppPaths.stateFile) {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            if var s = try? dec.decode(State.self, from: data) {
                // Built-in profiles saved before .nfo/thumbnail support existed pick up the new defaults once.
                for i in s.profiles.indices where s.profiles[i].nfoStyle == nil && s.profiles[i].writeThumbnail == nil {
                    if let b = Profile.builtins.first(where: { $0.id == s.profiles[i].id }) {
                        s.profiles[i].nfoStyle = b.nfoStyle; s.profiles[i].writeThumbnail = b.writeThumbnail
                    }
                }
                for i in s.profiles.indices where s.profiles[i].albumTag == nil && s.profiles[i].artistTag == nil {
                    if let b = Profile.builtins.first(where: { $0.id == s.profiles[i].id }) {
                        s.profiles[i].albumTag = b.albumTag; s.profiles[i].artistTag = b.artistTag
                    }
                }
                state = s; return
            }
            // Unreadable state: keep a copy rather than silently overwriting it.
            try? FileManager.default.copyItem(at: url, to: url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))"))
        }
        state = State()
    }

    public func snapshot() -> State { state }
    public func source(_ id: UUID) -> Source? { state.sources.first { $0.id == id } }
    public func profile(_ id: UUID) -> Profile? { state.profiles.first { $0.id == id } }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func upsert(_ p: Profile) {
        if let i = state.profiles.firstIndex(where: { $0.id == p.id }) { state.profiles[i] = p } else { state.profiles.append(p) }
        save()
    }
    /// Returns false if the profile is still used by a source.
    public func deleteProfile(_ id: UUID) -> Bool {
        if state.sources.contains(where: { $0.profileID == id }) { return false }
        state.profiles.removeAll { $0.id == id }; save(); return true
    }
    public func upsert(_ s: Source) {
        if let i = state.sources.firstIndex(where: { $0.id == s.id }) { state.sources[i] = s } else { state.sources.append(s) }
        save()
    }
    public func deleteSource(_ id: UUID) {
        state.sources.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: archiveURL(for: id))
        for k in [CatalogKind.videos, .playlists] { try? FileManager.default.removeItem(at: catalogURL(for: id, kind: k)) }
        save()
    }
    public func update(settings: Settings) { state.settings = settings; save() }
    public func mutateSettings(_ f: (inout Settings) -> Void) { f(&state.settings); save() }
    public func mutateSource(_ id: UUID, _ f: (inout Source) -> Void) {
        guard let i = state.sources.firstIndex(where: { $0.id == id }) else { return }
        f(&state.sources[i]); save()
    }
    public func append(_ r: DownloadRecord) {
        state.history.insert(r, at: 0)
        if state.history.count > 500 { state.history.removeLast(state.history.count - 500) }
        save()
    }

    public nonisolated func archiveURL(for id: UUID) -> URL {
        AppPaths.archives.appendingPathComponent("\(id.uuidString).txt")
    }

    // MARK: Catalogs (per-source listings, kept out of state.json because channels can have thousands of videos)

    public nonisolated func catalogURL(for id: UUID, kind: CatalogKind) -> URL {
        AppPaths.catalogs.appendingPathComponent("\(id.uuidString).\(kind.rawValue).json")
    }

    public func catalog(_ id: UUID, _ kind: CatalogKind) -> [CatalogEntry] {
        guard let data = try? Data(contentsOf: catalogURL(for: id, kind: kind)) else { return [] }
        return (try? JSONDecoder().decode([CatalogEntry].self, from: data)) ?? []
    }

    /// Saves a fresh scan, keeping the "downloaded" flag of entries we already knew about.
    public func saveCatalog(_ id: UUID, _ kind: CatalogKind, _ entries: [CatalogEntry]) {
        let had = Set(catalog(id, kind).filter(\.downloaded).map(\.id))
        let merged = entries.map { e -> CatalogEntry in var e = e; if had.contains(e.id) { e.downloaded = true }; return e }
        writeCatalog(id, kind, merged)
    }

    public func markDownloaded(_ id: UUID, ids: [String]) {
        guard !ids.isEmpty else { return }
        var entries = catalog(id, .videos)
        guard !entries.isEmpty else { return }
        let set = Set(ids)
        for i in entries.indices where set.contains(entries[i].id) { entries[i].downloaded = true; entries[i].isNew = nil }
        writeCatalog(id, .videos, entries)
    }

    /// Adds videos we haven't listed before to the front of the catalog, flagged as new. Returns just those.
    public func mergeNew(_ id: UUID, _ listed: [CatalogEntry]) -> [CatalogEntry] {
        let current = catalog(id, .videos)
        let known = Set(current.map(\.id))
        let fresh = listed.filter { !known.contains($0.id) }.map { e -> CatalogEntry in var e = e; e.isNew = true; return e }
        if !fresh.isEmpty { writeCatalog(id, .videos, fresh + current) }
        return fresh
    }

    /// Clears the "new" flag on every video of a source.
    public func clearNew(_ id: UUID) {
        var entries = catalog(id, .videos)
        guard entries.contains(where: { $0.isNew == true }) else { return }
        for i in entries.indices { entries[i].isNew = nil }
        writeCatalog(id, .videos, entries)
    }

    private func writeCatalog(_ id: UUID, _ kind: CatalogKind, _ entries: [CatalogEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: catalogURL(for: id, kind: kind), options: .atomic)
    }
}
