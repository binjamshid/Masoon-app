import MasoonDomain

/// Pure forecaster (PRD §7.10, T-015a).
///
/// The forecast IS `Engine.generate` run forward in projection mode — there is
/// no parallel scheduling model (AC-5.4: the pre-confirmation diff and the
/// post-confirmation regeneration are the same engine call on the same
/// inputs). Every workload number is the engine-stamped `estimated_minutes`
/// (ENGINE_SEMANTICS §1/§11.3); the forecaster only sums, groups, and diffs.
/// Deterministic: same inputs → identical result; integer math only; no wall
/// clock, RNG, locale, or I/O.
///
/// AC-O4: onboarding comparison figures come from this forecaster.

// MARK: - Result types

/// Assumed adherence for projected days (PRD §7.10 "honest mode").
public enum AdherenceMode: Hashable, Sendable {
    /// Every projected task completes (engine projection default).
    case full
    /// Thin the assumed completion of the daily new-ḥifẓ task to `rate`
    /// basis points (0...10000; e.g. trailing-28-day actual adherence).
    ///
    /// Deterministic integer thinning — no randomness, no opaque heuristics:
    /// the projection day at offset `k` (`date == today + k`, k ≥ 1) keeps its
    /// new-ḥifẓ completion iff
    ///
    ///     (k × rate) / 10000  ≠  ((k − 1) × rate) / 10000     (integer division)
    ///
    /// so over any prefix of n projection days exactly ⌊n × rate / 10000⌋
    /// new-ḥifẓ completions are assumed. A thinned day folds exactly like a
    /// real missed day under strict backlog: the cursor stalls, the ledger has
    /// a gap (warm-up/takrār shrink automatically), and the same content is
    /// re-selected on the next kept day. Thinning applies to new-ḥifẓ only;
    /// murājaʿah is still assumed done (its misses create no content debt,
    /// PRD §7.9).
    case trailingActual(rateBasisPoints: Int)
}

/// One projected day's workload (engine-stamped minutes, summed by task type).
public struct DayLoad: Hashable, Sendable {
    public let date: LocalDate
    public let estimatedMinutes: Int
    public let byType: [String: Int]

    public init(date: LocalDate, estimatedMinutes: Int, byType: [String: Int]) {
        self.date = date
        self.estimatedMinutes = estimatedMinutes
        self.byType = byType
    }
}

/// Weekly murājaʿah-family burden: average minutes per day of
/// murajaah + juz_review_distributed + cycle_consolidation over the days of
/// the week that fall inside the projection horizon (round-half-up).
public struct WeekBurden: Hashable, Sendable {
    public let weekStart: LocalDate
    public let avgMinutes: Int

    public init(weekStart: LocalDate, avgMinutes: Int) {
        self.weekStart = weekStart
        self.avgMinutes = avgMinutes
    }
}

/// In-plan cumulative content covered a whole juz on `date` (declared prior
/// ḥifẓ never counts, matching R-J1 trigger semantics). Projection dates only.
public struct JuzMilestone: Hashable, Sendable {
    public let juz: Int
    public let date: LocalDate

    public init(juz: Int, date: LocalDate) {
        self.juz = juz
        self.date = date
    }
}

public enum CapacitySeverity: String, Hashable, Sendable {
    /// estimated > declared (over 100%)
    case warn
    /// estimated > 150% of declared
    case severe
}

/// A maximal run of consecutive calendar days sharing the same severity whose
/// estimated total exceeds the declared daily availability.
public struct CapacityWarning: Hashable, Sendable {
    public let startDate: LocalDate
    public let endDate: LocalDate
    /// Peak estimated daily minutes within the range.
    public let estimatedMinutes: Int
    public let declaredAvailableMinutes: Int
    public let severity: CapacitySeverity

    public init(
        startDate: LocalDate,
        endDate: LocalDate,
        estimatedMinutes: Int,
        declaredAvailableMinutes: Int,
        severity: CapacitySeverity
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.estimatedMinutes = estimatedMinutes
        self.declaredAvailableMinutes = declaredAvailableMinutes
        self.severity = severity
    }
}

