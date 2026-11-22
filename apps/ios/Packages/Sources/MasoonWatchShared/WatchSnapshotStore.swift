import Foundation

/// The wrist's copy of the latest snapshot.
///
/// Latest-wins: the phone sends via `updateApplicationContext`, which coalesces,
/// so there is never a backlog of snapshots to reconcile — only the newest
/// matters. That is the right semantic for a daily view and the wrong one for
/// completions, which is why they travel the other way via `transferUserInfo`.
///
/// An `actor` for the same reason as `WatchQueueStore`: `WCSessionDelegate`
/// callbacks arrive off the main queue and strict concurrency is `minimal`, so
/// nothing else would catch a race here.
public actor WatchSnapshotStore {

    private let fileURL: URL
    private var cache: WatchDaySnapshot?
    private var didLoad = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The snapshot file in the supplied container or application support directory.
    public static func defaultFileURL(
        containerURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let base = containerURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("masoon-watch-snapshot.json")
    }

    public func current() -> WatchDaySnapshot? {
        if didLoad { return cache }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        cache = try? JSONDecoder().decode(WatchDaySnapshot.self, from: data)
        return cache
    }

    /// Stores unless the incoming snapshot is older than what we hold.
    /// `updateApplicationContext` is latest-wins but not strictly ordered on
    /// delivery, and presenting an older day after a newer one would be the
    /// stale-wrist bug by another route. Returns false when the write was
    /// skipped as stale.
    @discardableResult
    public func store(_ snapshot: WatchDaySnapshot) throws -> Bool {
        if let existing = current(),
           existing.planId == snapshot.planId,
           existing.generatedAtUnixMillis > snapshot.generatedAtUnixMillis {
            return false
        }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        cache = snapshot
        didLoad = true
        return true
    }

    public func clear() throws {
        try? FileManager.default.removeItem(at: fileURL)
        cache = nil
        didLoad = true
    }
}
