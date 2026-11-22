import MasoonDomain

/// The deterministic day generator (ENGINE_SEMANTICS §2–§10).
///
/// `generate(context:window:)` simulates the plan forward from its anchor date
/// through the end of the window: dates ≤ `today` fold actual events; dates
/// after `today` run in projection mode (every emitted content task is assumed
/// complete; cursor, rotation and ledgers advance accordingly).

public struct TaskInstance: Sendable {
    public let date: LocalDate
    public let dayClass: String
    public let session: String
    public let ordering: Int
    public let type: String
    public let originRuleId: String
    public let occurrence: Int
    public let content: [CanonicalRange]
    public let repetitions: Int?
    public let spacingMinutes: Int?
    public let listenCount: Int?
    public let window: (opensOn: LocalDate, closesOn: LocalDate)?
    public let estimatedMinutes: Int
    /// nil for info_only tasks (§11.5: empty evidence field).
    public let evidence: EvidenceSpec?
    public let flags: [String]
    public let taskUid: String
}

public enum PlanStatus: String, Sendable {
    case awaitingStartState = "awaiting_start_state"
    case active, paused, completed, superseded
}

public struct FinalPlanState: Sendable {
    public let cursor: CanonicalPosition?
    public let juzCompleted: Int
    public let cycleWeeks: Int
    public let debtNewRanges: Int
    public let status: PlanStatus
}

/// PC-5 (D-054 hard-boundary sweep) introspection record: what got dropped
/// at a curriculum switch's `effective_from` date. Swift-only and
/// UNSERIALIZED — `StreamSerializer` never reads `GenerationResult`'s
/// `droppedAtBoundary`, so it never appears in `expected.stream` output and
/// is exempt from cross-platform parity (Kotlin/TS never need to produce
/// it, now or in a later stage).
public struct BoundaryDrop: Sendable {
    public let date: LocalDate
    public let fromSlug: String
    public let toSlug: String
    public let consolidationWeeksDropped: Int
    public let distributionSlicesDropped: Int
    public let scheduledJuzReviewsDropped: Int
    public let rotationCursorsDropped: Int
}

public struct GenerationResult: Sendable {
    public let tasks: [TaskInstance]
    public let finalState: FinalPlanState
    /// PC-5: always empty for every fixture today (no fixture declares
    /// `plan.curriculum_upgraded`) — see `BoundaryDrop`.
    public let droppedAtBoundary: [BoundaryDrop]
}

public enum EngineError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        if case .invalid(let m) = self { return "engine error: \(m)" }
        return "engine error"
    }
}

public enum Engine {
    /// Public entry point: still takes the existential `context.quranIndex`
    /// (`any ContentIndex`, see GenerationContext.swift). SE-0352 implicit
    /// existential opening resolves it to a concrete `Index` at the call
    /// below, so the 400-day simulation loop inside `EngineRun<Index>`
    /// dispatches statically instead of through the protocol witness table.
    public static func generate(context: PlanGenerationContext, window: GenerationWindow) throws -> GenerationResult {
        try generate(context: context, index: context.quranIndex, window: window)
    }

    static func generate<Index: ContentIndex>(
        context: PlanGenerationContext, index: Index, window: GenerationWindow
    ) throws -> GenerationResult {
        var run = try EngineRun<Index>(context: context, index: index)
        return try run.generate(window: window).result
    }

    // MARK: - WP-06 incremental generation (v1 audit 3.1)

    /// `EngineCheckpointTests` exercises cold, mismatched-fingerprint,
    /// same-day, and 60-day chained restores against a fresh full replay on
    /// the exact same event log. The historical chained-restore failure was a
    /// test-harness defect: its final incremental result preceded the last
    /// appended completion while its fresh replay included that completion.
    /// The corrected test compares every intermediate call and performs one
    /// final incremental regenerate after the last append.
    ///
    /// Original design intent, preserved: incremental sibling of
    /// `generate(context:window:)`, for `PlanStore`'s hot write-transaction
    /// path only (`Regenerator` — every task completion, uncompletion,
    /// policy change, and day close replayed the WHOLE plan from its anchor
    /// date on every single mutation; v1 audit finding 3.1). The emitted
    /// `GenerationResult` is meant to be byte-identical to
    /// `generate(context:window:)` for the same `context`/`window`,
    /// checkpoint or no checkpoint. Every other caller (Forecaster,
    /// FixtureRunner, PlannerQueries, InsightsQueries, tests, ...) keeps
    /// calling the plain `generate(context:window:)` above, completely
    /// unmodified — this is purely additive and safe to leave compiled-but-
    /// unused.
    ///
    /// `fingerprint` is an opaque, caller-supplied identity string covering
    /// everything about the plan + its current event log that can change
    /// engine OUTPUT (`Regenerator` builds it from the plan row's immutable
    /// columns); a `resumingFrom` checkpoint captured under a DIFFERENT
    /// fingerprint, or whose captured concrete `Index` type does not match
    /// this call's, is never restored — that part of the contract (a stale/
    /// mismatched checkpoint falls back to a full replay rather than
    /// producing a wrong answer) held up under testing; the bug above is
    /// specifically in what happens when a checkpoint DOES match and IS
    /// restored, repeatedly, across many days.
    public static func generateIncremental(
        context: PlanGenerationContext, window: GenerationWindow,
        fingerprint: String, resumingFrom checkpoint: EngineCheckpoint?
    ) throws -> (result: GenerationResult, checkpoint: EngineCheckpoint?) {
        try generateIncremental(
            context: context, index: context.quranIndex, window: window,
            fingerprint: fingerprint, resumingFrom: checkpoint)
    }

    static func generateIncremental<Index: ContentIndex>(
        context: PlanGenerationContext, index: Index, window: GenerationWindow,
        fingerprint: String, resumingFrom checkpoint: EngineCheckpoint?
    ) throws -> (result: GenerationResult, checkpoint: EngineCheckpoint?) {
        var run = try EngineRun<Index>(context: context, index: index)
        let resume: EngineRun<Index>.Checkpoint?
        if let checkpoint, checkpoint.fingerprint == fingerprint,
           let inner = checkpoint.payload as? EngineRun<Index>.Checkpoint {
            resume = inner
        } else {
            resume = nil
        }
        let (result, newInner) = try run.generate(window: window, resumingFrom: resume)
        let newCheckpoint = newInner.map { EngineCheckpoint(fingerprint: fingerprint, payload: $0) }
        return (result, newCheckpoint)
    }
}

/// WP-06 (v1 audit 3.1) — part of the currently-DISABLED incremental path;
/// Opaque handle around a captured `EngineRun<Index>.Checkpoint`, returned by
/// `Engine.generateIncremental` and handed back on a later call for the SAME
/// plan. Callers (`Regenerator`, once re-enabled) never introspect this
/// value — they hold it (keyed by plan id) and pass it straight back in. A
/// checkpoint whose captured concrete `Index` type or `fingerprint`
/// mismatches the current call is silently ignored by `generateIncremental`,
/// which then falls back to a full replay from `anchor`.
public struct EngineCheckpoint {
    let fingerprint: String
    let payload: Any
}

// MARK: - Internal simulation

/// Corpus-generic per-generation state machine (Batch 3 Stage 2). `Index` is
/// resolved once at `Engine.generate`'s public boundary (today always
/// `QuranIndex`; `PoemIndex` proves the same machine type-checks and runs for
/// a structurally different corpus — MasoonDomainTests/PoemIndexTests.swift).
struct EngineRun<Index: ContentIndex> {
    let context: PlanGenerationContext
    let index: Index
    /// Batch 3 Stage 3 (PC-4/D-054): was `curriculum`, unconditionally read
    /// everywhere. Renamed so every remaining bare `curriculum` identifier in
    /// this file is a deliberate per-date local (see `cur(_:)` below and the
    /// `simulateDay` shadow-bind) rather than an accidental base-curriculum
    /// read once a plan can carry more than one curriculum active over time.
    let baseCurriculum: CompiledCurriculum
    let folded: FoldedEvents
    let order: MemorizationOrder<Index>
    let anchor: LocalDate
    let today: LocalDate

    // Static per-plan tables (from base policy + starting state).
    let targetSet: OrderSpanSet?          // nil = whole order domain
    let declaredOrderSet: OrderSpanSet
    let declaredGlobalSet: OrderSpanSet
    let strengthScaledOfGlobal: [Int64]   // 1000 / 1200 / 1500
    let weakGlobalSet: OrderSpanSet
    let uniformUnitMicropages: Int64?

    // Mutable simulation state.
    var cursorPos: Int                    // order position of next new ḥifẓ
    var completedOrderSet = OrderSpanSet()
    var completedGlobalSet = OrderSpanSet()
    var ledger: [LocalDate: OrderSpanSet] = [:]
    var firedJuz: Set<Int> = []
    var firedJuzSequence: [Int] = []
    var juzCompletedCount = 0
    // E-1 (D-038): each murājaʿah layer (rule) keeps its own rotation cursor,
    // keyed by rule id, so multiple layers over different pools coexist.
    var rotationCursors: [String: Int] = [:]
    var scheduledJuzReviews: [LocalDate: [ScheduledTask]] = [:]
    var distributions: [Distribution] = []
    var consolidationWeeks: [ConsolidationWeek] = []
    var cycleWeeksScheduled = 0
    /// D-049: lost advancement slots. Each is ONE closed day that owed new ḥifẓ
    /// and did not pass, carrying the µp it owed. `owedMp` is fixed when the slot
    /// is lost and discharged ONLY by catch-up work (redistribute extras) — NOT
    /// by completing the content later, which is just doing that day's work a day
    /// late: you are still a slot behind.
    var debtMissedNew: [(date: LocalDate, span: OrderSpanSet, owedMp: Int64)] = []
    var planCompleted = false
    var redistribution: Redistribution? = nil
    /// PC-5: accumulated hard-boundary sweep records (introspection only,
    /// never serialized). Always empty for every fixture today.
    var droppedAtBoundary: [BoundaryDrop] = []

    /// One-shot trigger-scheduled task (§11.2): origin = "{trigger_id}.{type}",
    /// ordering = 90 + schedule-effect index within the trigger.
    struct ScheduledTask {
        let content: OrderSpanSet
        let type: String
        let originRuleId: String
        let ordering: Int
        let session: String
        /// CB-2: mirrors `RuleEmit.estMinutes` for trigger-scheduled tasks
        /// (`ScheduleEffect.estMinutes`, schema). `nil` for every built-in.
        let estMinutesOverride: Int?
    }