/// Diff between applying the plan's recovery policy tomorrow vs staying on
/// strict backlog (PRD §5.5): produced by running the same forecast twice —
/// once with a projected `plan.recovery_applied` event effective tomorrow,
/// once without — and diffing (AC-5.4: identical to what confirming in the
/// Recovery Center regenerates).
public struct RecoveryImpact: Hashable, Sendable {
    /// Days the strict path finishes later than the recovery path
    /// (0 when either completion date is outside the horizon).
    public let slipDays: Int
    /// Average extra minutes on days where the recovery path is heavier
    /// (round-half-up over positive-delta days; 0 when none).
    public let extraDailyMinutes: Int
    /// Distinct curriculum weeks containing at least one positive-delta day.
    public let weeksAffected: Int

    public init(slipDays: Int, extraDailyMinutes: Int, weeksAffected: Int) {
        self.slipDays = slipDays
        self.extraDailyMinutes = extraDailyMinutes
        self.weeksAffected = weeksAffected
    }
}

/// Candidate-policy comparison (AC-6 plan-change preview): the candidate is
/// applied as a `plan.policy_changed` patch effective tomorrow — exactly the
/// event confirming the wizard would append — and the same forecast is re-run.
public struct ComparisonDelta: Hashable, Sendable {
    /// candidate.completionDate − base.completionDate in days;
    /// nil when either is outside the horizon.
    public let completionDeltaDays: Int?
    /// candidate − base average daily minutes, each averaged from tomorrow
    /// through its own completion date (or the horizon end when incomplete).
    public let avgDailyMinutesDelta: Int
    public let candidateCompletionDate: LocalDate?

    public init(completionDeltaDays: Int?, avgDailyMinutesDelta: Int, candidateCompletionDate: LocalDate?) {
        self.completionDeltaDays = completionDeltaDays
        self.avgDailyMinutesDelta = avgDailyMinutesDelta
        self.candidateCompletionDate = candidateCompletionDate
    }
}

public struct ForecastResult: Sendable, Equatable {
    /// Date the target range finishes (R-C1 flip = the last completed
    /// new-ḥifẓ task's date); nil when completion falls outside the horizon.
    public var completionDate: LocalDate?
    public var juzMilestones: [JuzMilestone]
    /// One entry per projection day (today+1 … today+horizon), dense; days
    /// with no tasks carry 0 minutes.
    public var dailyLoadCurve: [DayLoad]
    public var murajaahBurdenCurve: [WeekBurden]
    public var capacityWarnings: [CapacityWarning]
    public var recoveryImpact: RecoveryImpact?
    public var comparison: ComparisonDelta?

    public init(
        completionDate: LocalDate? = nil,
        juzMilestones: [JuzMilestone] = [],
        dailyLoadCurve: [DayLoad] = [],
        murajaahBurdenCurve: [WeekBurden] = [],
        capacityWarnings: [CapacityWarning] = [],
        recoveryImpact: RecoveryImpact? = nil,
        comparison: ComparisonDelta? = nil
    ) {
        self.completionDate = completionDate
        self.juzMilestones = juzMilestones
        self.dailyLoadCurve = dailyLoadCurve
        self.murajaahBurdenCurve = murajaahBurdenCurve
        self.capacityWarnings = capacityWarnings
        self.recoveryImpact = recoveryImpact
        self.comparison = comparison
    }
}

// MARK: - Forecaster

public enum Forecaster {
    /// Horizon hard cap (≈ 8.2 years of projection).
    public static let maxHorizonDays = 3000

