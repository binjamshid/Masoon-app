import MasoonDomain

/// The phone→watch payload: everything the wrist needs to render a day and act
/// on it, and nothing it could use to reach the backend (D-199).
///
/// The watch holds no auth token, no GRDB database and no device identity. It
/// cannot run `EventFold` — folding needs the plan's entire event history (pause
/// spans, policy and curriculum timelines) and task *instances* come from
/// generation, not from the fold. So the wrist renders a snapshot plus a pending
/// overlay:
///
/// ```
/// effective(row) = queue.hasPendingCompletion(row.taskUid, row.date)
///                ? .completed
///                : row.statusFromSnapshot
/// ```
///
/// It reuses `MasoonDomain.TaskStatus` — the enum only, which is free.
///
/// Every field below is load-bearing; see each doc comment for what goes wrong
/// without it.
public struct WatchDaySnapshot: Codable, Equatable, Sendable {

    /// Bumped when a field's *meaning* changes, not when one is added. Unknown
    /// keys decode away silently (Codable's default), so a newer phone build can
    /// always talk to an older watch build — the forward-compat case that
    /// matters, since the two update independently through the App Store.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int

    /// Never "the current plan": the ingestor routes per plan, and a learner can
    /// switch plans between a snapshot being sent and a completion coming back.
    public var planId: String

    /// The **plan's** IANA zone. The watch computes `today` and
    /// `occurred_at_local` from this, never from `TimeZone.current` — a learner
    /// travelling with the watch on their wrist would otherwise silently write
    /// events dated in the wrong day.
    public var planTimezone: String

    /// Per-sign-in UUID (`plan_meta` key `account_scope`). The ingestor drops
    /// records whose scope does not match the currently signed-in account, so a
    /// completion queued before a sign-out can never land in the next account's
    /// database. This is the isolation concern `PlanStore.deleteAllLocalData`'s
    /// own doc comment raises (App Store 5.1.1) — security, not just tidiness.
    public var accountScope: String

    /// Max local `plan_event.received_order` at generation time. Lets the
    /// ingestor recognise a wrist that has been offline across a supervisor
    /// override and quarantine rather than guess.
    public var planGeneration: Int64

    /// Written into the watch's own `masoon.locale` default: `DSLocale` reads
    /// `UserDefaults.standard`, which is a *different store on a different
    /// device*, so the wrist would otherwise fall back to system language and
    /// disagree with the phone about Arabic vs English.
    public var locale: String

    public var generatedAtUnixMillis: Int64

    /// Last plan-local date this snapshot may be presented as current, `YYYY-MM-DD`.
    /// Past it the watch renders "reconnect to update" rather than showing
    /// yesterday as today. **This is the most likely wrong-wrist bug** — a watch
    /// out of range of its phone overnight otherwise presents a stale day
    /// indistinguishable from a real one.
    public var validThroughISO: String

    /// Today first, then tomorrow. Two days is enough for a wrist and keeps the
    /// payload in single-digit KB, well inside WatchConnectivity's limits.
    public var days: [WatchDay]

    /// `event_id`s the phone has actually ingested into `plan_event`. The queue
    /// drops records only on this signal — `didFinish userInfoTransfer` proves
    /// delivery to the phone's WatchConnectivity daemon, not ingestion.
    public var ackedEventIds: [String]

    /// Set when the phone wants the wrist wiped (sign-out, account switch,
    /// erase-my-data). Clears snapshot **and** queue.
    public var wipe: Bool

    public init(
        schemaVersion: Int = WatchDaySnapshot.currentSchemaVersion,
        planId: String,
        planTimezone: String,
        accountScope: String,
        planGeneration: Int64,
        locale: String,
        generatedAtUnixMillis: Int64,
        validThroughISO: String,
        days: [WatchDay],
        ackedEventIds: [String] = [],
        wipe: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.planId = planId
        self.planTimezone = planTimezone
        self.accountScope = accountScope
        self.planGeneration = planGeneration
        self.locale = locale
        self.generatedAtUnixMillis = generatedAtUnixMillis
        self.validThroughISO = validThroughISO
        self.days = days
        self.ackedEventIds = ackedEventIds
        self.wipe = wipe
    }

    /// Decoding tolerates every field being absent except the identifiers, so an
    /// older watch build never hard-fails on a newer phone's payload.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        planId = try c.decode(String.self, forKey: .planId)
        planTimezone = try c.decodeIfPresent(String.self, forKey: .planTimezone) ?? "UTC"
        accountScope = try c.decodeIfPresent(String.self, forKey: .accountScope) ?? ""
        planGeneration = try c.decodeIfPresent(Int64.self, forKey: .planGeneration) ?? 0
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? "ar"
        generatedAtUnixMillis = try c.decodeIfPresent(Int64.self, forKey: .generatedAtUnixMillis) ?? 0
        validThroughISO = try c.decodeIfPresent(String.self, forKey: .validThroughISO) ?? ""
        days = try c.decodeIfPresent([WatchDay].self, forKey: .days) ?? []
        ackedEventIds = try c.decodeIfPresent([String].self, forKey: .ackedEventIds) ?? []
        wipe = try c.decodeIfPresent(Bool.self, forKey: .wipe) ?? false
    }

    /// True when `date` (plan-local today) is still inside the snapshot's
    /// validity. A snapshot with an unparseable `validThroughISO` is treated as
    /// stale — fail closed, never present an unknown day as current.
    public func isFresh(onPlanLocalDate date: LocalDate) -> Bool {
        guard let through = LocalDate(iso: validThroughISO) else { return false }
        return date <= through
    }

    public func day(on date: LocalDate) -> WatchDay? {
        days.first { $0.dateISO == date.isoString }
    }
}