    struct Distribution {
        /// slice index -> content (may be empty; empty slices emit nothing)
        let slices: [OrderSpanSet]
        /// calendar dates, one per slice; exception/paused/already-occupied
        /// days skipped at scheduling time (§11.11)
        let dates: [LocalDate]
        let type: String
        let originRuleId: String
        let ordering: Int
        let session: String
        /// CB-2: mirrors `RuleEmit.estMinutes` for distributed-slice tasks
        /// (`ScheduleEffect.estMinutes`, schema). `nil` for every built-in.
        let estMinutesOverride: Int?
    }

    struct ConsolidationWeek {
        let start: LocalDate   // week_start day
        let end: LocalDate     // start + 6
        let mode: String       // pause_new | parallel
        let triggerId: String
        let dayRules: [RuleSpec]
        let blockJuz: [Int]    // block juz in memorization-order sequence
        /// D-048: was this week inserted because the learner FAILED something
        /// (a `task_failed` trigger), rather than by the curriculum's own
        /// design (a juzʾ boundary)? A failure week costs advancement slots
        /// the learner did not choose to give up, so those slots owe debt; a
        /// planned one does not. Batch 3 Stage 3 (PC-4): computed ONCE at
        /// insertion time from the `TriggerSpec` that's already in hand
        /// there (`applyTriggerEffects`'s `trigger` parameter), replacing the
        /// old `isFailureWeek(_:)` re-lookup — a pure internal refactor, same
        /// result, no curriculum lookup needed at read time.
        let isFailure: Bool
        func contains(_ d: LocalDate) -> Bool { d >= start && d <= end }
    }

    struct Redistribution {
        var remainingMicropages: Int64
        var daysLeft: Int
        let maxExtraMicropages: Int64?
    }

    struct PendingEmission {
        let sessionRank: Int
        let session: String
        let ordering: Int
        let type: String
        let originRuleId: String
        let content: OrderSpanSet
        let repetitions: Int?
        let spacingMinutes: Int?
        let listenCount: Int?
        let window: (opensOn: LocalDate, closesOn: LocalDate)?
        let infoOnly: Bool
        let extraFlags: [String]
        /// CB-2: authored `est_minutes` override (`RuleEmit`/`ScheduleEffect`),
        /// checked FIRST by `estimateMinutes`. `nil` for every built-in.
        let estMinutesOverride: Int?
    }

    // MARK: - WP-06 checkpointing (v1 audit 3.1)

    /// Snapshot of every simulation-mutable field above, captured at the end
    /// of day `date` (inclusive) — everything `simulateDay`/
    /// `fireBoundaryTriggers`/`applyTriggerEffects` mutate. Restoring one and
    /// resuming simulation at `date + 1` MUST produce output byte-identical
    /// to a full replay from `anchor` — see
    /// `EngineCheckpointTests.testDayByDayIncrementalReplayMatchesFreshFullReplay`.
    ///
    /// Deliberately carries NO reference to `context`/`index`/`order`/the
    /// static per-plan tables `init` computes (`targetSet`,
    /// `declaredOrderSet`, `strengthScaledOfGlobal`, ...): those are wholly
    /// determined by the plan's immutable anchor/policy/starting-state/
    /// curriculum and are always freshly recomputed by `EngineRun.init`
    /// before a checkpoint is ever restored — a checkpoint is a CACHE of
    /// mutable simulation progress. The rules remain authoritative.
    struct Checkpoint {
        let date: LocalDate
        let cursorPos: Int
        let completedOrderSet: OrderSpanSet
        let completedGlobalSet: OrderSpanSet
        let ledger: [LocalDate: OrderSpanSet]
        let firedJuz: Set<Int>
        let firedJuzSequence: [Int]
        let juzCompletedCount: Int
        let rotationCursors: [String: Int]
        let scheduledJuzReviews: [LocalDate: [ScheduledTask]]
        let distributions: [Distribution]
        let consolidationWeeks: [ConsolidationWeek]
        let cycleWeeksScheduled: Int
        let debtMissedNew: [(date: LocalDate, span: OrderSpanSet, owedMp: Int64)]
        let planCompleted: Bool
        let redistribution: Redistribution?
        let droppedAtBoundary: [BoundaryDrop]
    }

    /// Captures every mutable field as of right now, tagged `date`. Callers
    /// must only invoke this once `date`'s `simulateDay` has fully run (see
    /// `generate(window:resumingFrom:)`).
    func checkpoint(at date: LocalDate) -> Checkpoint {
        Checkpoint(
            date: date, cursorPos: cursorPos, completedOrderSet: completedOrderSet,
            completedGlobalSet: completedGlobalSet, ledger: ledger, firedJuz: firedJuz,
            firedJuzSequence: firedJuzSequence, juzCompletedCount: juzCompletedCount,
            rotationCursors: rotationCursors, scheduledJuzReviews: scheduledJuzReviews,
            distributions: distributions, consolidationWeeks: consolidationWeeks,
            cycleWeeksScheduled: cycleWeeksScheduled, debtMissedNew: debtMissedNew,
            planCompleted: planCompleted, redistribution: redistribution,
            droppedAtBoundary: droppedAtBoundary)
    }

    /// Overwrites every mutable field with a previously-captured checkpoint's
    /// values. Only ever called from `generate(window:resumingFrom:)`,
    /// immediately after `init`, before any day is simulated.
    mutating func restore(_ checkpoint: Checkpoint) {
        cursorPos = checkpoint.cursorPos
        completedOrderSet = checkpoint.completedOrderSet
        completedGlobalSet = checkpoint.completedGlobalSet
        ledger = checkpoint.ledger
        firedJuz = checkpoint.firedJuz
        firedJuzSequence = checkpoint.firedJuzSequence
        juzCompletedCount = checkpoint.juzCompletedCount
        rotationCursors = checkpoint.rotationCursors
        scheduledJuzReviews = checkpoint.scheduledJuzReviews
        distributions = checkpoint.distributions
        consolidationWeeks = checkpoint.consolidationWeeks
        cycleWeeksScheduled = checkpoint.cycleWeeksScheduled
        debtMissedNew = checkpoint.debtMissedNew
        planCompleted = checkpoint.planCompleted
        redistribution = checkpoint.redistribution
        droppedAtBoundary = checkpoint.droppedAtBoundary
    }

    init(context: PlanGenerationContext, index: Index) throws {
        self.context = context
        self.index = index
        self.baseCurriculum = context.curriculumSet.base
        self.folded = EventFold.fold(context.events)
        self.anchor = context.calendar.anchorDate
        self.today = context.today
        self.order = try MemorizationOrder(kind: context.policy.memorizationOrder, index: index)
        if index.totalUnits > 0 {
            let first = index.weight(ofGlobal: 0)
            self.uniformUnitMicropages = (1..<index.totalUnits).allSatisfy {
                index.weight(ofGlobal: $0) == first
            } ? first : nil
        } else {
            self.uniformUnitMicropages = nil
        }

        // Placement cursor -> order position.
        guard let cursorGlobal = index.globalIndex(of: context.startingState.placementCursor),
              let cursorPosition = order.orderPosition(ofGlobal: cursorGlobal)
        else {
            throw EngineError.invalid("placement_cursor \(context.startingState.placementCursor) is not in the memorization order domain")
        }
        self.cursorPos = cursorPosition

        // Target set in order space (nil = everything).
        switch context.policy.targetRange {
        case .fullQuran:
            self.targetSet = nil
        case .ranges(let ranges):
            var set = OrderSpanSet()
            for range in ranges {
                guard let globals = index.globalRange(of: range) else {
                    throw EngineError.invalid("target range \(range) out of bounds")
                }
                for g in globals {
                    if let p = order.orderPosition(ofGlobal: g) { set.insert(p..<(p + 1)) }
                }
            }
            self.targetSet = set
        }

        // Declared prior ḥifẓ (murājaʿah pool seed; never fires triggers, D-016/§5).
        var declaredOrder = OrderSpanSet()
        var declaredGlobal = OrderSpanSet()
        var weakGlobal = OrderSpanSet()
        var strengths = [Int64](repeating: 1000, count: index.totalUnits)
        for declared in context.startingState.memorizedRanges {
            guard let globals = index.globalRange(of: declared.range) else {
                throw EngineError.invalid("declared range \(declared.range) out of bounds")
            }
            declaredGlobal.insert(globals)
            for g in globals {
                strengths[g] = max(strengths[g], declared.strength.scaledFactor)
                if let p = order.orderPosition(ofGlobal: g) { declaredOrder.insert(p..<(p + 1)) }
            }
            if declared.strength == .weak {
                for g in globals {
                    if let p = order.orderPosition(ofGlobal: g) { weakGlobal.insert(p..<(p + 1)) }
                }
            }
        }
        self.declaredOrderSet = declaredOrder
        self.declaredGlobalSet = declaredGlobal
        self.weakGlobalSet = weakGlobal
        self.strengthScaledOfGlobal = strengths
    }

    // MARK: weights

    func weightOfOrderPos(_ p: Int) -> Int64 {
        index.weight(ofGlobal: order.orderToGlobal[p])
    }

    func strengthOfOrderPos(_ p: Int) -> Int64 {
        strengthScaledOfGlobal[order.orderToGlobal[p]]
    }

    /// Weak-boost slicing weight (D-012/D-029): weak ayahs count at weight/boost
    /// (integer division) for rotation slicing while keeping full weight for
    /// workload estimates.
    func slicingWeightOfOrderPos(_ p: Int, weakBoost: Int64) -> Int64 {
        let w = weightOfOrderPos(p)
        if weakBoost > 1, weakGlobalSet.contains(p) { return w / weakBoost }
        return w
    }

    // MARK: curriculum & policy per date

    /// PC-4 (D-054): the curriculum active on `date`, resolved from the
    /// context's `CurriculumSet` + this run's folded `curriculumTimeline`
    /// (PC-1). Before the earliest `effective_from`, or when the timeline is
    /// empty (every one of the 19 existing fixtures — no fixture declares a
    /// `plan.curriculum_upgraded` event), this is exactly `baseCurriculum` on
    /// every date. A timeline entry naming a `slug@version` absent from
    /// `context.curriculumSet.byKey` falls back to `baseCurriculum` rather
    /// than crashing (see `CurriculumSet.resolve(on:timeline:)`).
    func cur(_ date: LocalDate) -> CompiledCurriculum {
        context.curriculumSet.resolve(on: date, timeline: folded.curriculumTimeline)
    }

