/// Deterministic event fold (ENGINE_SEMANTICS §9, DOMAIN_MODEL I-3).
///
/// Fold order: all acked events by `server_seq`, then local-unacked events by
/// `(device_id, client_seq)`. Superseded events fold as state no-ops but remain
/// available for history/status derivation.

public struct FoldedEvents: Equatable, Sendable {
    /// task_uid -> completion info for non-superseded, non-uncompleted completions.
    public var completions: [String: TaskCompletion] = [:]
    /// task_uids excused by teacher/supervisor.
    public var excused: Set<String> = []
    /// Policy patches in fold order: `plan.policy_changed` and `override.applied`
    /// both contribute `{effective_from, patch}` entries. Day D uses every entry
    /// with `effective_from <= D`, applied in fold order (ENGINE_SEMANTICS §9).
    public var policyTimeline: [PolicyPatch] = []
    /// Curriculum-switch timeline, folded from `plan.curriculum_upgraded`
    /// (D-054): append-only in fold order, one entry per well-formed event.
    /// Day D resolves to the entry with the greatest `effectiveFrom <= D`
    /// (ties broken by fold order — the later fold wins, mirroring how a
    /// later `policyTimeline` entry at the same date wins); `baseCurriculum`
    /// applies before the earliest entry or when the timeline is empty
    /// (every fixture today: Batch 3 Stage 3, PC-4).
    public var curriculumTimeline: [CurriculumChange] = []
    /// Closed/open pause spans: generation emits nothing on a date inside
    /// `[pausedFrom, resumeAnchor)`; an open span pauses through the end.
    public var pauseSpans: [PauseSpan] = []
    /// Dates on which `plan.recovery_applied` folded (redistribute activation).
    public var recoveryApplications: [RecoveryApplication] = []
    /// Latest `starting_state.declared/amended` payload, if any.
    public var startingStateOverride: JSONValue? = nil
    /// Explicit status transitions observed (activation only; completed is derived).
    public var activated: Bool = false

    public struct TaskCompletion: Equatable, Sendable {
        public let eventId: String
        public let teacherVerified: Bool
        /// D-032: the task instance's plan-LocalDate from `payload.date`,
        /// falling back to the local-date part of `occurred_at_local` (which is
        /// when the actor acted and may differ under D-021 backdating).
        /// Ledgers key on this, never on receipt time.
        public let date: LocalDate?
        public init(eventId: String, teacherVerified: Bool, date: LocalDate?) {
            self.eventId = eventId
            self.teacherVerified = teacherVerified
            self.date = date
        }
    }

    public struct PolicyPatch: Equatable, Sendable {
        /// nil = effective from the beginning of the plan (D-032(5):
        /// `override.applied` without `effective_from` is never silently narrowed).
        public let effectiveFrom: LocalDate?
        public let patch: JSONValue
        public let isOverride: Bool
        public init(effectiveFrom: LocalDate?, patch: JSONValue, isOverride: Bool) {
            self.effectiveFrom = effectiveFrom
            self.patch = patch
            self.isOverride = isOverride
        }
        public func isEffective(on date: LocalDate) -> Bool {
            guard let from = effectiveFrom else { return true }
            return from <= date
        }
    }

    public struct PauseSpan: Equatable, Sendable {
        public let from: LocalDate
        /// First generating date after the pause (`plan.resumed` anchor); nil = still paused.
        public let resumeAnchor: LocalDate?
        public init(from: LocalDate, resumeAnchor: LocalDate?) {
            self.from = from
            self.resumeAnchor = resumeAnchor
        }
        public func contains(_ date: LocalDate) -> Bool {
            if date < from { return false }
            if let anchor = resumeAnchor { return date < anchor }
            return true
        }
    }

    public struct RecoveryApplication: Equatable, Sendable {
        public let date: LocalDate
        public init(date: LocalDate) { self.date = date }
    }

    /// One `plan.curriculum_upgraded` fold (D-054): the plan switches to
    /// `slug@version` from `effectiveFrom` (inclusive) onward.
    public struct CurriculumChange: Equatable, Sendable {
        public let effectiveFrom: LocalDate
        public let slug: String
        /// Empty string when the event omits `version` — never fatal; PC-4's
        /// `EngineRun.cur(_:)` falls back to `baseCurriculum` when the
        /// resulting "slug@version" key has no `CurriculumSet.byKey` entry.
        public let version: String
        public init(effectiveFrom: LocalDate, slug: String, version: String) {
            self.effectiveFrom = effectiveFrom
            self.slug = slug
            self.version = version
        }
    }

    public init() {}

    public func isPaused(on date: LocalDate) -> Bool {
        pauseSpans.contains { $0.contains(date) }
    }
}

public enum EventFold {
    /// Total fold order (I-3): acked by server_seq, then unacked by (device_id, client_seq).
    public static func foldOrder(_ events: [PlanEvent]) -> [PlanEvent] {
        let acked = events.filter { $0.serverSeq != nil }.sorted { $0.serverSeq! < $1.serverSeq! }
        let unacked = events.filter { $0.serverSeq == nil }.sorted {
            if $0.deviceId != $1.deviceId { return $0.deviceId < $1.deviceId }
            return $0.clientSeq < $1.clientSeq
        }
        return acked + unacked
    }

