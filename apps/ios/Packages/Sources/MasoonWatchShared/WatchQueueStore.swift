import Foundation

/// The wrist's durable outbox: append-only, FIFO, survives termination.
///
/// An `actor` deliberately. The project builds with
/// `SWIFT_STRICT_CONCURRENCY: minimal`, so Sendable violations in
/// `WCSessionDelegate` are **not** caught at compile time — and those callbacks
/// arrive off the main queue. Actor isolation is the only thing actually
/// serialising reads and writes here, so it has to be real rather than a
/// convention.
///
/// Records leave the queue on exactly one signal: the phone echoing their
/// `event_id` in a snapshot's `ackedEventIds`. `didFinish userInfoTransfer`
/// proves the payload reached the phone's WatchConnectivity daemon, which is not
/// the same as it reaching `plan_event` — the app may have been killed in
/// between. Trusting the transfer callback would lose completions.
public actor WatchQueueStore {

    /// Above this limit, the oldest records are evicted.
    public static let defaultCapacity = 500

    private let fileURL: URL
    private let capacity: Int
    private var cache: [WatchPendingEvent]?
    /// Monotonic per-wrist ordinal for `payload.watch_seq`. Audit only.
    private var nextSeq: Int64 = 0

    public init(fileURL: URL, capacity: Int = WatchQueueStore.defaultCapacity) {
        self.fileURL = fileURL
        self.capacity = capacity
    }

    /// The queue file in the supplied container or application support directory.
    public static func defaultFileURL(
        containerURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let base = containerURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("masoon-watch-queue.json")
    }

    // MARK: - Reads

    public func pending() -> [WatchPendingEvent] { load() }

    public func count() -> Int { load().count }

    /// Drives the pending overlay: a row the learner has completed on the wrist
    /// reads as `.completed` immediately, before the phone has seen anything.
    public func hasPendingCompletion(taskUid: String, dateISO: String) -> Bool {
        load().contains { $0.taskUid == taskUid && $0.dateISO == dateISO }
    }

    // MARK: - Writes

    /// Appends unless an identical `(taskUid, dateISO)` is already queued —
    /// double-taps on a small screen are common, and two completions for one
    /// task instance are noise the phone would have to reconcile.
    /// Returns the stored record, or nil when it was a duplicate.
    @discardableResult
    public func append(_ makeRecord: (Int64) -> WatchPendingEvent) throws -> WatchPendingEvent? {
        var records = load()
        let seq = nextSeq
        let record = makeRecord(seq)
        guard !records.contains(where: {
            $0.taskUid == record.taskUid && $0.dateISO == record.dateISO
        }) else { return nil }

        nextSeq = seq + 1
        records.append(record)
        if records.count > capacity { records.removeFirst(records.count - capacity) }
        try persist(records)
        return record
    }

    /// Removes exactly the acknowledged ids. Anything not named stays queued.
    public func acknowledge(eventIds: Set<String>) throws {
        guard !eventIds.isEmpty else { return }
        let records = load()
        let remaining = records.filter { !eventIds.contains($0.eventId) }
        guard remaining.count != records.count else { return }
        try persist(remaining)
    }

    /// Sign-out / account switch / erase-my-data. The queue is dropped whole:
    /// its records belong to an account that is no longer signed in, and the
    /// ingestor would refuse them anyway on `account_scope`.
    public func wipe() throws {
        try persist([])
    }

    // MARK: - Storage

    private func load() -> [WatchPendingEvent] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL) else {
            cache = []
            return []
        }
        // A truncated or half-written file decodes to nothing rather than
        // throwing into the UI. `persist` writes atomically so this should be
        // unreachable, but a wrist that loses its queue must still function.
        let records = (try? JSONDecoder().decode([WatchPendingEvent].self, from: data)) ?? []
        cache = records
        nextSeq = (records.map(\.watchSeq).max() ?? -1) + 1
        return records
    }

    private func persist(_ records: [WatchPendingEvent]) throws {
        let data = try JSONEncoder().encode(records)
        // `.atomic` writes to a temporary file and renames: a crash or a
        // watchdog kill mid-write leaves the previous queue intact rather than a
        // truncated file. The cache is updated only after the write succeeds.
        try data.write(to: fileURL, options: .atomic)
        cache = records
    }
}