    /// PC-5 (D-054 hard-boundary sweep): the 15 built-in curricula have
    /// near-disjoint session/day-class vocabularies, so scheduled machinery
    /// carried across a curriculum switch would silently emit nothing or
    /// misclassify under the NEW curriculum's names. At a switch's
    /// `effective_from` date, drop every consolidation week, distribution
    /// slice, and scheduled juz review still relevant on/after that date,
    /// and reset every murājaʿah rotation cursor (a new curriculum's rule
    /// ids generally name different pools, so a stale position is
    /// meaningless even on the rare id collision). Cursor, ledger and debt
    /// are untouched, exactly as D-054 specifies.
    ///
    /// Called from `simulateDay` BEFORE `consWeek` is resolved, so the sweep
    /// itself cannot suppress the very boundary day it exists to unblock.
    ///
    /// INERT for every one of the 19 existing fixtures: none declares a
    /// `plan.curriculum_upgraded` event, so `folded.curriculumTimeline` is
    /// always empty and the guard below returns immediately on every date —
    /// the drop branches below never execute against any current fixture.
    mutating func sweepAtBoundary(_ date: LocalDate) {
        guard let boundary = folded.curriculumTimeline.first(where: { $0.effectiveFrom == date })
        else { return }

        // Weeks whose span has not fully elapsed before `date` are dropped —
        // includes a week that straddles `date` itself (§ the ordering note
        // above) and any purely-future week.
        let keptConsolidationWeeks = consolidationWeeks.filter { $0.end < date }
        let consolidationWeeksDropped = consolidationWeeks.count - keptConsolidationWeeks.count

        // `Distribution.slices`/`dates` are `let`-only (immutable fields):
        // dropping the future slice/date pairs means REBUILDING a new
        // `Distribution` value with the filtered parallel arrays, never
        // in-place mutation (which would not compile). A distribution left
        // with no kept dates is dropped from the array entirely.
        var keptDistributions: [Distribution] = []
        var distributionSlicesDropped = 0
        for distribution in distributions {
            var keptSlices: [OrderSpanSet] = []
            var keptDates: [LocalDate] = []
            for (slice, sliceDate) in zip(distribution.slices, distribution.dates) {
                if sliceDate < date {
                    keptSlices.append(slice)
                    keptDates.append(sliceDate)
                } else {
                    distributionSlicesDropped += 1
                }
            }
            if !keptDates.isEmpty {
                keptDistributions.append(Distribution(
                    slices: keptSlices, dates: keptDates, type: distribution.type,
                    originRuleId: distribution.originRuleId, ordering: distribution.ordering,
                    session: distribution.session, estMinutesOverride: distribution.estMinutesOverride))
            }
        }

        let scheduledJuzReviewsDropped = scheduledJuzReviews
            .filter { $0.key >= date }
            .reduce(0) { $0 + $1.value.count }
        let keptScheduledJuzReviews = scheduledJuzReviews.filter { $0.key < date }

        let rotationCursorsDropped = rotationCursors.count

        guard consolidationWeeksDropped + distributionSlicesDropped
            + scheduledJuzReviewsDropped + rotationCursorsDropped > 0
        else { return }

        consolidationWeeks = keptConsolidationWeeks
        distributions = keptDistributions
        scheduledJuzReviews = keptScheduledJuzReviews
        rotationCursors.removeAll()

        droppedAtBoundary.append(BoundaryDrop(
            date: date,
            fromSlug: cur(date.adding(days: -1)).slug,
            toSlug: boundary.slug,
            consolidationWeeksDropped: consolidationWeeksDropped,
            distributionSlicesDropped: distributionSlicesDropped,
            scheduledJuzReviewsDropped: scheduledJuzReviewsDropped,
            rotationCursorsDropped: rotationCursorsDropped))
    }

    func effectivePolicy(on date: LocalDate) -> PlanPolicy {
        var policy = context.policy
        for entry in folded.policyTimeline where entry.isEffective(on: date) {
            policy = policy.applying(patch: entry.patch)
        }
        return policy
    }

    // MARK: calendar helpers

    func exceptionClass(on date: LocalDate) -> String? {
        context.calendar.orgExceptions[date]
    }

    func dayClass(on date: LocalDate) -> String? {
        if let exception = exceptionClass(on: date) { return exception }
        // PC-4: the easy-to-miss one — `evaluateRule`'s first gate. Reading
        // `baseCurriculum` here instead of `cur(date)` would classify every
        // post-upgrade-boundary day under the WRONG curriculum's day-class
        // vocabulary and silently emit nothing (the 15 built-ins' day-class
        // names are largely disjoint). Inert today: no fixture ever crosses
        // an upgrade boundary.
        return cur(date).dayClass(of: date.weekday)
    }

    func isPaused(_ date: LocalDate) -> Bool {
        folded.isPaused(on: date)
    }

    /// D-049: discharge `mp` of catch-up work against the OLDEST lost slots
    /// first. Only work BEYOND a day's base amount repays a slot — one day's
    /// normal ḥifẓ cannot repay a day that was lost.
    mutating func dischargeDebt(_ mp: Int64) {
        var left = mp
        for i in debtMissedNew.indices {
            if left <= 0 { break }
            let take = min(debtMissedNew[i].owedMp, left)
            debtMissedNew[i].owedMp -= take
            left -= take
        }
        debtMissedNew.removeAll { $0.owedMp <= 0 }
    }

    /// Active day for trigger scheduling and recovery: policy-active weekday,
    /// not an org exception, not paused.
    func isActiveDay(_ date: LocalDate, policy: PlanPolicy) -> Bool {
        policy.activeWeekdays.contains(date.weekday) && exceptionClass(on: date) == nil && !isPaused(date)
    }

    func nextActiveDay(after date: LocalDate, policy: PlanPolicy) -> LocalDate? {
        for offset in 1...366 {
            let candidate = date.adding(days: offset)
            if isActiveDay(candidate, policy: policy) { return candidate }
        }
        return nil
    }

    /// The start of the curriculum week at or before `date`.
    func weekStart(of date: LocalDate) -> LocalDate {
        let delta = (date.weekday.rawValue - cur(date).weekStart.rawValue + 7) % 7
        return date.adding(days: -delta)
    }

    /// Completed weeks for the murājaʿah ramp: count of week-start days after
    /// the first active day and ≤ D (ENGINE_SEMANTICS §4).
    func completedWeeks(at date: LocalDate) -> Int64 {
        let target = cur(date).weekStart.rawValue
        let a = anchor.dayNumber
        let d = date.dayNumber
        guard d > a else { return 0 }
        let anchorWeekday = (a % 7 + 7 + 4) % 7
        var toAdd = (target - anchorWeekday + 7) % 7
        if toAdd == 0 { toAdd = 7 }  // strictly after the first active day
        let first = a + toAdd
        guard first <= d else { return 0 }
        return Int64((d - first) / 7 + 1)
    }

    // MARK: ledgers & windows

    func ledgerUnion(from: LocalDate, to: LocalDate) -> OrderSpanSet {
        var result = OrderSpanSet()
        guard from <= to else { return result }
        var d = from
        while d <= to {
            if let entry = ledger[d] { result.formUnion(entry) }
            d = d.adding(days: 1)
        }
        return result
    }

    /// R-W1/R-W2 window: prior `days`; on the week-start day, `sundayDays` (C-7).
    func warmupWindow(on date: LocalDate, days: Int, sundayDays: Int?) -> OrderSpanSet {
        let span = (date.weekday == cur(date).weekStart ? (sundayDays ?? days) : days)
        return ledgerUnion(from: date.adding(days: -span), to: date.adding(days: -1))
    }

    // MARK: content conversion

    func contentRanges(_ set: OrderSpanSet) -> [CanonicalRange] {
        var out: [CanonicalRange] = []
        var runStartGlobal = -1
        var prevGlobal = -1
        func flush() {
            guard runStartGlobal >= 0 else { return }
            out.append(CanonicalRange(
                work: index.workOfGlobal(runStartGlobal),
                unitStart: index.unitOfGlobal(runStartGlobal),
                unitEnd: index.unitOfGlobal(prevGlobal))!)
            runStartGlobal = -1
        }
        for p in set.positions {
            let g = order.orderToGlobal[p]
            if runStartGlobal >= 0, g == prevGlobal + 1, index.workOfGlobal(g) == index.workOfGlobal(prevGlobal) {
                prevGlobal = g
            } else {
                flush()
                runStartGlobal = g
                prevGlobal = g
            }
        }
        flush()
        return out
    }

    func globalSpanSet(fromOrder set: OrderSpanSet) -> OrderSpanSet {
        var out = OrderSpanSet()
        for p in set.positions {
            let g = order.orderToGlobal[p]
            out.insert(g..<(g + 1))
        }
        return out
    }

    // MARK: new-ḥifẓ selection (D-013/D-014, ENGINE_SEMANTICS §2)

    struct NewSelection {
        let positions: [Int]         // order positions, ascending
        let span: OrderSpanSet
        let nextCursor: Int          // order position after the selection
        let sizeMicropages: Int64
    }

    /// PCC-3: the ONLY thrown case is `.unsupported` — the DSL asked for a
    /// unit this corpus's `ContentIndex` cannot resolve at all. Every other
    /// nil-return below (`fromPos` past the end, a resolved count/µp amount
    /// of 0, or the walk finding nothing) is a legitimate "nothing to
    /// select" outcome and stays nil, exactly as before Stage 2.
    enum SelectionError: Error, CustomStringConvertible {
        case unsupportedUnit(String)
        case boundaryUnitUndefined
        var description: String {
            switch self {
            case .unsupportedUnit(let u):
                return "content index does not support unit '\(u)' for new-ḥifẓ selection (PCC-3)"
            case .boundaryUnitUndefined:
                return "content index has no fixed boundary micropage size for a recent-boundary murājaʿah pool window"
            }
        }
    }

    /// Converts an amount used by a µp-domain ramp without inventing a size for
    /// nonuniform count units. Poem bayts have one exact corpus-pinned weight;
    /// Qurʾān ayahs do not, so an ayah-count ramp is rejected explicitly.
    func rampMicropages(_ amount: QuranAmount, path: String) throws -> Int64 {
        switch index.amountMicropages(amount) {
        case .micropages(let value):
            return value
        case .countUnit(let count):
            guard let unit = uniformUnitMicropages else {
                throw EngineError.invalid(
                    "\(path): unit '\(amount.unit.rawValue)' is count-based and this corpus has nonuniform unit weights")
            }
            let (value, overflow) = Int64(count).multipliedReportingOverflow(by: unit)
            guard !overflow else { throw EngineError.invalid("\(path): amount overflows Int64") }
            return value
        case .unsupported:
            throw EngineError.invalid(
                "\(path): unit '\(amount.unit.rawValue)' is not defined for this corpus (boundary kind '\(index.boundaryKind)')")
        }
    }

