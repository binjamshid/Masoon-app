import MasoonDomain

/// One learner action taken on the wrist, waiting to reach the phone.
///
/// **This is not a `plan_event`.** It is a *request* to append one. The phone
/// re-stamps `device_id` and `client_seq` at ingestion
/// (`PlanStore.ingestWatchEvents`) because the watch must never hold a device
/// identity of its own — see D-199 for the full argument, but in short:
/// `validate.ts` enforces `client_seq` monotonicity across a whole push batch
/// with no device partitioning, `pendingPushBatches` orders by `received_order`
/// rather than by device, `OutboxPusher` rejects the *entire* batch on a
/// non-retryable verdict, and `rejected` is a terminal state. A single watch
/// event carrying a foreign `client_seq` would therefore permanently quarantine
/// up to 100 unrelated phone events, irrecoverably.
///
/// The fields that *do* survive ingestion verbatim are `eventId`, `type`,
/// `occurredAtLocal` and the payload. Those are the ones this type must get
/// right.
public struct WatchPendingEvent: Codable, Equatable, Sendable {

    /// UUIDv7 minted on the wrist. The one envelope field that survives
    /// ingestion, and therefore the sole idempotency key: delivery is
    /// at-least-once by design, so the phone inserts-or-ignores on this.
    public var eventId: String

    public var planId: String

    /// Copied from the snapshot this action was taken against. The ingestor
    /// drops the record if it no longer matches the signed-in account.
    public var accountScope: String

    /// The snapshot's `planGeneration`, for staleness diagnosis after an override.
    public var planGeneration: Int64

    /// `PlanEventType.taskCompleted` today; the field exists so the wrist can
    /// grow a second action without a schema change.
    public var type: String

    /// ISO-8601 **in the plan timezone**, produced by `LocalTimestamp.iso8601` —
    /// the same code the phone uses.
    ///
    /// The ingestor must never rewrite this. It is when the learner acted, and
    /// D-032 keys ledgers on it when `payload.date` is absent. A large skew is
    /// *supposed* to trip the server's `isTimeSuspect` check rather than be
    /// quietly corrected into a lie.
    public var occurredAtLocal: String

    /// `payload.date` — the task instance's plan-LocalDate (D-032). Carried
    /// separately from `occurredAtLocal` precisely because they can differ.
    public var dateISO: String

    public var taskUid: String

    public var evidence: WatchEvidence

    /// Per-wrist ordinal, stamped into `payload.watch_seq` purely as an audit
    /// trail. It is deliberately **not** a `client_seq` and never reaches the
    /// envelope.
    public var watchSeq: Int64

    /// Set when the action came from a notification whose `task_uid` was not in
    /// the current snapshot — reminders are scheduled 7 days ahead, so their
    /// `userInfo` can be a week stale. The wrist still queues (never lose the
    /// learner's action) and the ingestor re-validates.
    public var unverifiedContext: Bool

    public init(
        eventId: String,
        planId: String,
        accountScope: String,
        planGeneration: Int64,
        type: String,
        occurredAtLocal: String,
        dateISO: String,
        taskUid: String,
        evidence: WatchEvidence,
        watchSeq: Int64,
        unverifiedContext: Bool = false
    ) {
        self.eventId = eventId
        self.planId = planId
        self.accountScope = accountScope
        self.planGeneration = planGeneration
        self.type = type
        self.occurredAtLocal = occurredAtLocal
        self.dateISO = dateISO
        self.taskUid = taskUid
        self.evidence = evidence
        self.watchSeq = watchSeq
        self.unverifiedContext = unverifiedContext
    }

    public var date: LocalDate? { LocalDate(iso: dateISO) }
}

/// Evidence gathered on the wrist, in a `Codable` shape.
///
/// `JSONValue` is not `Codable` (it is a deterministic engine type, not a
/// serialization type), so the transfer format is this flat struct and
/// `jsonValue` converts it — through `MasoonDomain.EvidencePayloads`, the very
/// same functions the phone's Today screen calls. That is what guarantees a
/// wrist completion and a phone completion produce identical `evidence` objects
/// rather than two shapes that merely look alike.
public struct WatchEvidence: Codable, Equatable, Sendable {
    public var kind: String
    public var count: Int?
    public var increments: [String]?
    public var seconds: Int?

    public init(kind: String, count: Int? = nil, increments: [String]? = nil, seconds: Int? = nil) {
        self.kind = kind
        self.count = count
        self.increments = increments
        self.seconds = seconds
    }

    public static func selfCheck() -> WatchEvidence { WatchEvidence(kind: "self_check") }

    public static func counter(count: Int, increments: [String]) -> WatchEvidence {
        WatchEvidence(kind: "counter", count: count, increments: increments)
    }

    public static func timer(seconds: Int) -> WatchEvidence {
        WatchEvidence(kind: "timer", seconds: seconds)
    }

    /// The engine-facing payload. Falls back to `self_check` for an unrecognised
    /// kind rather than emitting a shape the fold has never seen.
    public var jsonValue: JSONValue {
        switch kind {
        case "counter":
            return EvidencePayloads.counter(count: count ?? 0, increments: increments ?? [])
        case "timer":
            return EvidencePayloads.timer(seconds: seconds ?? 0)
        default:
            return EvidencePayloads.selfCheck()
        }
    }
}