    /// Runs `Engine.generate` forward over today+1 … today+min(horizonDays, 3000)
    /// and aggregates the projected stream. Throws only what the engine/context
    /// throw for invalid inputs; a valid generation context always forecasts.
    public static func forecast(
        context: PlanGenerationContext,
        horizonDays: Int,
        assumedAdherence: AdherenceMode = .full,
        declaredDailyAvailableMinutes: Int? = nil,
        candidate: PlanPolicy? = nil
    ) throws -> ForecastResult {
        let horizon = min(horizonDays, maxHorizonDays)
        guard horizon >= 1 else { return ForecastResult() }

        let base = try projection(
            context: context, horizonDays: horizon, adherence: assumedAdherence, extraEvents: [])

        // PC-3(c): `weekStartDay` groups the WHOLE burden/impact curve under
        // one global weekday. A curriculum switch (D-054) can carry a
        // different `calendar.week_start`, so grouping every date — pre- and
        // post-switch alike — by the BASE curriculum's week start is a
        // documented simplification, not a per-date resolution: it is exactly
        // right while only one curriculum is ever active (every context
        // today), and stays the deliberate, single-horizon choice until a
        // later stage decides whether a burden week should regroup at a
        // switch boundary. Do not silently change this without a D-nnn.
        var result = ForecastResult(
            completionDate: base.completionDate,
            juzMilestones: base.milestones,
            dailyLoadCurve: base.curve,
            murajaahBurdenCurve: murajaahBurden(curve: base.curve, weekStartDay: context.curriculum.weekStart),
            capacityWarnings: declaredDailyAvailableMinutes.map {
                capacityWarnings(curve: base.curve, declared: $0)
            } ?? [])

        // Recovery diff (PRD §5.5): only when the plan carries new-ḥifẓ debt today.
        if try outstandingDebtRanges(context: context) > 0 {
            let recoveryRun = try projection(
                context: context, horizonDays: horizon, adherence: assumedAdherence,
                extraEvents: [recoveryAppliedEvent(context: context)])
            // PC-3(c): same single-global-week-start simplification as above.
            result.recoveryImpact = recoveryImpact(
                strict: base, recovery: recoveryRun, weekStartDay: context.curriculum.weekStart)
        }

        // Candidate comparison (AC-6 preview): candidate policy effective tomorrow.
        if let candidate {
            let candidateRun = try projection(
                context: context, horizonDays: horizon, adherence: assumedAdherence,
                extraEvents: [policyChangedEvent(context: context, candidate: candidate)])
            let delta: Int? = base.completionDate.flatMap { b in
                candidateRun.completionDate.map { $0 - b }
            }
            result.comparison = ComparisonDelta(
                completionDeltaDays: delta,
                avgDailyMinutesDelta: candidateRun.avgActiveDailyMinutes - base.avgActiveDailyMinutes,
                candidateCompletionDate: candidateRun.completionDate)
        }

        return result
    }

    // MARK: - One projection run

    struct ProjectionOutcome {
        let completionDate: LocalDate?
        let milestones: [JuzMilestone]
        /// Dense: one entry per date in today+1 … today+horizon.
        let curve: [DayLoad]
        /// Average daily minutes from tomorrow through completion (or horizon
        /// end when incomplete), round-half-up.
        let avgActiveDailyMinutes: Int
    }

