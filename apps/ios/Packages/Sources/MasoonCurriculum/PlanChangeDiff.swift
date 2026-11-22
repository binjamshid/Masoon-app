import MasoonDomain

/// `PlanChangeDiff` (T-PC-10): a PURE comparison of a plan's CURRENT
/// trajectory ("base") against a CANDIDATE policy-and/or-curriculum change,
/// over the exact same explicit date range for both sides.
///
/// This is deliberately NOT built on top of `Forecaster.forecast(candidate:)`
/// — that function's candidate preview (`policyChangedEvent`'s pre-PC-10
/// default) hardcodes the candidate's `effective_from` at `context.today + 1`
/// (AC-6's "wizard confirms right now" preview). `PlanChangeDiff` needs an
/// arbitrary, caller-chosen `effectiveFrom` (a supervisor scheduling a
/// curriculum switch for next month, say), so it drives `Engine.generate`
/// directly for BOTH the base and candidate sides, over the IDENTICAL
/// `GenerationWindow`, so neither side's start date is silently different
/// from the other's (see PC-10's own written correctness requirement).
///
/// ## `historyUnchanged`
/// Both `Engine.generate` calls use `window.from = effectiveFrom` — never
/// `context.calendar.anchorDate`. The engine still simulates its own internal
/// state (cursor, ledger, debt, rotation cursors) from the plan's anchor
/// forward to establish correct day-`effectiveFrom` state (this is
/// `Engine.generate`'s own unavoidable, pre-existing mechanic — see
/// `Forecaster.projection`'s identical `windowFrom` pattern) — but neither
/// call's RETURNED `tasks` can ever contain a date before `effectiveFrom`,
/// because `EngineRun.generate(window:)` only appends a day's emissions to
/// `output` when `date >= window.from`. Days before `effectiveFrom` are
/// therefore never part of this diff's output or comparison "by construction
/// -- not by comparison" (PC-10's own phrasing): there is no code path in
/// this file that could observe, let alone compare, a pre-`effectiveFrom`
/// day. `historyUnchanged` re-asserts this at runtime (cheap, from arrays
/// already in hand) as a regression guard, not because it is in doubt.
///
/// ## `coverage.cursorMoved`
/// D-054 requires a curriculum switch to never relocate the memorization
/// cursor. Investigated (not merely asserted) against the engine as it
/// exists after this same round's PC-4/PC-5 work:
///   1. `EngineRun.cursorPos` is initialized exactly ONCE, from
///      `context.startingState.placementCursor` (`EngineRun.init`), and never
///      re-initialized.
///   2. It is mutated in exactly ONE place in the whole engine —
///      `cursorPos = selection.nextCursor` inside `simulateDay`, gated on a
///      new-ḥifẓ task actually PASSING that day (ordinary forward advancement
///      only).
///   3. `sweepAtBoundary(_:)` — the ONLY code that runs specifically at a
///      curriculum switch's `effective_from` (D-054's hard-boundary sweep,
///      PC-5) — mutates `consolidationWeeks`, `distributions`,
///      `scheduledJuzReviews`, and `rotationCursors` ONLY. It does not
///      reference `cursorPos` at all.
///   4. `PlanPolicy.applying(patch:)` — the only code that applies a
///      `plan.policy_changed`/`plan.curriculum_upgraded`-bundled patch — has
///      no cursor- or placement-related key, and `targetSet` (the OTHER
///      thing that could make the cursor's MEANING shift) is computed once
///      at `EngineRun.init` from the context's STATIC `context.policy`, never
///      from `effectivePolicy(on:)`, so a patch cannot retarget it either.
///   5. This file never constructs a different `startingState` for the
///      candidate context (`candidateContext(...)` below reuses
///      `context.startingState` byte-for-byte) and never synthesizes a
///      `starting_state.declared`/`starting_state.amended` event.
/// No code path in the engine or in this file can move the cursor as a
/// side-effect of a switch/patch event; only genuine forward ḥifẓ progress
/// moves it, identically to how it always has. `cursorMoved` is therefore
/// `false` by construction, exactly like `historyUnchanged` above — this is
/// reported, not papered over, per PC-10's instructions.
public enum PlanChangeDiff {
    public enum DiffError: Error, CustomStringConvertible {
        /// D-054 previews only ever propose a FUTURE switch/patch. Allowing
        /// `effectiveFrom <= today` would make the candidate side's
        /// actual-mode days (§ Engine.swift `actualMode = date <= today`)
        /// resolve `task_uid`s against a DIFFERENT rule/session vocabulary
        /// than the real recorded completions were keyed under, manufacturing
        /// synthetic "missed" debt out of a hypothetical retroactive switch
        /// — not a real product state, and exactly the kind of confusion
        /// `historyUnchanged`/`cursorMoved` exist to rule out.
        case effectiveFromNotInFuture(effectiveFrom: LocalDate, today: LocalDate)
        public var description: String {
            switch self {
            case .effectiveFromNotInFuture(let effectiveFrom, let today):
                return "PlanChangeDiff: effective_from \(effectiveFrom.isoString) must be after today "
                    + "\(today.isoString) — a plan-change preview only ever proposes a future switch"
            }
        }
    }

