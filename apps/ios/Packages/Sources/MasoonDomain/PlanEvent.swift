/// Append-only plan events (DOMAIN_MODEL §3). Events are the sync unit and the
/// single source of truth for plan state; task instances are derived cache.

public enum PlanEventType {
    public static let planCreated = "plan.created"
    public static let planActivated = "plan.activated"
    public static let planPaused = "plan.paused"
    public static let planResumed = "plan.resumed"
    public static let planPolicyChanged = "plan.policy_changed"
    public static let planCurriculumUpgraded = "plan.curriculum_upgraded"
    public static let planRecoveryApplied = "plan.recovery_applied"
    public static let planDayClosed = "plan.day_closed"
    public static let taskStarted = "task.started"
    public static let taskCompleted = "task.completed"
    public static let taskUncompleted = "task.uncompleted"
    public static let taskExcused = "task.excused"
    public static let assessmentLogged = "assessment.logged"
    public static let overrideApplied = "override.applied"
    public static let startingStateDeclared = "starting_state.declared"
    public static let startingStateAmended = "starting_state.amended"
    /// CB-22 (Batch 3 Stage 6, Track B): a WHOLE-PLAN supersession — fired on
    /// the OLD plan's own event log when a NEW plan is created for a corpus
    /// that already has an active one (D-085: `max_active_plans_per_corpus
    /// == 1`). Distinct from `planCurriculumUpgraded`, which is D-054's
    /// folded INTRA-plan curriculum switch (one plan row, timeline folds);
    /// this event instead marks that PLAN ROW ITSELF as retired — never
    /// deleted, never silently overwritten, permanently discoverable in its
    /// own history. Payload: `superseded_by_plan_id` (the new plan's id) +
    /// `reason` (free-text, UI-supplied). See `PlanSupersession.swift`.
    public static let planSuperseded = "plan.superseded"
}

public struct PlanEvent: Sendable, Equatable {
    public let eventId: String
    public let type: String
    /// Server-assigned canonical ordering; nil while local-unacked.
    public let serverSeq: Int64?
    public let deviceId: String
    /// Per-device monotonic sequence.
    public let clientSeq: Int64
    /// ISO8601 with offset, e.g. "2026-07-12T06:40:00+03:00".
    public let occurredAtLocal: String
    public let schemaVersion: Int
    public let actorRole: String?
    /// Set server-side when a supervisor override invalidated this event; the
    /// event is retained but folds as a state no-op (DOMAIN_MODEL I-2).
    public let supersededBy: String?
    public let payload: JSONValue

    public init(
        eventId: String,
        type: String,
        serverSeq: Int64?,
        deviceId: String,
        clientSeq: Int64,
        occurredAtLocal: String,
        schemaVersion: Int = 1,
        actorRole: String? = nil,
        supersededBy: String? = nil,
        payload: JSONValue = .object([:])
    ) {
        self.eventId = eventId
        self.type = type
        self.serverSeq = serverSeq
        self.deviceId = deviceId
        self.clientSeq = clientSeq
        self.occurredAtLocal = occurredAtLocal
        self.schemaVersion = schemaVersion
        self.actorRole = actorRole
        self.supersededBy = supersededBy
        self.payload = payload
    }

    public init?(json: JSONValue) {
        guard let obj = json.objectValue,
              let eventId = obj["event_id"]?.stringValue,
              let type = obj["type"]?.stringValue,
              let deviceId = obj["device_id"]?.stringValue,
              let clientSeq = obj["client_seq"]?.intValue,
              let occurredAt = obj["occurred_at_local"]?.stringValue
        else { return nil }
        self.init(
            eventId: eventId,
            type: type,
            serverSeq: obj["server_seq"]?.intValue.map(Int64.init),
            deviceId: deviceId,
            clientSeq: Int64(clientSeq),
            occurredAtLocal: occurredAt,
            schemaVersion: obj["schema_version"]?.intValue ?? 1,
            actorRole: obj["actor_role"]?.stringValue,
            supersededBy: obj["superseded_by"]?.stringValue,
            payload: obj["payload"] ?? .object([:])
        )
    }

    /// The plan-timezone local date this event occurred on.
    public var occurredOnLocalDate: LocalDate? {
        guard occurredAtLocal.count >= 10 else { return nil }
        return LocalDate(iso: String(occurredAtLocal.prefix(10)))
    }
}