    /// One `Engine.generate` pass plus stream aggregation. `extraEvents` are
    /// projected events (recovery application / candidate policy patch) that a
    /// confirmation would append for real — the AC-5.4 equivalence mechanism.
    static func projection(
        context: PlanGenerationContext,
        horizonDays: Int,
        adherence: AdherenceMode,
        extraEvents: [PlanEvent]
    ) throws -> ProjectionOutcome {
        let today = context.today
        let horizonEnd = today.adding(days: horizonDays)
        let anchor = context.calendar.anchorDate
        let windowFrom = min(anchor, today.adding(days: 1))

        // Effective engine input. `.trailingActual` moves the engine's `today`
        // to the horizon end and supplies explicit assumed-completion events,
        // because projection mode unconditionally assumes completion; actual
        // mode reads the event fold — the identical code path real history uses.
        let engineContext: PlanGenerationContext
        switch adherence {
        case .full:
            engineContext = extraEvents.isEmpty ? context : try rebuilt(
                context, events: context.events + extraEvents, today: today)
        case .trailingActual(let rate):
            let assumed = assumedCompletionEvents(
                context: context, horizonDays: horizonDays, rateBasisPoints: rate)
            engineContext = try rebuilt(
                context, events: context.events + extraEvents + assumed, today: horizonEnd)
        }

        let generated = try Engine.generate(
            context: engineContext,
            window: GenerationWindow(from: windowFrom, to: horizonEnd))
        let folded = EventFold.fold(engineContext.events)

        // Milestone bookkeeping: cumulative in-plan coverage per juz.
        let index = context.quranIndex
        var covered = [Bool](repeating: false, count: index.totalUnits)
        var remaining = [Int](repeating: 0, count: index.boundaryCount + 1)
        // Guarded against `boundaryCount == 0` — see Engine.swift's
        // fireBoundaryTriggers for the same `1...0` ClosedRange trap note.
        if index.boundaryCount >= 1 {
            for juz in 1...index.boundaryCount {
                remaining[juz] = index.boundaryGlobalRange(juz)?.count ?? 0
            }
        }

        var milestones: [JuzMilestone] = []
        var lastCompletedNewHifz: LocalDate? = nil
        var totalsByDate: [LocalDate: (total: Int, byType: [String: Int])] = [:]

        for task in generated.tasks {
            if task.date > today {
                var entry = totalsByDate[task.date] ?? (0, [:])
                entry.total += task.estimatedMinutes
                entry.byType[task.type, default: 0] += task.estimatedMinutes
                totalsByDate[task.date] = entry
            }
            guard task.type == "new_hifz" else { continue }
            // Completed ⟺ projection-assumed (date beyond the engine's today)
            // or a folded `task.completed` exists (actual/assumed events).
            let completed = task.date > engineContext.today || folded.completions[task.taskUid] != nil
            guard completed else { continue }
            lastCompletedNewHifz = task.date
            for range in task.content {
                guard let globals = index.globalRange(of: range) else { continue }
                for g in globals where !covered[g] {
                    covered[g] = true
                    let juz = index.boundaryOfGlobal(g)
                    remaining[juz] -= 1
                    if remaining[juz] == 0, task.date > today {
                        milestones.append(JuzMilestone(juz: juz, date: task.date))
                    }
                }
            }
        }

        // R-C1 read-through: the engine's completed status is authoritative;
        // its flip date is the last completed new-ḥifẓ task's date.
        let completionDate: LocalDate? =
            generated.finalState.status == .completed ? lastCompletedNewHifz : nil

        var curve: [DayLoad] = []
        curve.reserveCapacity(horizonDays)
        for offset in 1...horizonDays {
            let date = today.adding(days: offset)
            let entry = totalsByDate[date] ?? (0, [:])
            curve.append(DayLoad(date: date, estimatedMinutes: entry.total, byType: entry.byType))
        }

        // Average active-day minutes: tomorrow → completion (or horizon end).
        var activeEnd = horizonEnd
        if let done = completionDate {
            activeEnd = max(min(done, horizonEnd), today.adding(days: 1))
        }
        var activeTotal: Int64 = 0
        for load in curve where load.date <= activeEnd {
            activeTotal += Int64(load.estimatedMinutes)
        }
        let activeDays = Int64(activeEnd - today)
        let avg = activeDays > 0 ? Int(Micropage.roundHalfUp(activeTotal, activeDays)) : 0

        return ProjectionOutcome(
            completionDate: completionDate,
            milestones: milestones,
            curve: curve,
            avgActiveDailyMinutes: avg)
    }

    // MARK: - Adherence thinning (assumed-completion events)