    func selectNextNew(fromPos: Int, amount: QuranAmount) throws -> NewSelection? {
        guard fromPos < order.count else { return nil }

        func inTarget(_ p: Int) -> Bool {
            targetSet?.contains(p) ?? true
        }

        var selected: [Int] = []
        var accumulated: Int64 = 0

        switch index.amountMicropages(amount) {
        case .unsupported:
            throw SelectionError.unsupportedUnit(amount.unit.rawValue)

        case .countUnit(let count):
            // Ayah-equivalent amounts resolve by unit count, not µp
            // (ENGINE_SEMANTICS §1); D-014 applies on that count, segment by
            // segment (§11.13).
            guard count >= 1 else { return nil }
            var segmentCount = 0
            var p = fromPos
            while p < order.count && selected.count < count {
                if !inTarget(p) { p += 1; continue }
                if let last = selected.last {
                    let lastWork = index.workOfGlobal(order.orderToGlobal[last])
                    let thisWork = index.workOfGlobal(order.orderToGlobal[p])
                    if lastWork != thisWork {
                        if segmentCount * 3 >= count { break }  // truncate at boundary
                        segmentCount = 0                        // bridge into the next work
                    }
                }
                selected.append(p)
                segmentCount += 1
                accumulated += weightOfOrderPos(p)
                p += 1
            }

        case .micropages(let amountMicropages):
            guard amountMicropages > 0 else { return nil }
            // D-014 per §11.13: at every work transition, truncate unless the
            // current work's selected segment is < amount/3 (segment-by-
            // segment, enabling multi-work bridging through short works).
            var segmentMicropages: Int64 = 0
            var p = fromPos
            while p < order.count {
                if !inTarget(p) { p += 1; continue }
                if let last = selected.last {
                    let lastWork = index.workOfGlobal(order.orderToGlobal[last])
                    let thisWork = index.workOfGlobal(order.orderToGlobal[p])
                    if lastWork != thisWork {
                        if segmentMicropages * 3 >= amountMicropages { break }  // truncate
                        segmentMicropages = 0                                   // bridge
                    }
                }
                selected.append(p)
                let w = weightOfOrderPos(p)
                accumulated += w
                segmentMicropages += w
                if accumulated >= amountMicropages { break }
                p += 1
            }
            // D-013: round up unless overshoot > 40% of a page; never below 1
            // unit. This threshold stays a raw literal deliberately — it is
            // corpus-INVARIANT (40% of the page-in-µp normalization that
            // holds for every corpus under the batch's µp ruling: e.g. 4
            // abyāt for the poem corpus's per-bayt µp size), unlike the
            // per-corpus boundary-sizing constant resolved via
            // `index.boundaryUnitMicropages` in `murajaahPoolWindow` below.
            if accumulated >= amountMicropages,
               accumulated - amountMicropages > 400_000,
               selected.count > 1 {
                let dropped = selected.removeLast()
                accumulated -= weightOfOrderPos(dropped)
            }
        }

        guard let lastPos = selected.last else { return nil }
        var span = OrderSpanSet()
        for p in selected { span.insert(p..<(p + 1)) }
        return NewSelection(positions: selected, span: span, nextCursor: lastPos + 1, sizeMicropages: accumulated)
    }

    // MARK: murājaʿah (ENGINE_SEMANTICS §4)

    struct MurajaahOutcome {
        let slice: OrderSpanSet
        let nextRotationCursor: Int
    }

    func murajaahPool(on date: LocalDate, warmupSubtract: OrderSpanSet) -> OrderSpanSet {
        declaredOrderSet.union(completedOrderSet).subtracting(warmupSubtract)
    }

    /// E-1 (D-038): resolve a murājaʿah pool window to order positions.
    /// `prior_hifz` = all memorized minus today's warm-up windows; a recent
    /// window = the most-recently-memorized N pages/juz by memorization order
    /// (does NOT subtract warm-up — a recent layer is meant to cover it).
    func murajaahPoolWindow(
        _ window: PoolWindow, warmupSubtract: OrderSpanSet, resolver: VariableResolver
    ) throws -> OrderSpanSet {
        let memorized = declaredOrderSet.union(completedOrderSet)
        let unitMp: Int64
        let countRef: IntOrVar
        // E-1b (D-043): the complement pools derive from the SAME backwards walk
        // as the recent window, so the two can never drift apart.
        let complement: Bool
        switch window {
        case .priorHifz:
            return memorized.subtracting(warmupSubtract)
        // `1_000_000` stays a raw literal: it is the corpus-INVARIANT
        // 1-page-in-µp normalization (every corpus's "page" is defined as
        // 1_000_000 µp under the batch's ruling), unlike the per-corpus
        // "recent N boundaries" size just below.
        case .recentPages(let n): unitMp = 1_000_000; countRef = n; complement = false
        case .recentJuz(let n):
            guard let boundaryMp = index.boundaryUnitMicropages else { throw SelectionError.boundaryUnitUndefined }
            unitMp = boundaryMp; countRef = n; complement = false
        case .allExceptRecentPages(let n): unitMp = 1_000_000; countRef = n; complement = true
        case .allExceptRecentJuz(let n):
            guard let boundaryMp = index.boundaryUnitMicropages else { throw SelectionError.boundaryUnitUndefined }
            unitMp = boundaryMp; countRef = n; complement = true
        }
        let target = Int64(resolver.int(countRef) ?? 0) * unitMp
        // Guard BEFORE inserting (not after) so a count of 0 yields an empty
        // window, matching the TS/Kotlin walk exactly.
        var recent = OrderSpanSet()
        var acc: Int64 = 0
        for pos in memorized.positions.reversed() {
            if acc >= target { break }
            recent.insert(pos..<(pos + 1))
            acc += weightOfOrderPos(pos)
        }
        if !complement { return recent }
        // Everything that has ROLLED OFF the window; like priorHifz this is an
        // "old material" layer, so it subtracts the warm-up union.
        return memorized.subtracting(recent).subtracting(warmupSubtract)
    }

    func murajaahSlice(
        pool: OrderSpanSet,
        rotationCursor: Int,
        rampStartMicropages: Int64,
        rampStepMicropages: Int64,
        ceilingMicropages: Int64,
        weakBoost: Int64,
        weeks: Int64,
        distributedTodayMicropages: Int64,
        /// E-3a (D-045): when set, `per_day` is fixed-interval cycling instead of a
        /// ramp — take enough to cover the WHOLE pool every N days.
        cycleDays: Int64? = nil
    ) -> MurajaahOutcome? {
        guard !pool.isEmpty else { return nil }
        // §11.7: the pool-size clamp uses slicing-weight totals so
        // "whole pool exactly once" holds under weak-boost.
        let poolSlicing = pool.sum { self.slicingWeightOfOrderPos($0, weakBoost: weakBoost) }
        let m: Int64
        if let n = cycleDays {
            // The amount derives from the POOL, so the per-item interval stays fixed
            // as the corpus grows. Ceil ⇒ "at least once every N days". No ceiling
            // exists in this mode, so the GX-09 clamp does not apply.
            m = min((poolSlicing + n - 1) / n, poolSlicing)
        } else {
            let ramp = rampStartMicropages + rampStepMicropages * weeks
            // GX-09: a distributed juz-review slice takes priority under the ceiling.
            let effectiveCeiling = max(0, ceilingMicropages - distributedTodayMicropages)
            m = min(effectiveCeiling, min(ramp, poolSlicing))
        }
        guard m > 0 else { return nil }

        if poolSlicing <= m {
            // Whole pool exactly once; the cursor does not move.
            return MurajaahOutcome(slice: pool, nextRotationCursor: rotationCursor)
        }

        let positions = pool.positions
        guard let startPos = pool.firstPosition(atOrAfter: rotationCursor) ?? pool.first,
              let startIndex = positions.firstIndex(of: startPos)
        else { return nil }

        var slice = OrderSpanSet()
        var acc: Int64 = 0
        var i = startIndex
        var lastPos = startPos
        var taken = 0
        while taken < positions.count {
            let p = positions[i]
            slice.insert(p..<(p + 1))
            acc += slicingWeightOfOrderPos(p, weakBoost: weakBoost)
            lastPos = p
            taken += 1
            if acc >= m { break }
            i = (i + 1) % positions.count
        }
        let next = lastPos + 1 >= order.count ? 0 : lastPos + 1
        return MurajaahOutcome(slice: slice, nextRotationCursor: next)
    }

    // MARK: near-equal prefix split (ENGINE_SEMANTICS §5)

    func splitNearEqual(_ set: OrderSpanSet, parts: Int) -> [OrderSpanSet] {
        var slices = [OrderSpanSet](repeating: OrderSpanSet(), count: parts)
        guard parts >= 1, !set.isEmpty else { return slices }
        let total = set.sum { self.weightOfOrderPos($0) }
        var cumulative: Int64 = 0
        var k = 0
        for p in set.positions {
            slices[k].insert(p..<(p + 1))
            cumulative += weightOfOrderPos(p)
            // Slice k+1 ends at the smallest prefix ≥ (k+1)×total/parts.
            while k < parts - 1, cumulative >= Int64(k + 1) * total / Int64(parts) {
                k += 1
            }
        }
        return slices
    }

    // MARK: workload model (ENGINE_SEMANTICS §1, PRD §7.10)

    func estimateMinutes(
        type: String, content: OrderSpanSet, repetitions: Int?, listenCount: Int? = nil,
        estMinutesOverride: Int? = nil, on date: LocalDate
    ) -> Int {
        // CB-2: an authored `est_minutes` override wins FIRST — before the
        // `prep_dhikr` zero-out, before any rate lookup, before any
        // `guard s > 0`-style guard below. No built-in curriculum sets
        // `est_minutes`, so this is always a no-op fallthrough today.
        if let override = estMinutesOverride { return override }
        // PC-4: thread `date` so rate lookups resolve against the curriculum
        // active THAT day, not unconditionally `baseCurriculum`.
        let curriculum = cur(date)
        if type == "prep_dhikr" { return 0 }
        if type == "listening" {
            // §11.16: rate[listening_lesson] × listen_count.
            guard let rate = curriculum.workloadRates["listening_lesson"] ?? curriculum.workloadRates[type] else { return 0 }
            let count = Int64(listenCount ?? 1)
            return Int(Micropage.roundHalfUp(rate.units * count, rate.denominator))
        }
        let (rateKey, perRep): (String, Bool)
        switch type {
        case "new_hifz": (rateKey, perRep) = ("new_hifz", false)
        case "warmup": (rateKey, perRep) = ("warmup", false)
        case "takrar": (rateKey, perRep) = ("takrar_rep", true)
        case "weekend_consolidation": (rateKey, perRep) = ("takrar_rep", true)
        case "murajaah": (rateKey, perRep) = ("murajaah", false)
        default: (rateKey, perRep) = ("murajaah", false)  // review-pass types: tasmee, juz_review(±distributed), cycle_consolidation
        }
        guard let rate = curriculum.workloadRates[type] ?? curriculum.workloadRates[rateKey] else { return 0 }
        // S = Σ weight(a) × strength_factor_scaled(a)
        var s: Int64 = 0
        for p in content.positions {
            s += weightOfOrderPos(p) * strengthOfOrderPos(p)
        }
        guard s > 0 else { return 0 }
        let reps = perRep ? Int64(repetitions ?? 1) : 1
        // minutes = round_half_up(rate × S × reps / (1e6 × 1e3))
        let minutes = Micropage.roundHalfUp(rate.units * s * reps, rate.denominator * 1_000_000 * 1_000)
        return Int(minutes)
    }