    public static func fold(_ events: [PlanEvent]) -> FoldedEvents {
        var state = FoldedEvents()
        var openPauseFrom: LocalDate? = nil

        for event in foldOrder(events) {
            // Superseded events fold as no-ops for state (DOMAIN_MODEL I-2).
            if event.supersededBy != nil { continue }

            // D-032: task.* events key on payload.date, falling back to the
            // local-date part of occurred_at_local for legacy events.
            let taskDate = event.payload["date"]?.stringValue.flatMap(LocalDate.init(iso:))
                ?? event.occurredOnLocalDate

            switch event.type {
            case PlanEventType.taskCompleted:
                guard let uid = event.payload["task_uid"]?.stringValue else { continue }
                // E-4b (D-046): a completion counts as VERIFIED when the evidence
                // is a teacher verification OR the payload carries an explicit
                // `verified: true` (a teacher accepting other evidence kinds —
                // e.g. marking a counter-evidenced sabaq maqbūl). Aligned with the
                // TS and Kotlin folds; Swift previously honored only the former.
                let verified = event.payload["evidence"]?["kind"]?.stringValue == "teacher_verification"
                    || event.payload["verified"]?.boolValue == true
                    // A named listener's attestation records verification
                    // separately from teacher verification.
                    || event.payload["evidence"]?["verified"]?.boolValue == true
                state.completions[uid] = FoldedEvents.TaskCompletion(
                    eventId: event.eventId, teacherVerified: verified, date: taskDate)

            case PlanEventType.taskUncompleted:
                guard let uid = event.payload["task_uid"]?.stringValue else { continue }
                state.completions.removeValue(forKey: uid)

            case PlanEventType.taskExcused:
                guard let uid = event.payload["task_uid"]?.stringValue else { continue }
                state.excused.insert(uid)

            case PlanEventType.planPolicyChanged, PlanEventType.overrideApplied:
                guard let patch = event.payload["patch"] else { continue }
                let from = event.payload["effective_from"]?.stringValue.flatMap(LocalDate.init(iso:))
                let isOverride = event.type == PlanEventType.overrideApplied
                if from == nil && !isOverride { continue }  // policy_changed requires effective_from
                // D-032(5): override.applied without effective_from is
                // effective from the beginning of the plan.
                state.policyTimeline.append(FoldedEvents.PolicyPatch(
                    effectiveFrom: from, patch: patch, isOverride: isOverride))

            case PlanEventType.planCurriculumUpgraded:
                // D-054: missing `slug` or an unparseable `effective_from` is a
                // deterministic no-op (I-4 house style — same pattern as
                // `plan.policy_changed` without `effective_from` above): skip
                // the whole event, including any bundled `policy_patch`, and
                // leave both timelines exactly as they were.
                guard let slug = event.payload["slug"]?.stringValue,
                      let from = event.payload["effective_from"]?.stringValue.flatMap(LocalDate.init(iso:))
                else { continue }
                let version = event.payload["version"]?.stringValue ?? ""
                state.curriculumTimeline.append(FoldedEvents.CurriculumChange(
                    effectiveFrom: from, slug: slug, version: version))
                // A bundled `policy_patch` rides the SAME effective_from date
                // into the existing policy timeline (not a supervisor
                // override — `isOverride: false`), reusing the identical
                // append the plan.policy_changed/override.applied case uses.
                if let patch = event.payload["policy_patch"] {
                    state.policyTimeline.append(FoldedEvents.PolicyPatch(
                        effectiveFrom: from, patch: patch, isOverride: false))
                }

            case PlanEventType.planPaused:
                if openPauseFrom == nil {
                    openPauseFrom = event.payload["effective_from"]?.stringValue.flatMap(LocalDate.init(iso:))
                        ?? event.occurredOnLocalDate
                }

            case PlanEventType.planResumed:
                if let from = openPauseFrom {
                    let anchor = event.payload["anchor"]?.stringValue.flatMap(LocalDate.init(iso:))
                        ?? event.occurredOnLocalDate
                    state.pauseSpans.append(FoldedEvents.PauseSpan(from: from, resumeAnchor: anchor))
                    openPauseFrom = nil
                }

            case PlanEventType.planRecoveryApplied:
                let date = event.payload["effective_from"]?.stringValue.flatMap(LocalDate.init(iso:))
                    ?? event.occurredOnLocalDate
                if let d = date {
                    state.recoveryApplications.append(FoldedEvents.RecoveryApplication(date: d))
                }

            case PlanEventType.startingStateDeclared, PlanEventType.startingStateAmended:
                state.startingStateOverride = event.payload

            case PlanEventType.planActivated:
                state.activated = true

            default:
                // Unknown types are preserved opaquely (I-4); no state effect here.
                continue
            }
        }

        if let from = openPauseFrom {
            state.pauseSpans.append(FoldedEvents.PauseSpan(from: from, resumeAnchor: nil))
        }
        return state
    }
}

// MARK: - Task status derivation (DOMAIN_MODEL §3 invariants)

public enum TaskStatus: String, Sendable {
    case pending, completed, verified, missed, excused, superseded
}

public enum TaskStatusDerivation {
    /// Status is derived, never stored as truth:
    /// completed ⟺ a non-superseded `task.completed` exists; verified adds
    /// teacher verification; missed ⟺ deadline < today ∧ no completion ∧ not
    /// excused, where deadline is `window.closesOn` when the task carries an
    /// engine-emitted submission window (e.g. the tasmeeʿ window — v1 audit
    /// 6.11), else the task's own `date`.
    ///
    /// Supply the submission window for tasks whose due date differs
    /// from their scheduled date.
    public static func status(
        taskUid: String,
        date: LocalDate,
        today: LocalDate,
        folded: FoldedEvents,
        window: (opensOn: LocalDate, closesOn: LocalDate)? = nil
    ) -> TaskStatus {
        if let completion = folded.completions[taskUid] {
            return completion.teacherVerified ? .verified : .completed
        }
        if folded.excused.contains(taskUid) { return .excused }
        let deadline = window?.closesOn ?? date
        if deadline < today { return .missed }
        return .pending
    }
}