    /// Only two task types fold state on completion: `new_hifz` (ledger,
    /// cursor, boundary triggers, R-C1) and `murajaah` (rotation cursor).
    /// The thinned projection therefore assumes murājaʿah always completes
    /// and new-ḥifẓ completes only on kept days per the documented formula.
    static func assumedCompletionEvents(
        context: PlanGenerationContext,
        horizonDays: Int,
        rateBasisPoints: Int
    ) -> [PlanEvent] {
        let rate = max(0, min(10_000, rateBasisPoints))

        struct Classified {
            var newHifzRules: [(session: String, id: String)] = []
            var murajaahRules: [(session: String, id: String)] = []
        }
        func classify(_ curriculum: CompiledCurriculum) -> Classified {
            var out = Classified()
            func addRule(_ rule: RuleSpec) {
                switch rule.emit.type {
                case "new_hifz": out.newHifzRules.append((rule.when.session, rule.id))
                case "murajaah": out.murajaahRules.append((rule.when.session, rule.id))
                default: break
                }
            }
            for rule in curriculum.rules { addRule(rule) }
            for trigger in curriculum.triggers {
                for effect in trigger.effects {
                    if case .insertWeek(_, _, let dayRules) = effect {
                        for rule in dayRules { addRule(rule) }
                    }
                }
            }
            return out
        }

        // PC-3(b): classify against the curriculum ACTIVE on each projected
        // date (D-054 `curriculumTimeline`), not unconditionally against the
        // base curriculum — once multiple curricula can be active, a date
        // past an `effective_from` boundary must assume completions against
        // ITS curriculum's rule ids (`new_hifz`/`murajaah` origin_rule_ids
        // are curriculum-specific, so classifying against the wrong
        // curriculum would synthesize `task.completed` events for uids the
        // post-switch engine run never emits). For every real context today
        // `curriculumTimeline` is empty, so `resolve(on:timeline:)` returns
        // `base` on every date — byte-identical to the pre-PC-3 single
        // classify() call this replaces.
        let timeline = EventFold.fold(context.events).curriculumTimeline
        // Cache by slug: within one forecast run the resolver only ever
        // returns `base` or a fixed `byKey` entry for a given slug, so this
        // is a pure perf memoization (avoids re-scanning rules/triggers on
        // every one of up to 3000 horizon days), never a correctness
        // dependency.
        var cache: [String: Classified] = [:]
        func classified(on date: LocalDate) -> Classified {
            let curriculum = context.curriculumSet.resolve(on: date, timeline: timeline)
            if let hit = cache[curriculum.slug] { return hit }
            let result = classify(curriculum)
            cache[curriculum.slug] = result
            return result
        }

        var events: [PlanEvent] = []
        var seq: Int64 = 1
        func append(date: LocalDate, session: String, ruleId: String) {
            // occurrence is always 0 for daily-rule emissions (one evaluation
            // per rule per day; ENGINE_SEMANTICS §10).
            let uid = UUIDv5.uuid(
                namespace: context.planIdBytes,
                name: "\(date.isoString)|\(session)|\(ruleId)|0")
            events.append(PlanEvent(
                eventId: "forecast-assumed-\(seq)",
                type: PlanEventType.taskCompleted,
                serverSeq: nil,
                // "~" sorts after alphanumeric device ids, so assumed events
                // fold after any real local-unacked events.
                deviceId: "~masoon-forecast",
                clientSeq: seq,
                occurredAtLocal: "\(date.isoString)T23:59:00+00:00",
                payload: .object([
                    "task_uid": .string(uid),
                    "date": .string(date.isoString),
                    "evidence": .object(["kind": .string("self_check")]),
                ])))
            seq += 1
        }

        for k in 1...horizonDays {
            let date = context.today.adding(days: k)
            let keep = Int64(k) * Int64(rate) / 10_000 != Int64(k - 1) * Int64(rate) / 10_000
            let c = classified(on: date)
            for rule in c.murajaahRules { append(date: date, session: rule.session, ruleId: rule.id) }
            if keep {
                for rule in c.newHifzRules { append(date: date, session: rule.session, ruleId: rule.id) }
            }
        }
        return events
    }

    // MARK: - Projected events (recovery / candidate policy)

    /// Missed-new debt records outstanding at `today` (engine-derived).
    static func outstandingDebtRanges(context: PlanGenerationContext) throws -> Int {
        guard context.today >= context.calendar.anchorDate else { return 0 }
        let history = try Engine.generate(
            context: context,
            window: GenerationWindow(from: context.calendar.anchorDate, to: context.today))
        return history.finalState.debtNewRanges
    }