    // MARK: evidence resolution

    func resolveEvidence(type: String, resolver: VariableResolver, policy: PlanPolicy, on date: LocalDate) -> EvidenceSpec {
        let curriculum = cur(date)  // PC-4: per-date curriculum resolution.
        let resolved: EvidenceSpec
        if let override = policy.evidencePolicy[type], let spec = resolver.evidence(override) {
            resolved = spec
        } else if let json = curriculum.evidenceDefaults[type], let spec = resolver.evidence(json) {
            resolved = spec
        } else if let json = curriculum.evidenceDefaults["default"], let spec = resolver.evidence(json) {
            resolved = spec
        } else {
            resolved = .selfCheck
        }
        return teacherlessFallback(resolved, type: type, curriculum: curriculum)
    }

    /// A learner without an assigned teacher can self-check a task whose
    /// teacher evidence is optional. A curriculum requiring verified
    /// advancement still requires teacher evidence for new memorization.
    func teacherlessFallback(_ spec: EvidenceSpec, type: String, curriculum: CompiledCurriculum) -> EvidenceSpec {
        guard !context.hasAssignedTeacher, case .teacherVerification = spec else { return spec }
        let isNonNegotiableGate = (type == "new_hifz" && curriculum.requireVerified)
        return isNonNegotiableGate ? spec : .selfCheck
    }

    // MARK: main loop

    /// WP-06 (v1 audit 3.1): `resumingFrom` is additive — every existing
    /// caller (`Engine.generate(context:window:)`, used by everything except
    /// `Regenerator`) keeps calling this with the default `nil` and gets
    /// EXACTLY the old anchor-replay behavior, byte for byte. Only
    /// `Engine.generateIncremental` (below) passes a non-nil checkpoint.
    ///
    /// Resuming is safe because `window.from` is already, in the
    /// un-checkpointed code, the boundary `Regenerator` trusts as "nothing
    /// at or after this date can be assumed unaffected by what's new" — it
    /// only diffs/emits `task_instance_cache` rows from `window.from`
    /// onward, leaving everything before it untouched no matter what. Reusing
    /// that SAME trusted boundary for internal simulation STATE, not merely
    /// output filtering, does not weaken it: any newly appended event's
    /// `earliestDirtyDate` (see `PlanStore.earliestDirtyDate`) is always ≥
    /// `window.from` by construction (`Regenerator.window`), and events are
    /// append-only, so nothing dated before `window.from` can have changed
    /// since the checkpoint was captured. The `checkpoint.date <= today`
    /// guard additionally protects against reusing a checkpoint that was
    /// captured while a day was still in PROJECTION mode (assumed-pass)
    /// once `today` has caught up to it and that day must now be checked
    /// against real completions (`simulateDay`'s `actualMode`) — a
    /// checkpoint is never captured past its OWN `today` (see
    /// `checkpointDate` below), but this guard also covers a caller passing
    /// an older `today` than the checkpoint was captured under.
    mutating func generate(
        window: GenerationWindow, resumingFrom resumeCheckpoint: Checkpoint? = nil
    ) throws -> (result: GenerationResult, checkpoint: Checkpoint?) {
        guard window.from <= window.to else {
            throw EngineError.invalid("window.from must be ≤ window.to")
        }
        var output: [TaskInstance] = []
        var date = anchor
        var capturedCheckpoint: Checkpoint? = nil
        if let resumeCheckpoint,
           resumeCheckpoint.date >= anchor,
           resumeCheckpoint.date < window.from,
           resumeCheckpoint.date <= today {
            restore(resumeCheckpoint)
            date = resumeCheckpoint.date.adding(days: 1)
            capturedCheckpoint = resumeCheckpoint
        }
        // The latest day it is safe to checkpoint: strictly before THIS run's
        // own dirty boundary (so a LATER run's `resumeCheckpoint.date <
        // window.from` guard above can trust it), and never past `today` (so
        // a checkpointed day was simulated in ACTUAL, not projection, mode).
        let checkpointDate = min(window.from.adding(days: -1), today)
        while date <= window.to {
            let emitted = try simulateDay(date)
            if date >= window.from {
                output.append(contentsOf: emitted)
            }
            if date == checkpointDate {
                capturedCheckpoint = checkpoint(at: date)
            }
            date = date.adding(days: 1)
        }

        // §11.15: cursor = next SELECTABLE new-ḥifẓ ayah, `-` when exhausted.
        // Skip already-memorized (declared or in-plan-completed) and out-of-
        // target positions — so a full ḥāfiẓ maintenance plan reports `-`
        // (2026-07-16 multi-curriculum hardening; frontier plans are unchanged
        // because the cursor already sits on the first unmemorized position).
        let isTilawahPlan = baseCurriculum.rules.contains { $0.emit.type == "tilawah" }
        let memorizedSet = declaredOrderSet.union(completedOrderSet)
        var selPos = cursorPos
        while !isTilawahPlan && selPos < order.count {
            let inTarget = targetSet?.contains(selPos) ?? true
            if inTarget && !memorizedSet.contains(selPos) { break }
            selPos += 1
        }
        let cursor: CanonicalPosition? = selPos < order.count
            ? index.position(ofGlobal: order.orderToGlobal[selPos])
            : nil
        // D-049: count still-OWED lost slots. A slot's content may well be
        // memorized by now — that does not give the lost day back.
        let outstandingDebt = debtMissedNew.filter { $0.owedMp > 0 }.count
        let status: PlanStatus
        if planCompleted {
            status = .completed
        } else if isPaused(window.to) {
            status = .paused
        } else {
            status = .active
        }
        return (
            GenerationResult(
                tasks: output,
                finalState: FinalPlanState(
                    cursor: cursor,
                    juzCompleted: juzCompletedCount,
                    cycleWeeks: cycleWeeksScheduled,
                    debtNewRanges: outstandingDebt,
                    status: status),
                droppedAtBoundary: droppedAtBoundary),
            capturedCheckpoint)
    }