    /// Horizon hard cap, matching `Forecaster.maxHorizonDays` (this file
    /// drives the same `Engine.generate` machinery over a comparable span).
    public static let maxHorizonDays = Forecaster.maxHorizonDays

    // MARK: - Candidate curriculum switch

    /// A candidate `plan.curriculum_upgraded` target: the new curriculum's
    /// `slug`/`version` (folded into `FoldedEvents.curriculumTimeline`, D-054)
    /// plus its compiled definition (injected into the candidate context's
    /// `CurriculumSet.byKey`, PC-3/PC-7, so `CurriculumSet.resolve` actually
    /// finds it instead of silently falling back to `base`).
    public struct CandidateCurriculumSwitch: Sendable {
        public let slug: String
        public let version: String
        public let compiled: CompiledCurriculum

        public init(slug: String, version: String, compiled: CompiledCurriculum) {
            self.slug = slug
            self.version = version
            self.compiled = compiled
        }
    }

    // MARK: - Result shape

    public struct DateWindow: Hashable, Sendable {
        public let from: LocalDate
        /// Inclusive.
        public let to: LocalDate

        public init(from: LocalDate, to: LocalDate) {
            self.from = from
            self.to = to
        }
    }

    /// One window's average daily workload, base vs candidate.
    public struct Pace: Hashable, Sendable {
        public let window: DateWindow
        /// Round-half-up average total `estimatedMinutes`/day over the days
        /// of `window` actually inside the diffed horizon.
        public let baseAvgMinutes: Int
        public let candidateAvgMinutes: Int
        /// Days of `window` actually covered by the horizon (0 when the
        /// whole window falls beyond `effectiveFrom + horizonDays` — a short
        /// horizon can leave the steady window entirely uncovered; `0`
        /// average in that case means "no data", not "no load").
        public let daysCounted: Int
    }

    /// Characterizes the candidate's ramp-vs-steady pacing shape: a 14-day
    /// ramp window `[effectiveFrom, effectiveFrom+13]` and a 28-day steady
    /// window `[effectiveFrom+28, effectiveFrom+55]` — PC-10's own literal
    /// sampling windows, not re-derived from any curriculum ramp constant.
    public struct Shape: Hashable, Sendable {
        public let ramp: Pace
        public let steady: Pace
    }

    /// One murājaʿah-family rule's post-switch "bridge" (catch-up) date: the
    /// first date on/after `effectiveFrom` the rule's per-occurrence content
    /// weight reaches `peakMicropages` — the rule's own steady-state ceiling,
    /// observed empirically from the CANDIDATE's own generated stream (never
    /// re-derived from the DSL ramp formula, so this can never drift from
    /// what the engine actually emits). A rule already at steady state going
    /// into the switch reaches its peak on its very first post-switch
    /// emission — `fillDate` sits right at `effectiveFrom` — which is
    /// exactly the observable signature of "the ramp did not restart".
    public struct BridgeEntry: Hashable, Sendable {
        public let ruleId: String
        public let session: String
        /// Peak per-occurrence µp content observed for this rule within the
        /// diffed horizon; 0 when the rule never emits any content.
        public let peakMicropages: Int64
        /// `nil` when the rule never reaches nonzero content within the
        /// horizon (peak == 0) — nothing to "bridge" to.
        public let fillDate: LocalDate?
    }