    static func recoveryAppliedEvent(context: PlanGenerationContext) -> PlanEvent {
        let effective = context.today.adding(days: 1)
        return PlanEvent(
            eventId: "forecast-recovery-preview",
            type: PlanEventType.planRecoveryApplied,
            serverSeq: nil,
            deviceId: "~masoon-forecast",
            clientSeq: Int64.max - 1,
            occurredAtLocal: "\(context.today.isoString)T23:59:00+00:00",
            payload: .object(["effective_from": .string(effective.isoString)]))
    }

    /// PC-10: `effective`/`eventId`/`deviceId` are optional so this stays the
    /// exact byte-identical call `Forecaster.forecast(candidate:)` already
    /// made (`effective` defaulting to `today+1`, the original hardcoded
    /// value) while giving `PlanChangeDiff` (MasoonCurriculum) a way to reuse
    /// this SAME patch-serialization/event-shape logic with an explicit,
    /// caller-chosen effective date instead — `PlanChangeDiff` must never go
    /// through the `today+1`-hardcoded default path (that hardcoding is
    /// exactly why it cannot call `Forecaster.forecast(candidate:)` itself
    /// for its candidate side; see PlanChangeDiff.swift's header comment).
    static func policyChangedEvent(
        context: PlanGenerationContext,
        candidate: PlanPolicy,
        effective: LocalDate? = nil,
        eventId: String = "forecast-candidate-preview",
        deviceId: String = "~masoon-forecast"
    ) -> PlanEvent {
        let effectiveDate = effective ?? context.today.adding(days: 1)
        return PlanEvent(
            eventId: eventId,
            type: PlanEventType.planPolicyChanged,
            serverSeq: nil,
            deviceId: deviceId,
            clientSeq: Int64.max,
            occurredAtLocal: "\(context.today.isoString)T23:59:00+00:00",
            payload: .object([
                "effective_from": .string(effectiveDate.isoString),
                "patch": policyPatch(candidate),
            ]))
    }