    mutating func simulateDay(_ date: LocalDate) throws -> [TaskInstance] {
        // pause_and_resume: no tasks, no misses during a pause (§8).
        if isPaused(date) { return [] }
        // PC-4 (D-054): shadow-bind the curriculum active on THIS date. Every
        // bare `curriculum` reference for the rest of this function —
        // including every nested closure below (sessionRank, baseFlags,
        // evaluateRule, isCompleted, isPass), which capture it by ordinary
        // lexical scoping — now resolves per-date instead of to the struct's
        // `baseCurriculum`. For every existing fixture (`curriculumTimeline`
        // empty) `cur(date) == baseCurriculum` on every date, so this is
        // observably a no-op — verified via fixture-parity after this change.
        let curriculum = cur(date)
        guard let dayClassName = dayClass(on: date) else { return [] }

        // PC-5 (D-054 hard-boundary sweep): runs BEFORE `consWeek` is
        // resolved below — a stale consolidation week whose span straddles
        // this boundary date must not survive to gate `date`'s rules under
        // the OLD curriculum's vocabulary, which is exactly the bug this
        // ordering prevents.
        sweepAtBoundary(date)

        let policy = effectivePolicy(on: date)
        let resolver = VariableResolver(curriculum: curriculum, policy: policy)
        let isExceptionDay = exceptionClass(on: date) != nil
        let actualMode = date <= today
        let firstActiveDay = date == anchor
        let consWeek = consolidationWeeks.first { $0.contains(date) }
        let suppressNew = consWeek.map { $0.mode == "pause_new" } ?? false

        // --- Today's new-ḥifẓ selection (shared by every next_new use today).
        var newAmountMicropages = policy.newAmount.micropages
        var redistributionExtra: Int64 = 0
        if var redistribute = redistribution, redistribute.daysLeft > 0, redistribute.remainingMicropages > 0,
           isActiveDay(date, policy: policy), !suppressNew {
            // §8 redistribute: next N valid weekdays get new_amount + extra.
            let extra = min(
                Micropage.roundHalfUp(redistribute.remainingMicropages, Int64(redistribute.daysLeft)),
                redistribute.maxExtraMicropages ?? Int64.max)
            redistributionExtra = extra
            if let base = newAmountMicropages { newAmountMicropages = base + extra }
            redistribute.daysLeft -= 1
            redistribution = redistribute
        }
        let effectiveAmount: QuranAmount
        if let micropages = newAmountMicropages, redistributionExtra > 0 {
            // Express the boosted amount as an exact page decimal (µp / 1e6).
            effectiveAmount = QuranAmount(
                unit: .page,
                value: DecimalValue(string: micropagesToPageDecimal(micropages))!)
        } else {
            effectiveAmount = policy.newAmount
        }
        let newSelection: NewSelection?
        if planCompleted {
            newSelection = nil
        } else {
            newSelection = try selectNextNew(fromPos: cursorPos, amount: effectiveAmount)
        }

        // --- Distributed juz-review slices landing today (before murājaʿah: ceiling priority).
        var distributedToday: [(distributionIndex: Int, slice: OrderSpanSet)] = []
        for (i, distribution) in distributions.enumerated() {
            for (k, sliceDate) in distribution.dates.enumerated() where sliceDate == date {
                let slice = distribution.slices[k]
                if !slice.isEmpty { distributedToday.append((i, slice)) }
            }
        }
        let distributedMicropages = distributedToday.reduce(Int64(0)) { acc, item in
            acc + item.slice.sum { self.weightOfOrderPos($0) }
        }

        // --- Collect emissions.
        var pending: [PendingEmission] = []
        var pendingRotationAdvances: [(ruleId: String, nextCursor: Int)] = []
        var readingSelection: NewSelection?

        func sessionRank(_ id: String) -> Int {
            curriculum.sessionIds.firstIndex(of: id) ?? curriculum.sessionIds.count
        }

        func baseFlags() -> [String] {
            var flags: [String] = []
            if firstActiveDay { flags.append("first_active_day") }
            if consWeek != nil { flags.append("consolidation_week") }
            return flags
        }

        func evaluateRule(_ rule: RuleSpec, effectiveOrdering: Int?) throws {
            guard rule.when.dayClasses.contains(dayClassName) else { return }
            guard curriculum.sessionIds.contains(rule.when.session) else { return }
            if let enabledVar = rule.when.enabledVar, resolver.bool(enabledVar) != true { return }
            if let dayIn = rule.when.dayIn {
                guard let set = resolver.weekdaySet(dayIn), set.contains(date.weekday) else { return }
            }
            for condition in rule.when.notConditions {
                switch condition {
                case .firstActiveDay: if firstActiveDay { return }
                case .inConsolidationWeek: if consWeek != nil { return }
                case .hasFlag: return  // no custom flags in v1
                }
            }
            if suppressNew, let week = consWeek, rule.suppressedBy.contains(week.triggerId) {
                // D-048: a FAILURE week (inserted by a task_failed trigger) costs
                // advancement slots the learner did not choose to give up, so each
                // suppressed new-ḥifẓ day owes debt — slot-based per D-035. A
                // A planned consolidation week owes nothing.
                if rule.emit.type == "new_hifz", date < today, week.isFailure,
                   isActiveDay(date, policy: policy),
                   let selection = newSelection, !selection.span.isEmpty {
                    debtMissedNew.append((date: date, span: selection.span, owedMp: selection.span.sum { self.weightOfOrderPos($0) }))
                }
                return
            }

            var content = OrderSpanSet()
            var isMurajaahRule = false
            if let selectRef = rule.emit.select {
                let spec: SelectorSpec?
                switch selectRef {
                case .named(let name): spec = curriculum.selectors[name]
                case .inline(let inline): spec = inline
                }
                guard let selector = spec else { return }
                switch selector {
                case .nextContent(let amountRef):
                    guard let amount = resolver.amount(amountRef),
                          let selection = try selectNextNew(fromPos: cursorPos, amount: amount)
                    else { return }
                    content = selection.span
                    if rule.emit.type == "tilawah" { readingSelection = selection }
                case .nextNew:
                    guard let selection = newSelection else { return }
                    content = selection.span
                case .ledgerWindow(let daysRef, let sundayRef):
                    guard let days = resolver.int(daysRef) else { return }
                    content = warmupWindow(on: date, days: days, sundayDays: resolver.int(sundayRef))
                case .ledgerOffset(let daysAgoRef):
                    // E-2 (D-039): the new-ḥifẓ ledger of exactly one prior day.
                    guard let k = resolver.int(daysAgoRef) else { return }
                    content = ledgerUnion(from: date.adding(days: -k), to: date.adding(days: -k))
                case .weekToDate:
                    content = ledgerUnion(from: weekStart(of: date), to: date.adding(days: -1))
                case .poolRotation(let poolWindow, let perDay, let boostRef):
                    isMurajaahRule = true
                    var start: Int64 = 0
                    var step: Int64 = 0
                    var ceiling: Int64 = 0
                    var cycleDays: Int64?
                    switch perDay {
                    case .ramp(let startRef, let stepRef, let ceilingRef):
                        // §11.7: ramp start comes from policy.murajaah_ramp.start
                        // when present, else the DSL literal/variable.
                        guard let startAmount = policy.murajaahRamp?.start ?? resolver.amount(startRef),
                              let stepAmount = policy.murajaahRamp?.step ?? resolver.amount(stepRef),
                              let ceilingAmount = resolver.amount(ceilingRef)
                        else { return }
                        start = try rampMicropages(startAmount, path: "pool_rotation.ramp.start")
                        step = try rampMicropages(stepAmount, path: "pool_rotation.ramp.step")
                        ceiling = try rampMicropages(ceilingAmount, path: "pool_rotation.ramp.ceiling")
                    case .cycleDays(let nRef):
                        // E-3a (D-045): no ramp and no policy ramp override — the
                        // amount derives from the pool so the interval stays fixed.
                        guard let n = resolver.int(nRef), n >= 1 else { return }
                        cycleDays = Int64(n)
                    }
                    let boost = Int64(resolver.int(boostRef) ?? 1)
                    // H-5 (2026-07-16): subtract the UNION of every warm-up
                    // window emitted TODAY (§4 "no double coverage"), not one
                    // arbitrary ledger_window selector.
                    let subtract = warmupSubtractForDay(
                        date: date, dayClassName: dayClassName, firstActiveDay: firstActiveDay,
                        consWeek: consWeek, resolver: resolver)
                    let pool = try murajaahPoolWindow(poolWindow, warmupSubtract: subtract, resolver: resolver)
                    guard let outcome = murajaahSlice(
                        pool: pool,
                        rotationCursor: rotationCursors[rule.id] ?? 0,  // E-1: per-layer cursor
                        rampStartMicropages: start,
                        rampStepMicropages: step,
                        ceilingMicropages: ceiling,
                        weakBoost: boost,
                        weeks: completedWeeks(at: date),
                        distributedTodayMicropages: distributedMicropages,
                        cycleDays: cycleDays)
                    else { return }
                    content = outcome.slice
                    pendingRotationAdvances.append((rule.id, outcome.nextRotationCursor))
                case .tomorrowNew:
                    guard let target = try listeningTarget(
                        on: date, policy: policy, resolver: resolver, consWeek: consWeek,
                        todaysSelection: newSelection) else { return }
                    content = target
                case .block:
                    // Whole last-N-juz block; only meaningful inside a
                    // consolidation week (cyc_we day rule).
                    guard let week = consWeek else { return }
                    content = blockContent(week: week)
                case .completedJuz, .priorHifzSplit:
                    return  // trigger-context selectors; not valid in daily rules
                case .fixed(let ranges):
                    for range in ranges {
                        guard let globals = index.globalRange(of: range) else { continue }
                        for g in globals {
                            if let p = order.orderPosition(ofGlobal: g) { content.insert(p..<(p + 1)) }
                        }
                    }
                case .blockSlice(let ofName, let parts):
                    guard let week = consWeek,
                          let slice = blockSliceContent(week: week, of: ofName, parts: parts, date: date, resolver: resolver)
                    else { return }
                    content = slice
                case .intersectPriorHifz(let ref):
                    let inner: SelectorSpec?
                    switch ref {
                    case .named(let name): inner = curriculum.selectors[name]
                    case .inline(let spec): inner = spec
                    }
                    guard case .fixed(let ranges)? = inner else {
                        throw EngineError.invalid("intersect_prior_hifz currently requires a fixed selector")
                    }
                    var selected = OrderSpanSet()
                    for range in ranges {
                        guard let globals = index.globalRange(of: range) else { continue }
                        for global in globals {
                            if let position = order.orderPosition(ofGlobal: global) {
                                selected.insert(position..<(position + 1))
                            }
                        }
                    }
                    let memorized = declaredOrderSet.union(completedOrderSet)
                    for position in selected.positions where memorized.contains(position) {
                        content.insert(position..<(position + 1))
                    }
                }
                // Empty-content rule: content-bearing tasks with empty selection are not emitted.
                if content.isEmpty && !rule.emit.infoOnly {
                    // Drop any advance this rule just recorded (empty ⇒ not emitted).
                    if isMurajaahRule, pendingRotationAdvances.last?.ruleId == rule.id {
                        pendingRotationAdvances.removeLast()
                    }
                    return
                }
            }

            var window: (LocalDate, LocalDate)? = nil
            if let w = rule.emit.window {
                window = (latestDate(withWeekday: w.opens, atOrBefore: date),
                          earliestDate(withWeekday: w.closes, atOrAfter: date))
            }

            pending.append(PendingEmission(
                sessionRank: sessionRank(rule.when.session),
                session: rule.when.session,
                ordering: effectiveOrdering ?? rule.emit.ordering,
                type: rule.emit.type,
                originRuleId: rule.id,
                content: content,
                repetitions: resolver.int(rule.emit.repetitions),
                spacingMinutes: resolver.int(rule.emit.spacingMinutes),
                listenCount: resolver.int(rule.emit.listenCount),
                window: window,
                infoOnly: rule.emit.infoOnly,
                extraFlags: rule.emit.infoOnly ? ["info_only"] : [],
                estMinutesOverride: rule.emit.estMinutes))
        }

        // Daily rules (evaluation order = DSL order; ordering ints drive sort).
        for rule in curriculum.rules {
            try evaluateRule(rule, effectiveOrdering: nil)
        }
        // Inserted-week day rules keep their declared ids with
        // ordering = 90 + declared ordering (§11.2).
        if let week = consWeek {
            for rule in week.dayRules {
                try evaluateRule(rule, effectiveOrdering: 90 + rule.emit.ordering)
            }
        }
        // Trigger-scheduled tasks (§11.2): origin "{trigger_id}.{task_type}",
        // ordering 90 + effect index.
        for scheduled in scheduledJuzReviews[date] ?? [] where !scheduled.content.isEmpty {
            pending.append(PendingEmission(
                sessionRank: sessionRank(scheduled.session), session: scheduled.session,
                ordering: scheduled.ordering, type: scheduled.type, originRuleId: scheduled.originRuleId,
                content: scheduled.content, repetitions: nil, spacingMinutes: nil, listenCount: nil,
                window: nil, infoOnly: false, extraFlags: [],
                estMinutesOverride: scheduled.estMinutesOverride))
        }
        for item in distributedToday {
            let distribution = distributions[item.distributionIndex]
            pending.append(PendingEmission(
                sessionRank: sessionRank(distribution.session), session: distribution.session,
                ordering: distribution.ordering, type: distribution.type, originRuleId: distribution.originRuleId,
                content: item.slice, repetitions: nil, spacingMinutes: nil, listenCount: nil,
                window: nil, infoOnly: false, extraFlags: [],
                estMinutesOverride: distribution.estMinutesOverride))
        }

        // --- Order, uid, materialize.
        pending.sort { a, b in
            if a.sessionRank != b.sessionRank { return a.sessionRank < b.sessionRank }
            if a.ordering != b.ordering { return a.ordering < b.ordering }
            return a.originRuleId.utf8.lexicographicallyPrecedes(b.originRuleId.utf8)
        }
        var occurrenceCounters: [String: Int] = [:]
        var tasks: [TaskInstance] = []
        for emission in pending {
            let occurrenceKey = "\(emission.session)|\(emission.originRuleId)"
            let occurrence = occurrenceCounters[occurrenceKey, default: 0]
            occurrenceCounters[occurrenceKey] = occurrence + 1
            let uid = UUIDv5.uuid(
                namespace: context.planIdBytes,
                name: "\(date.isoString)|\(emission.session)|\(emission.originRuleId)|\(occurrence)")
            var flags = baseFlags()
            flags.append(contentsOf: emission.extraFlags)
            tasks.append(TaskInstance(
                date: date,
                dayClass: dayClassName,
                session: emission.session,
                ordering: emission.ordering,
                type: emission.type,
                originRuleId: emission.originRuleId,
                occurrence: occurrence,
                content: contentRanges(emission.content),
                repetitions: emission.repetitions,
                spacingMinutes: emission.spacingMinutes,
                listenCount: emission.listenCount,
                window: emission.window.map { (opensOn: $0.0, closesOn: $0.1) },
                estimatedMinutes: estimateMinutes(
                    type: emission.type, content: emission.content,
                    repetitions: emission.repetitions, listenCount: emission.listenCount,
                    estMinutesOverride: emission.estMinutesOverride, on: date),
                // §11.5: info_only tasks serialize an empty evidence field.
                evidence: emission.infoOnly ? nil : resolveEvidence(type: emission.type, resolver: resolver, policy: policy, on: date),
                flags: flags.sorted(),
                taskUid: uid))
        }

        let deduplicated: TaskDeduplicationResult
        if curriculum.taskDeduplication == .exactExecution {
            deduplicated = TaskDeduplicator.deduplicate(namespace: context.planIdBytes, tasks: tasks)
        } else {
            deduplicated = TaskDeduplicationResult(output: tasks, stateTasks: tasks)
        }
        let outputTasks = deduplicated.output
        let stateTasks = deduplicated.stateTasks

        // --- Fold the day's outcomes into state.
        func isCompleted(_ task: TaskInstance) -> Bool {
            if actualMode {
                return folded.completions[task.taskUid] != nil
            }
            return true  // projection mode: every emitted content task completes
        }

        // E-4b (D-046): under require_verified a completed-but-UNVERIFIED portion
        // is a teacher REJECTION (mardūd) and must not advance. Projection assumes
        // every day passes (else a forecast could never progress).
        func isPass(_ task: TaskInstance) -> Bool {
            guard curriculum.requireVerified, actualMode else { return isCompleted(task) }
            return folded.completions[task.taskUid]?.teacherVerified == true
        }

        // New-ḥifẓ ledger, cursor, boundary triggers.
        if let selection = newSelection,
           let newTask = stateTasks.first(where: { $0.type == "new_hifz" }) {
            if isPass(newTask) {
                ledger[date, default: OrderSpanSet()].formUnion(selection.span)
                completedOrderSet.formUnion(selection.span)
                completedGlobalSet.formUnion(globalSpanSet(fromOrder: selection.span))
                cursorPos = selection.nextCursor
                if var redistribute = redistribution, redistributionExtra > 0 {
                    redistribute.remainingMicropages = max(0, redistribute.remainingMicropages - redistributionExtra)
                    redistribution = redistribute
                    dischargeDebt(redistributionExtra) // D-049: the extra IS the catch-up
                }
                try fireBoundaryTriggers(on: date, policy: policy, resolver: resolver)
                checkTargetCompletion(on: date)
            } else if actualMode, date < today, !folded.excused.contains(newTask.taskUid) {
                // D-048: a fail becomes debt — missed, unmastered or mardūd alike.
                debtMissedNew.append((date: date, span: selection.span,
                                      owedMp: selection.span.sum { self.weightOfOrderPos($0) }))
            }
        }

        if let selection = readingSelection,
           let readingTask = stateTasks.first(where: { $0.type == "tilawah" }),
           isCompleted(readingTask) {
            // Tilawah advances only its sequential cursor. It never enters any
            // hifz ledger, completion map, murajaah pool, or boundary trigger.
            cursorPos = selection.nextCursor
        }

        // Each murājaʿah layer's cursor advances only when its own task
        // completes (actual mode) or unconditionally in projection mode (§4).
        // E-1: keyed by rule id so layers advance independently.
        for advance in pendingRotationAdvances {
            if let task = stateTasks.first(where: { $0.originRuleId == advance.ruleId }),
               isCompleted(task) {
                rotationCursors[advance.ruleId] = advance.nextCursor
            }
        }

        // E-5 (D-047): a `task_failed` trigger fires when the task its rule
        // emitted today was NOT verified. Only on a CLOSED day — an open day's
        // test has not been sat yet, and a projected day is assumed to pass
        // (§8/D-043, the same principle as debt).
        if date < today {
            for trigger in curriculum.triggers {
                guard case .taskFailed(let ruleId) = trigger.on else { continue }
                for task in stateTasks where task.originRuleId == ruleId {
                    let record = folded.completions[task.taskUid]
                    if record?.teacherVerified == true || folded.excused.contains(task.taskUid) { continue }
                    // No juz is involved in a task_failed fire; only insert_week
                    // effects are meaningful here (schedule effects would need a
                    // completed juz), so completedJuz is a don't-care.
                    try applyTriggerEffects(trigger, completedJuz: 0, on: date, policy: policy, resolver: resolver)
                }
            }
        }

        // Recovery applications activating today (redistribute policy only).
        for application in folded.recoveryApplications where application.date == date {
            if case .redistribute(let days, let maxExtra) = policy.recoveryPolicy, days > 0 {
                let debtMicropages = debtMissedNew.reduce(Int64(0)) { $0 + $1.owedMp }
                if debtMicropages > 0 {
                    redistribution = Redistribution(
                        remainingMicropages: debtMicropages,
                        daysLeft: days,
                        maxExtraMicropages: maxExtra?.micropages)
                }
            }
        }

        return outputTasks
    }