    /// Debt-ledger comparison (`GenerationResult.finalState.debtNewRanges`,
    /// D-049) as of `effectiveFrom + horizonDays` — the engine exposes only
    /// this final accumulated count, not a day-by-day debt curve, so "over
    /// the horizon" reads as "accumulated BY the end of the horizon".
    public struct Debt: Hashable, Sendable {
        public let baseOutstandingRanges: Int
        public let candidateOutstandingRanges: Int
        public var delta: Int { candidateOutstandingRanges - baseOutstandingRanges }
    }

    /// D-054 coverage comparison. `cursorMoved` is ALWAYS `false` — see this
    /// file's header comment for the structural argument.
    public struct Coverage: Hashable, Sendable {
        public let cursorMoved: Bool
        public let baseCursor: CanonicalPosition?
        public let candidateCursor: CanonicalPosition?
        /// µp of new-ḥifẓ content each side actually schedules within the
        /// diffed window (`ContentWeight.micropages`) — a coverage-volume
        /// comparison independent of minutes/pacing.
        public let baseNewMicropages: Int64
        public let candidateNewMicropages: Int64
    }

    /// One side's (base or candidate) completion state — kept as a 4-way
    /// enum specifically so a UI never has to collapse two different
    /// "nothing to show" states into one ambiguous case (PC-10's explicit
    /// requirement: distinguish "still going" from "structurally can't
    /// complete").
    public enum Completion: Hashable, Sendable {
        /// The target completes within `[effectiveFrom, effectiveFrom +
        /// horizonDays]`, on this date (R-C1: the last completed/assumed
        /// new-ḥifẓ task's date).
        case date(LocalDate)
        /// The plan was ALREADY complete (or its cursor already exhausted —
        /// see the doc note below) before `effectiveFrom`; the diffed window
        /// contains no new-ḥifẓ work either way.
        case alreadyComplete
        /// Outstanding new-ḥifẓ work exists, but does not finish by
        /// `effectiveFrom + horizonDays`.
        case beyondHorizon
        /// The active curriculum declares NO `new_hifz`-emitting rule at
        /// all (a structurally revision-only curriculum/change) — there is
        /// no completion date to report, not even a distant one, because
        /// nothing this side does could ever complete a target.
        case noNewHifz
    }

    public struct CompletionResult: Hashable, Sendable {
        public let base: Completion
        public let candidate: Completion
    }

    public struct Result: Sendable {
        /// See this file's header comment — proven true from the arrays
        /// already in hand (window-filtered by construction), never by a
        /// deeper comparison against history.
        public let historyUnchanged: Bool
        public let effectiveFrom: LocalDate
        public let horizonDays: Int
        public let shape: Shape
        /// Sorted by `ruleId` for determinism.
        public let bridge: [BridgeEntry]
        public let debt: Debt
        public let coverage: Coverage
        public let completion: CompletionResult
    }

    // MARK: - Compute