/// One plan-local day of wrist-actionable work.
public struct WatchDay: Codable, Equatable, Sendable {
    /// `YYYY-MM-DD` in the plan timezone. Carried explicitly because a
    /// `task.completed` payload must key on it (D-032), never on receipt time.
    public var dateISO: String
    public var rows: [WatchTaskRow]

    public init(dateISO: String, rows: [WatchTaskRow]) {
        self.dateISO = dateISO
        self.rows = rows
    }

    public var date: LocalDate? { LocalDate(iso: dateISO) }
}

/// One task as the wrist sees it.
///
/// Display strings are formatted **on the phone** by `FeatureToday`'s own
/// formatters, so the watch never needs `QuranIndex`, the poem corpora, the
/// surah-name catalogue or any localization table — and the wrist can never
/// drift from what the phone shows for the same task.
public struct WatchTaskRow: Codable, Equatable, Sendable {
    public var taskUid: String
    /// Already-localized task label, e.g. the Today screen's own title.
    public var title: String
    /// Already-formatted range text ("الوحدات ٢–٥"), nil when the task has none.
    public var detail: String?
    /// `TaskStatus` raw value as the phone derived it. Unknown values decode to
    /// `.pending` rather than failing the whole snapshot.
    public var statusRaw: String
    public var evidence: WatchEvidenceKind
    /// From `TaskInstanceRow.target_repetitions` — never invented on the wrist.
    /// If the task supplies no repetition count
    /// the counter surface is simply not offered.
    public var targetRepetitions: Int?
    /// From `TaskInstanceRow.spacing_minutes`, same rule.
    public var spacingMinutes: Int?
    public var sessionId: String?

    public init(
        taskUid: String,
        title: String,
        detail: String? = nil,
        statusRaw: String,
        evidence: WatchEvidenceKind,
        targetRepetitions: Int? = nil,
        spacingMinutes: Int? = nil,
        sessionId: String? = nil
    ) {
        self.taskUid = taskUid
        self.title = title
        self.detail = detail
        self.statusRaw = statusRaw
        self.evidence = evidence
        self.targetRepetitions = targetRepetitions
        self.spacingMinutes = spacingMinutes
        self.sessionId = sessionId
    }

    public var status: TaskStatus { TaskStatus(rawValue: statusRaw) ?? .pending }

    /// The wrist offers completion only for work the learner does alone.
    /// Teacher-verified and form evidence stay on the phone by design — the
    /// watch has no way to run either, and silently downgrading them to a tap
    /// would forge assessment.
    public var isCompletableOnWrist: Bool {
        switch evidence {
        case .selfCheck, .counter, .timer: return true
        case .teacherVerification, .form, .unsupported: return false
        }
    }
}

/// The wrist-visible subset of `MasoonDomain.EvidenceSpec`.
///
/// Deliberately not `EvidenceSpec` itself: that enum is `indirect` with a
/// `composite` case, and a watch has no sane way to present a composite
/// requirement. The phone flattens to one of these and marks anything it cannot
/// reduce as `.unsupported`, which the wrist shows read-only.
public enum WatchEvidenceKind: Codable, Equatable, Sendable {
    case selfCheck
    case counter(target: Int)
    case timer(minSeconds: Int)
    case teacherVerification
    case form
    /// Anything the phone could not reduce — including `composite`.
    case unsupported

    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "unsupported"
        let value = try c.decodeIfPresent(Int.self, forKey: .value)
        switch kind {
        case "self_check": self = .selfCheck
        case "counter": self = .counter(target: value ?? 0)
        case "timer": self = .timer(minSeconds: value ?? 0)
        case "teacher_verification": self = .teacherVerification
        case "form": self = .form
        default: self = .unsupported  // forward-compat: a future kind is read-only, not fatal
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .selfCheck: try c.encode("self_check", forKey: .kind)
        case .counter(let t):
            try c.encode("counter", forKey: .kind)
            try c.encode(t, forKey: .value)
        case .timer(let s):
            try c.encode("timer", forKey: .kind)
            try c.encode(s, forKey: .value)
        case .teacherVerification: try c.encode("teacher_verification", forKey: .kind)
        case .form: try c.encode("form", forKey: .kind)
        case .unsupported: try c.encode("unsupported", forKey: .kind)
        }
    }

    /// Flattens an engine spec for the wrist. `composite` is not reduced — a
    /// learner must not be able to satisfy a two-part requirement with one tap.
    public init(spec: EvidenceSpec) {
        switch spec {
        case .selfCheck: self = .selfCheck
        case .counter(let target): self = .counter(target: target)
        case .timer(let minSeconds): self = .timer(minSeconds: minSeconds)
        case .teacherVerification: self = .teacherVerification
        case .form: self = .form
        case .composite: self = .unsupported
        }
    }
}
