import Foundation

/// A repetition or timer session in progress on the wrist (D-199, Phase 2).
///
/// Persists counter or timer progress across backgrounding and app
/// termination. The final completion carries all recorded evidence.
public struct WatchEvidenceDraft: Codable, Equatable, Sendable {

    public var planId: String
    public var taskUid: String
    public var dateISO: String
    /// Target repetition count supplied by the task.
    public var target: Int
    /// Real "HH:mm" wall-clock tap times in the **plan's** zone, one per
    /// increment. These are evidence, not decoration.
    public var increments: [String]
    /// Elapsed seconds for a timer draft.
    public var seconds: Int
    public var kind: Kind

    public enum Kind: String, Codable, Sendable { case counter, timer }

    public init(
        planId: String,
        taskUid: String,
        dateISO: String,
        target: Int,
        increments: [String] = [],
        seconds: Int = 0,
        kind: Kind
    ) {
        self.planId = planId
        self.taskUid = taskUid
        self.dateISO = dateISO
        self.target = target
        self.increments = increments
        self.seconds = seconds
        self.kind = kind
    }

    public var count: Int { increments.count }

    /// Whether the learner has done what the task asks. Deliberately `>=`: a
    /// learner who taps a sixth time has not done something invalid, and the
    /// wrist must not silently discard it.
    public var isSatisfied: Bool {
        switch kind {
        case .counter: return count >= target
        case .timer: return seconds >= target
        }
    }

    /// The evidence to submit. Counter and timer drafts produce exactly the
    /// shapes `MasoonDomain.EvidencePayloads` defines, so a wrist session and a
    /// phone session are indistinguishable in the event log.
    public var evidence: WatchEvidence {
        switch kind {
        case .counter: return .counter(count: count, increments: increments)
        case .timer: return .timer(seconds: seconds)
        }
    }

    /// Records one repetition at `hhmm` (plan-local).
    public mutating func increment(at hhmm: String) {
        increments.append(hhmm)
    }
}

/// Durable storage for at most one in-flight draft.
///
/// One, not many: a learner is doing one thing at a time, and a wrist offering
/// several half-finished counters is a worse experience than one that asks them
/// to finish or abandon.
public actor WatchDraftStore {

    private let fileURL: URL
    private var cache: WatchEvidenceDraft?
    private var didLoad = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        containerURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let base = containerURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("masoon-watch-draft.json")
    }

    public func current() -> WatchEvidenceDraft? {
        if didLoad { return cache }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        cache = try? JSONDecoder().decode(WatchEvidenceDraft.self, from: data)
        return cache
    }

    /// Returns the draft for `(taskUid, dateISO)`, or nil if the stored draft is
    /// for something else — switching tasks must not inherit another task's count.
    public func current(taskUid: String, dateISO: String) -> WatchEvidenceDraft? {
        guard let draft = current(), draft.taskUid == taskUid, draft.dateISO == dateISO else {
            return nil
        }
        return draft
    }

    public func save(_ draft: WatchEvidenceDraft) throws {
        let data = try JSONEncoder().encode(draft)
        try data.write(to: fileURL, options: .atomic)
        cache = draft
        didLoad = true
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        cache = nil
        didLoad = true
    }
}