    /// Serializes a candidate policy as a `plan.policy_changed` patch — the
    /// exact payload the plan-change wizard appends on confirm. Only fields
    /// `PlanPolicy.applying(patch:)` supports are expressed (target range,
    /// memorization order, and session structure change via other flows,
    /// AC-6.2); derive candidates from the current policy.
    public static func policyPatch(_ policy: PlanPolicy) -> JSONValue {
        func amount(_ a: QuranAmount) -> JSONValue {
            .object(["unit": .string(a.unit.rawValue), "value": .string(decimalString(a.value))])
        }
        func weekdays(_ set: Set<Weekday>) -> JSONValue {
            .array(set.sorted().map { .string($0.code) })
        }
        // PC-6: this function serializes `policy` as a complete snapshot of
        // what the policy SPECIFIES (the candidate becomes exactly this), not
        // a diff — so an empty
        // `variable_overrides`/`evidence_policy` or an absent `murajaahRamp`
        // must actively CLEAR whatever the base context's policy already had
        // there, not silently inherit it. Before PC-6's explicit-null signal
        // there was no way to express that: `.object([:])` iterated zero
        // entries in `applying(patch:)` and left the base's overrides
        // exactly as they were, and an omitted `murajaah_ramp` key did the
        // same for the ramp — a latent candidate-preview bug (harmless for
        // every existing test, whose candidate and base share the same
        // already-empty/already-omitted fields; see ForecasterTests).
        var obj: [String: JSONValue] = [
            "new_amount": amount(policy.newAmount),
            "active_weekdays": weekdays(policy.activeWeekdays),
            // PC-6 wired `sessions`/`separate_session_completion` into
            // `PlanPolicy.applying(patch:)` and `PlannerQueries
            // .policyChangePatch` (the COMMITTED patch) but not into this
            // snapshot — so a candidate whose only edit was a session time
            // previewed as byte-identical to the base and then applied a real
            // change. A preview that cannot see an edit the apply path does
            // see is worse than no preview. Both keys are emitted here now,
            // in the same shapes `applying(patch:)` parses.
            "sessions": .array(policy.sessions.map {
                .object(["id": .string($0.id), "start": .string($0.start)])
            }),
            "separate_session_completion": .bool(policy.separateSessionCompletion),
            "variable_overrides": policy.variableOverrides.isEmpty ? .null : .object(policy.variableOverrides),
            "evidence_policy": policy.evidencePolicy.isEmpty ? .null : .object(policy.evidencePolicy),
        ]
        // §11.21 — the five gated fields are emitted ONLY when this policy
        // actually specified them.
        //
        // Emitting them unconditionally made every candidate preview
        // asymmetric with its own base. `PlanChangeDiff` resolves the base
        // through the plan's real policy (where an onboarding-created plan
        // specifies none of these five, so each falls through to the
        // curriculum's declared default) and the candidate through this
        // patch (where `applying(patch:)` marks every key it sees explicit,
        // so each binds `PlanPolicy`'s STRUCT default instead). On
        // `online-academy` — `takrar_count: 12`, `murajaah_ceiling: 2 pages`
        // — that alone manufactured a takrar 12→5 and a ceiling 2-pages→2-juz
        // difference out of a candidate the learner had not touched, and
        // attributed the resulting minutes swing to whatever they HAD edited.
        // Omitting an unspecified field leaves the base's own value and
        // presence untouched, so untouched fields resolve identically on both
        // sides — which is the only reading under which a diff means anything.
        if policy.explicitPolicyFields.contains("listening_days") {
            obj["listening_days"] = weekdays(policy.listeningDays)
        }
        if policy.explicitPolicyFields.contains("listening_count") {
            obj["listening_count"] = .number(String(policy.listeningCount))
        }
        if policy.explicitPolicyFields.contains("takrar_count") {
            obj["takrar_count"] = .number(String(policy.takrarCount))
        }
        if policy.explicitPolicyFields.contains("takrar_spacing_minutes") {
            obj["takrar_spacing_minutes"] = .number(String(policy.takrarSpacingMinutes))
        }
        if policy.explicitPolicyFields.contains("murajaah_daily_ceiling") {
            obj["murajaah_daily_ceiling"] = amount(policy.murajaahDailyCeiling)
        }
        if let ramp = policy.murajaahRamp {
            obj["murajaah_ramp"] = .object(["start": amount(ramp.start), "step": amount(ramp.step)])
        } else {
            obj["murajaah_ramp"] = .null
        }
        switch policy.recoveryPolicy {
        case .strictBacklog:
            obj["recovery_policy"] = .object(["kind": .string("strict_backlog")])
        case .redistribute(let days, let maxExtra):
            var r: [String: JSONValue] = [
                "kind": .string("redistribute"),
                "days": .number(String(days)),
            ]
            if let maxExtra { r["max_extra"] = amount(maxExtra) }
            obj["recovery_policy"] = .object(r)
        case .pauseAndResume:
            obj["recovery_policy"] = .object(["kind": .string("pause_and_resume")])
        }
        if let mode = policy.cycleWeekMode {
            obj["cycle_week_mode"] = .string(mode)
        }
        return .object(obj)
    }

    /// Exact decimal string for a DecimalValue (denominator is a power of 10).
    static func decimalString(_ value: DecimalValue) -> String {
        if value.denominator == 1 { return String(value.units) }
        let whole = value.units / value.denominator
        var frac = String(value.units % value.denominator)
        var digits = 0
        var d = value.denominator
        while d > 1 {
            d /= 10
            digits += 1
        }
        while frac.count < digits { frac = "0" + frac }
        while frac.hasSuffix("0") { frac.removeLast() }
        return frac.isEmpty ? String(whole) : "\(whole).\(frac)"
    }

    // MARK: - Aggregations