    /// Computes the diff. `candidatePolicy`/`candidateCurriculum` may be
    /// combined (a curriculum switch that ALSO carries a bundled policy
    /// patch, D-054's `policy_patch` field) or used independently; leaving
    /// both `nil` is a legitimate (if degenerate) no-op self-diff.
    public static func compute(
        context: PlanGenerationContext,
        effectiveFrom: LocalDate,
        horizonDays: Int,
        candidatePolicy: PlanPolicy? = nil,
        candidateCurriculum: CandidateCurriculumSwitch? = nil
    ) throws -> Result {
        guard effectiveFrom > context.today else {
            throw DiffError.effectiveFromNotInFuture(effectiveFrom: effectiveFrom, today: context.today)
        }
        let horizon = max(0, min(horizonDays, maxHorizonDays))
        let horizonEnd = effectiveFrom.adding(days: horizon)
        // PC-10: the SAME explicit window for both sides — never
        // `context.calendar.anchorDate` — is the whole correctness point.
        let window = GenerationWindow(from: effectiveFrom, to: horizonEnd)

        let baseResult = try Engine.generate(context: context, window: window)
        let candidateCtx = try candidateContext(
            context: context, effectiveFrom: effectiveFrom,
            candidatePolicy: candidatePolicy, candidateCurriculum: candidateCurriculum)
        let candidateResult = try Engine.generate(context: candidateCtx, window: window)

        // Regression guard, not a measurement — see header comment.
        let historyUnchanged =
            baseResult.tasks.allSatisfy { $0.date >= effectiveFrom }
            && candidateResult.tasks.allSatisfy { $0.date >= effectiveFrom }

        let shape = computeShape(
            baseTasks: baseResult.tasks, candidateTasks: candidateResult.tasks,
            effectiveFrom: effectiveFrom, horizonEnd: horizonEnd)

        let bridge = computeBridge(candidateTasks: candidateResult.tasks, index: context.quranIndex)

        let debt = Debt(
            baseOutstandingRanges: baseResult.finalState.debtNewRanges,
            candidateOutstandingRanges: candidateResult.finalState.debtNewRanges)

        let baseNewRanges = baseResult.tasks.filter { $0.type == "new_hifz" }.flatMap(\.content)
        let candidateNewRanges = candidateResult.tasks.filter { $0.type == "new_hifz" }.flatMap(\.content)
        let coverage = Coverage(
            cursorMoved: false,
            baseCursor: baseResult.finalState.cursor,
            candidateCursor: candidateResult.finalState.cursor,
            baseNewMicropages: ContentWeight.micropages(of: baseNewRanges, index: context.quranIndex),
            candidateNewMicropages: ContentWeight.micropages(of: candidateNewRanges, index: context.quranIndex))

        let candidateCurriculumActive = candidateCurriculum?.compiled ?? context.curriculumSet.base
        let completion = CompletionResult(
            base: completion(for: baseResult, curriculum: context.curriculumSet.base, windowFrom: effectiveFrom),
            candidate: completion(for: candidateResult, curriculum: candidateCurriculumActive, windowFrom: effectiveFrom))

        return Result(
            historyUnchanged: historyUnchanged,
            effectiveFrom: effectiveFrom,
            horizonDays: horizon,
            shape: shape,
            bridge: bridge,
            debt: debt,
            coverage: coverage,
            completion: completion)
    }

    // MARK: - Candidate context construction

    static func candidateContext(
        context: PlanGenerationContext,
        effectiveFrom: LocalDate,
        candidatePolicy: PlanPolicy?,
        candidateCurriculum: CandidateCurriculumSwitch?
    ) throws -> PlanGenerationContext {
        var curriculumByKey = context.curriculumSet.byKey
        var extraEvents: [PlanEvent] = []
        let occurredAtLocal = "\(context.today.isoString)T23:59:00+00:00"

        if let sw = candidateCurriculum {
            curriculumByKey["\(sw.slug)@\(sw.version)"] = sw.compiled
            // D-054/Fold.swift: a `plan.curriculum_upgraded` event may bundle
            // its own `policy_patch`, folded onto the SAME effective_from —
            // use that single-event mechanism when both are supplied, rather
            // than two independent events.
            var payload: [String: JSONValue] = [
                "slug": .string(sw.slug),
                "version": .string(sw.version),
                "effective_from": .string(effectiveFrom.isoString),
            ]
            if let policy = candidatePolicy {
                payload["policy_patch"] = Forecaster.policyPatch(policy)
            }
            extraEvents.append(PlanEvent(
                eventId: "planchange-candidate-curriculum",
                type: PlanEventType.planCurriculumUpgraded,
                serverSeq: nil,
                deviceId: "~masoon-planchange",
                clientSeq: Int64.max,
                occurredAtLocal: occurredAtLocal,
                payload: .object(payload)))
        } else if let policy = candidatePolicy {
            extraEvents.append(Forecaster.policyChangedEvent(
                context: context, candidate: policy, effective: effectiveFrom,
                eventId: "planchange-candidate-policy", deviceId: "~masoon-planchange"))
        }

        // PC-10: reuse `context.startingState`/`context.policy` byte-for-byte
        // — see this file's header comment on `coverage.cursorMoved` for why
        // that matters. Only `curriculumByKey` and `events` change.
        return try PlanGenerationContext(
            planId: context.planId,
            curriculum: context.curriculumSet.base,
            curriculumByKey: curriculumByKey,
            quranIndex: context.quranIndex,
            policy: context.policy,
            startingState: context.startingState,
            calendar: context.calendar,
            events: context.events + extraEvents,
            today: context.today)
    }

    // MARK: - Shape

    static func minutesByDate(_ tasks: [TaskInstance]) -> [LocalDate: Int] {
        var out: [LocalDate: Int] = [:]
        for task in tasks { out[task.date, default: 0] += task.estimatedMinutes }
        return out
    }