    /// H-5: union of every warm-up window whose rule EMITS today — the pool
    /// subtracts what warm-up actually covers today (§4 "no double coverage").
    /// Empty on days with no warm-up. Mirrors `evaluateRule`'s match gate.
    func warmupSubtractForDay(
        date: LocalDate, dayClassName: String, firstActiveDay: Bool,
        consWeek: ConsolidationWeek?, resolver: VariableResolver
    ) -> OrderSpanSet {
        let curriculum = cur(date)  // PC-4: per-date curriculum resolution.
        var subtract = OrderSpanSet()
        for rule in curriculum.rules where rule.emit.type == "warmup" {
            guard rule.when.dayClasses.contains(dayClassName),
                  curriculum.sessionIds.contains(rule.when.session) else { continue }
            if let enabledVar = rule.when.enabledVar, resolver.bool(enabledVar) != true { continue }
            if let dayIn = rule.when.dayIn {
                guard let set = resolver.weekdaySet(dayIn), set.contains(date.weekday) else { continue }
            }
            var skip = false
            for condition in rule.when.notConditions {
                switch condition {
                case .firstActiveDay: if firstActiveDay { skip = true }
                case .inConsolidationWeek: if consWeek != nil { skip = true }
                case .hasFlag: skip = true
                }
            }
            if skip { continue }
            guard let selectRef = rule.emit.select else { continue }
            let spec: SelectorSpec?
            switch selectRef {
            case .named(let name): spec = curriculum.selectors[name]
            case .inline(let inline): spec = inline
            }
            guard case .ledgerWindow(let daysRef, let sundayRef)? = spec,
                  let days = resolver.int(daysRef) else { continue }
            subtract.formUnion(warmupWindow(on: date, days: days, sundayDays: resolver.int(sundayRef)))
        }
        return subtract
    }

    /// Default warm-up window parameters (legacy single-window helper; retained
    /// for callers other than the murājaʿah pool subtraction). Currently
    /// unused (no call sites) — `date` is threaded anyway (PC-4) so a future
    /// caller reads the per-date curriculum by construction rather than
    /// silently defaulting back to `baseCurriculum`.
    func defaultWarmupWindow(resolver: VariableResolver, on date: LocalDate) -> (days: Int, sundayDays: Int?) {
        let curriculum = cur(date)
        for name in curriculum.selectors.keys.sorted() {
            if case .ledgerWindow(let daysRef, let sundayRef) = curriculum.selectors[name]! {
                if let days = resolver.int(daysRef) {
                    return (days, resolver.int(sundayRef))
                }
            }
        }
        return (7, 14)
    }

    // MARK: listening (R-L1, GX-15, ENGINE_SEMANTICS §7)

    func listeningTarget(
        on date: LocalDate,
        policy: PlanPolicy,
        resolver: VariableResolver,
        consWeek: ConsolidationWeek?,
        todaysSelection: NewSelection? = nil
    ) throws -> OrderSpanSet? {
        guard !planCompleted else { return nil }
        // Cursor after D, assuming D's new material completes. D's material is
        // what R-N1 actually EMITTED today (incl. any redistribute boost) —
        // §11.9's ignore-extras rule applies to E only (2026-07-13 audit AX-02).
        var cursorAfter = cursorPos
        if newHifzEmits(on: date, policy: policy, consWeek: consolidationWeeks.first { $0.contains(date) }) {
            let selection = try todaysSelection ?? selectNextNew(fromPos: cursorPos, amount: policy.newAmount)
            if let selection {
                cursorAfter = selection.nextCursor
            }
        }
        // Next day E > D where R-N1 actually emits; look ahead ≤ 14 days.
        for offset in 1...14 {
            let e = date.adding(days: offset)
            let policyE = effectivePolicy(on: e)
            let weekE = consolidationWeeks.first { $0.contains(e) }
            guard newHifzEmits(on: e, policy: policyE, consWeek: weekE) else { continue }
            guard let selection = try selectNextNew(fromPos: cursorAfter, amount: policyE.newAmount) else { return nil }
            return selection.span
        }
        return nil
    }

    /// Whether the curriculum's new_hifz rule emits on `date` (weekday-class
    /// day, not exception, not paused, not suppressed by a pause_new week).
    func newHifzEmits(on date: LocalDate, policy: PlanPolicy, consWeek: ConsolidationWeek?) -> Bool {
        guard !isPaused(date), exceptionClass(on: date) == nil,
              let className = dayClass(on: date)
        else { return false }
        if let week = consWeek, week.mode == "pause_new" { return false }
        for rule in cur(date).rules where rule.emit.type == "new_hifz" {
            if rule.when.dayClasses.contains(className) {
                if rule.when.notConditions.contains(.firstActiveDay) && date == anchor { continue }
                return true
            }
        }
        return false
    }

    // MARK: boundary triggers (R-J1/R-J2/R-C1, ENGINE_SEMANTICS §5/§6)