    static func murajaahBurden(curve: [DayLoad], weekStartDay: Weekday) -> [WeekBurden] {
        let burdenTypes = ["murajaah", "juz_review_distributed", "cycle_consolidation"]
        var totals: [LocalDate: (minutes: Int64, days: Int64)] = [:]
        for load in curve {
            let ws = weekStart(of: load.date, weekStartDay: weekStartDay)
            var entry = totals[ws] ?? (0, 0)
            for type in burdenTypes {
                entry.minutes += Int64(load.byType[type] ?? 0)
            }
            entry.days += 1
            totals[ws] = entry
        }
        return totals.keys.sorted().map { ws in
            let entry = totals[ws]!
            return WeekBurden(weekStart: ws, avgMinutes: Int(Micropage.roundHalfUp(entry.minutes, entry.days)))
        }
    }

    static func capacityWarnings(curve: [DayLoad], declared: Int) -> [CapacityWarning] {
        func severity(_ minutes: Int) -> CapacitySeverity? {
            guard minutes > declared else { return nil }
            // > 150%: minutes/declared > 3/2 ⟺ 2·minutes > 3·declared (integers).
            return 2 * minutes > 3 * declared ? .severe : .warn
        }
        var warnings: [CapacityWarning] = []
        var runStart: LocalDate? = nil
        var runEnd: LocalDate? = nil
        var runPeak = 0
        var runSeverity: CapacitySeverity? = nil
        func flush() {
            guard let start = runStart, let end = runEnd, let sev = runSeverity else { return }
            warnings.append(CapacityWarning(
                startDate: start, endDate: end, estimatedMinutes: runPeak,
                declaredAvailableMinutes: declared, severity: sev))
            runStart = nil
            runEnd = nil
            runPeak = 0
            runSeverity = nil
        }
        for load in curve {
            guard let sev = severity(load.estimatedMinutes) else {
                flush()
                continue
            }
            if let end = runEnd, sev == runSeverity, load.date - end == 1 {
                runEnd = load.date
                runPeak = max(runPeak, load.estimatedMinutes)
            } else {
                flush()
                runStart = load.date
                runEnd = load.date
                runPeak = load.estimatedMinutes
                runSeverity = sev
            }
        }
        flush()
        return warnings
    }

    static func recoveryImpact(
        strict: ProjectionOutcome,
        recovery: ProjectionOutcome,
        weekStartDay: Weekday
    ) -> RecoveryImpact {
        var slip = 0
        if let strictDone = strict.completionDate, let recoveryDone = recovery.completionDate {
            slip = strictDone - recoveryDone
        }
        var positiveTotal: Int64 = 0
        var positiveDays: Int64 = 0
        var weeks: Set<LocalDate> = []
        for (base, applied) in zip(strict.curve, recovery.curve) {
            let delta = applied.estimatedMinutes - base.estimatedMinutes
            if delta > 0 {
                positiveTotal += Int64(delta)
                positiveDays += 1
                weeks.insert(weekStart(of: applied.date, weekStartDay: weekStartDay))
            }
        }
        let extra = positiveDays > 0 ? Int(Micropage.roundHalfUp(positiveTotal, positiveDays)) : 0
        return RecoveryImpact(slipDays: slip, extraDailyMinutes: extra, weeksAffected: weeks.count)
    }

    // MARK: - Helpers

    static func weekStart(of date: LocalDate, weekStartDay: Weekday) -> LocalDate {
        let delta = (date.weekday.rawValue - weekStartDay.rawValue + 7) % 7
        return date.adding(days: -delta)
    }

    static func rebuilt(
        _ context: PlanGenerationContext,
        events: [PlanEvent],
        today: LocalDate
    ) throws -> PlanGenerationContext {
        try PlanGenerationContext(
            planId: context.planId,
            curriculum: context.curriculumSet.base,
            // PC-3(a): preserve the FULL CurriculumSet across a rebuild — a
            // forecast run over a plan mid-curriculum-switch (D-054) must
            // still resolve the post-switch curriculum on projected dates,
            // not collapse back to `base`. Latent/inert today: every real
            // caller's `byKey` is empty, so this is `[:]` -> `[:]` either way.
            curriculumByKey: context.curriculumSet.byKey,
            quranIndex: context.quranIndex,
            policy: context.policy,
            startingState: context.startingState,
            calendar: context.calendar,
            events: events,
            today: today)
    }
}