    static func avgMinutes(
        _ byDate: [LocalDate: Int], window: DateWindow, horizonEnd: LocalDate
    ) -> (avg: Int, daysCounted: Int) {
        let clippedTo = min(window.to, horizonEnd)
        guard window.from <= clippedTo else { return (0, 0) }
        var total: Int64 = 0
        var count: Int64 = 0
        var d = window.from
        while d <= clippedTo {
            total += Int64(byDate[d] ?? 0)
            count += 1
            d = d.adding(days: 1)
        }
        let avg = count > 0 ? Int(Micropage.roundHalfUp(total, count)) : 0
        return (avg, Int(count))
    }

    static func computeShape(
        baseTasks: [TaskInstance], candidateTasks: [TaskInstance],
        effectiveFrom: LocalDate, horizonEnd: LocalDate
    ) -> Shape {
        let baseByDate = minutesByDate(baseTasks)
        let candidateByDate = minutesByDate(candidateTasks)
        // PC-10's own literal sampling windows (day offsets), not re-derived.
        let rampWindow = DateWindow(from: effectiveFrom, to: effectiveFrom.adding(days: 13))
        let steadyWindow = DateWindow(from: effectiveFrom.adding(days: 28), to: effectiveFrom.adding(days: 55))

        func pace(_ window: DateWindow) -> Pace {
            let base = avgMinutes(baseByDate, window: window, horizonEnd: horizonEnd)
            let candidate = avgMinutes(candidateByDate, window: window, horizonEnd: horizonEnd)
            return Pace(
                window: window, baseAvgMinutes: base.avg, candidateAvgMinutes: candidate.avg,
                daysCounted: base.daysCounted)
        }
        return Shape(ramp: pace(rampWindow), steady: pace(steadyWindow))
    }

    // MARK: - Bridge

    static func computeBridge(candidateTasks: [TaskInstance], index: any ContentIndex) -> [BridgeEntry] {
        struct Series { var session: String; var points: [(date: LocalDate, mp: Int64)] = [] }
        var byRule: [String: Series] = [:]
        for task in candidateTasks where task.type == "murajaah" {
            let mp = ContentWeight.micropages(of: task.content, index: index)
            byRule[task.originRuleId, default: Series(session: task.session)].points.append((task.date, mp))
        }
        var out: [BridgeEntry] = []
        for ruleId in byRule.keys.sorted() {
            let series = byRule[ruleId]!.points.sorted { $0.date < $1.date }
            let peak = series.map(\.mp).max() ?? 0
            let fillDate = peak > 0 ? series.first(where: { $0.mp == peak })?.date : nil
            out.append(BridgeEntry(
                ruleId: ruleId, session: byRule[ruleId]!.session, peakMicropages: peak, fillDate: fillDate))
        }
        return out
    }

    // MARK: - Completion

    static func hasNewHifzRule(_ curriculum: CompiledCurriculum) -> Bool {
        if curriculum.rules.contains(where: { $0.emit.type == "new_hifz" }) { return true }
        for trigger in curriculum.triggers {
            for effect in trigger.effects {
                if case .insertWeek(_, _, let dayRules) = effect,
                   dayRules.contains(where: { $0.emit.type == "new_hifz" }) {
                    return true
                }
            }
        }
        return false
    }

    static func completion(
        for result: GenerationResult, curriculum: CompiledCurriculum, windowFrom: LocalDate
    ) -> Completion {
        guard hasNewHifzRule(curriculum) else { return .noNewHifz }
        let lastInWindow = result.tasks.filter { $0.type == "new_hifz" }.map(\.date).max()
        if let last = lastInWindow, result.finalState.status == .completed {
            return .date(last)
        }
        // §11.15: `finalState.cursor == nil` ⟺ nothing selectable remains —
        // authoritative even in the (separate, pre-existing) engine edge case
        // where a target that was ALREADY fully covered by declared ḥifẓ
        // before `effectiveFrom` never fires `checkTargetCompletion` (that
        // trigger only runs after a new-ḥifẓ PASS, which never happens when
        // there was never anything left to select) and so never actually
        // flips `status` to `.completed`.
        if result.finalState.cursor == nil {
            return .alreadyComplete
        }
        return .beyondHorizon
    }
}