    mutating func fireBoundaryTriggers(on date: LocalDate, policy: PlanPolicy, resolver: VariableResolver) throws {
        // In-plan completions only; declared prior ḥifẓ never fires triggers.
        // Guarded against `boundaryCount == 0` (Stage 2 ground truth: a
        // `1...0` ClosedRange traps at construction in Swift). QuranIndex can
        // never actually produce 0 today, but a ContentIndex conformer is not
        // guaranteed to re-establish that invariant, so this is defensive by
        // construction rather than by (undocumented) corpus assumption —
        // mirrors ProgressQueries.swift's `max(count, 1)` guard pattern.
        var newlyCompletedJuz: [Int] = []
        if index.boundaryCount >= 1 {
            for juz in 1...index.boundaryCount where !firedJuz.contains(juz) {
                guard let range = index.boundaryGlobalRange(juz) else { continue }
                if OrderSpanSet(span: range).subtracting(completedGlobalSet).isEmpty {
                    newlyCompletedJuz.append(juz)
                }
            }
        }
        for juz in newlyCompletedJuz {
            firedJuz.insert(juz)
            firedJuzSequence.append(juz)
            juzCompletedCount += 1
            for trigger in cur(date).triggers {
                guard case .boundary(let kind, let everyRef) = trigger.on, kind == "juz" else { continue }
                let every = resolver.int(everyRef) ?? 1
                guard every > 0, juzCompletedCount % every == 0 else { continue }
                try applyTriggerEffects(trigger, completedJuz: juz, on: date, policy: policy, resolver: resolver)
            }
        }
    }

    mutating func applyTriggerEffects(
        _ trigger: TriggerSpec,
        completedJuz juz: Int,
        on date: LocalDate,
        policy: PlanPolicy,
        resolver: VariableResolver
    ) throws {
        for (effectIndex, effect) in trigger.effects.enumerated() {
            switch effect {
            case .schedule(let type, let select, let distributeOverDays, let intoSession, _, _, let estMinutes):
                let selector: SelectorSpec?
                switch select {
                case .named(let name): selector = cur(date).selectors[name]
                case .inline(let spec): selector = spec
                }
                guard let spec = selector else { continue }
                // §11.2: origin = "{trigger_id}.{task_type}", ordering = 90 +
                // effect index within the trigger, into_session defaults to morning.
                let originRuleId = "\(trigger.id).\(type)"
                let ordering = 90 + effectIndex
                let session = intoSession ?? "morning"

                switch spec {
                case .completedJuz:
                    // (a) whole just-completed juz on the next active day.
                    guard let range = index.boundaryGlobalRange(juz) else { continue }
                    var content = OrderSpanSet()
                    for g in range {
                        if let p = order.orderPosition(ofGlobal: g) { content.insert(p..<(p + 1)) }
                    }
                    if let day = nextActiveDay(after: date, policy: policy), !content.isEmpty {
                        scheduledJuzReviews[day, default: []].append(ScheduledTask(
                            content: content, type: type, originRuleId: originRuleId,
                            ordering: ordering, session: session, estMinutesOverride: estMinutes))
                    }
                case .priorHifzSplit(let parts):
                    // (b) prior ḥifẓ (in-plan + declared, excluding juz `juz`;
                    // same-day overshoot included, §11.14), near-equal µp
                    // slices over the next `distribute_over_days` calendar
                    // days, skipping exception/paused days and days already
                    // occupied by an earlier distribution (§11.11).
                    var juzSet = OrderSpanSet()
                    if let range = index.boundaryGlobalRange(juz) {
                        for g in range {
                            if let p = order.orderPosition(ofGlobal: g) { juzSet.insert(p..<(p + 1)) }
                        }
                    }
                    let pool = declaredOrderSet.union(completedOrderSet).subtracting(juzSet)
                    guard !pool.isEmpty else { continue }
                    let count = distributeOverDays ?? parts
                    let slices = splitNearEqual(pool, parts: count)
                    let occupied = Set(distributions.flatMap(\.dates))
                    var dates: [LocalDate] = []
                    var d = date
                    while dates.count < count {
                        d = d.adding(days: 1)
                        if exceptionClass(on: d) == nil && !isPaused(d) && !occupied.contains(d) {
                            dates.append(d)
                        }
                        if d > date.adding(days: 366) { break }
                    }
                    guard dates.count == count else { continue }
                    distributions.append(Distribution(
                        slices: slices, dates: dates, type: type,
                        originRuleId: originRuleId, ordering: ordering, session: session,
                        estMinutesOverride: estMinutes))
                default:
                    continue
                }

            case .insertWeek(_, let modeVar, let dayRules):
                // R-J2 (D-010/D-017): consolidation week = next full week after
                // any pending distribution finishes.
                let mode = modeVar.flatMap { resolver.string($0) }
                    ?? policy.cycleWeekMode
                    ?? "pause_new"
                var candidate = nextWeekStart(strictlyAfter: date)
                let lastDistributionDay = distributions.flatMap(\.dates).max()
                if let last = lastDistributionDay {
                    while candidate <= last { candidate = candidate.adding(days: 7) }
                }
                // Block = the last `cycle` completed juz, memorization-ordered.
                let cycleLength = cycleLengthJuz(trigger: trigger, resolver: resolver)
                let blockJuz = Array(firedJuzSequence.suffix(cycleLength)).sorted { a, b in
                    juzOrderKey(a) < juzOrderKey(b)
                }
                let isFailureWeek: Bool
                if case .taskFailed = trigger.on { isFailureWeek = true } else { isFailureWeek = false }
                consolidationWeeks.append(ConsolidationWeek(
                    start: candidate,
                    end: candidate.adding(days: 6),
                    mode: mode,
                    triggerId: trigger.id,
                    dayRules: dayRules,
                    blockJuz: blockJuz,
                    isFailure: isFailureWeek))
                cycleWeeksScheduled += 1

            case .completePlan:
                break  // handled by checkTargetCompletion()

            case .setFlag, .clearFlag:
                break  // Custom flags are unsupported.
            }
        }
    }

    func cycleLengthJuz(trigger: TriggerSpec, resolver: VariableResolver) -> Int {
        if case .boundary(_, let everyRef) = trigger.on, let every = resolver.int(everyRef) {
            return every
        }
        // E-5 (D-047): a pure pause week has no block to size.
        if case .taskFailed = trigger.on { return 0 }
        return 5
    }

    /// Sort key ordering juz blocks by memorization order (mushaf-forward:
    /// ascending juz; juz-ʿamma-backward: descending juz).
    func juzOrderKey(_ juz: Int) -> Int {
        guard let range = index.boundaryGlobalRange(juz),
              let pos = order.orderPosition(ofGlobal: range.lowerBound) else { return Int.max }
        return pos
    }

    func nextWeekStart(strictlyAfter date: LocalDate) -> LocalDate {
        var delta = (cur(date).weekStart.rawValue - date.weekday.rawValue + 7) % 7
        if delta == 0 { delta = 7 }
        return date.adding(days: delta)
    }

    mutating func checkTargetCompletion(on date: LocalDate) {
        let hasTargetTrigger = cur(date).triggers.contains { trigger in
            if case .boundary(let kind, _) = trigger.on, kind == "target" { return true }
            return false
        }
        guard hasTargetTrigger else { return }
        let remaining: Bool
        if let target = targetSet {
            remaining = target.firstPosition(atOrAfter: cursorPos) != nil
        } else {
            remaining = cursorPos < order.count
        }
        if !remaining { planCompleted = true }
    }

    // MARK: consolidation-week block slices

    func blockSliceContent(
        week: ConsolidationWeek,
        of selectorName: String,
        parts: Int,
        date: LocalDate,
        resolver: VariableResolver
    ) -> OrderSpanSet? {
        let curriculum = cur(date)  // PC-4: per-date curriculum resolution.
        guard case .block? = curriculum.selectors[selectorName] else { return nil }
        guard !week.blockJuz.isEmpty else { return nil }
        // Slice index = position of `date` among the week's weekday-class days
        // Use the weekdays of this day class.
        guard let className = dayClass(on: date), let classDays = curriculum.dayClasses[className] else { return nil }
        var sliceIndex = 0
        var d = week.start
        while d < date {
            if exceptionClass(on: d) == nil, let cls = dayClass(on: d), cls == className, classDays.contains(d.weekday) {
                sliceIndex += 1
            }
            d = d.adding(days: 1)
        }
        guard sliceIndex < parts else { return nil }

        if week.blockJuz.count == parts {
            // One juz per weekday (ENGINE_SEMANTICS §6).
            let juz = week.blockJuz[sliceIndex]
            guard let range = index.boundaryGlobalRange(juz) else { return nil }
            var content = OrderSpanSet()
            for g in range {
                if let p = order.orderPosition(ofGlobal: g) { content.insert(p..<(p + 1)) }
            }
            return content
        }
        // Fallback: near-equal µp split of the whole block.
        var block = OrderSpanSet()
        for juz in week.blockJuz {
            guard let range = index.boundaryGlobalRange(juz) else { continue }
            for g in range {
                if let p = order.orderPosition(ofGlobal: g) { block.insert(p..<(p + 1)) }
            }
        }
        let slices = splitNearEqual(block, parts: parts)
        return sliceIndex < slices.count ? slices[sliceIndex] : nil
    }

    /// Whole-block content for `block` selectors evaluated inside a
    /// consolidation week (cyc_we day rule).
    func blockContent(week: ConsolidationWeek) -> OrderSpanSet {
        var block = OrderSpanSet()
        for juz in week.blockJuz {
            guard let range = index.boundaryGlobalRange(juz) else { continue }
            for g in range {
                if let p = order.orderPosition(ofGlobal: g) { block.insert(p..<(p + 1)) }
            }
        }
        return block
    }

    // MARK: date helpers

    func latestDate(withWeekday weekday: Weekday, atOrBefore date: LocalDate) -> LocalDate {
        let delta = (date.weekday.rawValue - weekday.rawValue + 7) % 7
        return date.adding(days: -delta)
    }

    func earliestDate(withWeekday weekday: Weekday, atOrAfter date: LocalDate) -> LocalDate {
        let delta = (weekday.rawValue - date.weekday.rawValue + 7) % 7
        return date.adding(days: delta)
    }

    func micropagesToPageDecimal(_ micropages: Int64) -> String {
        let whole = micropages / Micropage.perPage
        let frac = micropages % Micropage.perPage
        if frac == 0 { return String(whole) }
        var fracString = String(frac)
        while fracString.count < 6 { fracString = "0" + fracString }
        while fracString.hasSuffix("0") { fracString.removeLast() }
        return "\(whole).\(fracString)"
    }
}
