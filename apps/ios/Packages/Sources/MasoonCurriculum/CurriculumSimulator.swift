import MasoonDomain

/// CB-6: `CurriculumSimulationGate`'s first real implementation (CB-5's gate
/// 4 seam, `CurriculumValidator.swift`). Runs a draft's COMPILED curriculum
/// through the real `Engine.generate` — the SAME engine every other call
/// site uses, never a re-implementation — across the three canonical
/// `SimulationProfile`s (fresh/mid/hafiz — `SimulationProfiles.swift`) at
/// two depths:
///
///   - PREVIEW (`Self.previewDays` = 60): fast, interactive. `simulate(_:)`
///     — the `CurriculumSimulationGate` conformance CB-5's pipeline calls by
///     default — runs preview depth only.
///   - PUBLISH (`Self.publishDays` = 400, ×2 for a determinism proof): slow,
///     explicit-only — `publish(_:)`. Never invoked by the pipeline itself;
///     a real authoring UI calls this once, right before actually
///     publishing a draft, not on every edit.
///
/// Both depths run the SAME `PlanPolicy` (synthesized generically from the
/// curriculum's own `default_pace`/session ids — `defaultPolicy(for:)`
/// below) across all 3 profiles, with the engine's `today` pinned to one day
/// BEFORE a fixed `anchor`. Per `Engine.swift`'s own header ("dates ≤ `today`
/// fold actual events; dates after `today` run in projection mode"), this
/// puts the ENTIRE simulated window in projection mode: no synthetic
/// completion events are needed, no debt accumulates, and — this is the
/// fixed projection boundary avoids a duplicate-selection
/// artifact that shows up whenever `anchor == today`: the anchor day itself
/// is still `date <= today` (fold-actual-events) with an empty event log, so
/// it neither advances the cursor nor is treated as a miss, and the very
/// next (first projection) day re-selects from the SAME un-advanced cursor,
/// producing two calendar days of identical new-ḥifẓ content. Pinning
/// `today` one day before `anchor` sidesteps that entirely — every simulated
/// date, including the first, runs in clean projection mode.
///
/// A fixed, literal anchor date (never the wall clock) keeps every run a
/// pure function of the curriculum and index. Publication checks that
/// two runs over identical inputs produce identical output.
public struct CurriculumSimulator: CurriculumSimulationGate, Sendable {
    /// The corpus this simulator runs curricula against — a real caller
    /// supplies the SAME `QuranIndex` (`any ContentIndex`, Stage 2) every
    /// other engine entry point uses. Held as instance state per CB-5's own
    /// design note on `CurriculumSimulationGate` ("conforming types can hold
    /// state ... instead of capturing it in a closure").
    public let index: any ContentIndex

    /// Fixed simulation anchor, independent of the wall clock.
    public static let anchor = LocalDate(iso: "2026-08-02")!
    /// One day before `anchor`, so every simulated date (including the
    /// anchor itself) runs in projection mode — see the type doc above.
    public static let today = anchor.adding(days: -1)

    public static let previewDays = 60
    public static let publishDays = 400
    /// Safety ceiling: a full calendar day.
    public static let maxMinutesPerDay = 1440

    public init(index: any ContentIndex) {
        self.index = index
    }

    // MARK: - CurriculumSimulationGate conformance (gate 4 default: PREVIEW depth)

    /// The pipeline's gate 4 entry point. Deliberately PREVIEW depth, not
    /// PUBLISH — see the type doc's timing rationale. Call `publish(_:)`
    /// directly (outside the 4-gate pipeline) for the deeper check.
    public func simulate(_ curriculum: CompiledCurriculum) throws -> [CurriculumIssue] {
        try preview(curriculum)
    }

    // MARK: - Preview (60 days × 3 profiles, fast)

    /// Runs all 3 profiles for `Self.previewDays` days and checks the
    /// 1440-minutes/day ceiling. No determinism double-run at this depth —
    /// that is PUBLISH-only (400 days × 3 profiles × 2 is already the
    /// expensive check; doubling PREVIEW too would defeat its purpose of
    /// staying interactive).
    public func preview(_ curriculum: CompiledCurriculum) throws -> [CurriculumIssue] {
        var issues: [CurriculumIssue] = []
        for profile in SimulationProfile.allCases {
            let result = try run(curriculum: curriculum, profile: profile, days: Self.previewDays)
            issues += Self.ceilingIssues(result: result, profile: profile)
        }
        return issues.sorted(by: Self.issueOrder)
    }

    // MARK: - Per-day minutes (CB-11: the builder's simulation-preview screen)

    /// One preview day's workload — the SAME `run(curriculum:profile:days:)`
    /// PREVIEW-depth simulation `preview(_:)`'s ceiling check already uses,
    /// exposed here as real per-day data (not just pass/fail issues) for a
    /// chart. Public, additive: `run`/the ceiling machinery above stay
    /// exactly as CB-6 built them; this is a thin reuse, not a second
    /// simulation path.
    public struct DailyMinutesSummary: Sendable, Equatable {
        public let date: LocalDate
        public let totalMinutes: Int
        public let taskCount: Int
    }

    /// Runs ONE profile at PREVIEW depth (60 days) and returns its per-day
    /// totals, sorted by date. Throws exactly as `run` does (the same
    /// `Engine.generate` call underneath).
    public func previewDailyMinutes(_ curriculum: CompiledCurriculum, profile: SimulationProfile) throws -> [DailyMinutesSummary] {
        let result = try run(curriculum: curriculum, profile: profile, days: Self.previewDays)
        var perDay: [LocalDate: (minutes: Int, count: Int)] = [:]
        for task in result.tasks {
            perDay[task.date, default: (0, 0)].minutes += task.estimatedMinutes
            perDay[task.date, default: (0, 0)].count += 1
        }
        return perDay.keys.sorted().map {
            DailyMinutesSummary(date: $0, totalMinutes: perDay[$0]!.minutes, taskCount: perDay[$0]!.count)
        }
    }

    // MARK: - Publish (400 days × 3 profiles, deep, + determinism double-run)

    /// The deeper, explicit-only check: 400 days × 3 profiles against the
    /// 1440-minutes/day ceiling, PLUS the entire 400-day × 3-profile
    /// simulation run a SECOND time and diffed byte-for-byte
    /// (`StreamSerializer` output) against the first — a determinism proof.
    /// Never called by `CurriculumValidator`'s pipeline; a real authoring UI
    /// calls this once, right before publish.
    public func publish(_ curriculum: CompiledCurriculum) throws -> [CurriculumIssue] {
        let runA = try publishStreams(curriculum)
        let runB = try publishStreams(curriculum)

        var issues: [CurriculumIssue] = []
        for profile in SimulationProfile.allCases {
            issues += Self.ceilingIssues(result: runA.results[profile]!, profile: profile)
            if runA.streams[profile] != runB.streams[profile] {
                issues.append(CurriculumIssue(
                    severity: .error, id: "SIM-NONDETERMINISTIC", gate: .simulation, path: JSONPointer(),
                    messageEn: "publish simulation is non-deterministic for profile '\(profile)': "
                        + "two runs over identical inputs produced different StreamSerializer output",
                    messageAr: "محاكاة النشر غير حتمية للملف الشخصي '\(profile)': "
                        + "أنتج تشغيلان بنفس المدخلات تمامًا مخرجات مختلفة"))
            }
        }
        return issues.sorted(by: Self.issueOrder)
    }

    /// One full PUBLISH-depth pass: all 3 profiles, each serialized via the
    /// real `StreamSerializer` (the same byte-exact format the fixture-
    /// parity harness compares across all three engines).
    private func publishStreams(
        _ curriculum: CompiledCurriculum
    ) throws -> (results: [SimulationProfile: GenerationResult], streams: [SimulationProfile: String]) {
        var results: [SimulationProfile: GenerationResult] = [:]
        var streams: [SimulationProfile: String] = [:]
        for profile in SimulationProfile.allCases {
            let result = try run(curriculum: curriculum, profile: profile, days: Self.publishDays)
            results[profile] = result
            streams[profile] = StreamSerializer.serialize(result)
        }
        return (results, streams)
    }

    // MARK: - One profile's run

    /// `planId` per profile: fixed, arbitrary, valid UUIDs — never the wall
    /// clock or a random generator (determinism). Distinct per profile only
    /// for readability; nothing downstream keys behavior off `planId`
    /// beyond validating its shape (`GenerationContext.swift`).
    private static let planIds: [SimulationProfile: String] = [
        .fresh: "00000000-0000-0000-0000-0000000cb601",
        .mid: "00000000-0000-0000-0000-0000000cb602",
        .hafiz: "00000000-0000-0000-0000-0000000cb603",
    ]

    func run(curriculum: CompiledCurriculum, profile: SimulationProfile, days: Int) throws -> GenerationResult {
        let policy = try Self.defaultPolicy(for: curriculum)
        let startingState = profile.startingState(index: index)
        let context = try PlanGenerationContext(
            planId: Self.planIds[profile]!,
            curriculum: curriculum,
            quranIndex: index,
            policy: policy,
            startingState: startingState,
            calendar: PlanCalendar(timezone: "UTC", anchorDate: Self.anchor, orgExceptions: []),
            events: [],
            today: Self.today)
        let window = GenerationWindow(from: Self.anchor, to: Self.anchor.adding(days: days - 1))
        return try Engine.generate(context: context, window: window)
    }

    // MARK: - 1440-minutes/day ceiling

    static func ceilingIssues(result: GenerationResult, profile: SimulationProfile) -> [CurriculumIssue] {
        var perDay: [LocalDate: Int] = [:]
        for task in result.tasks {
            perDay[task.date, default: 0] += task.estimatedMinutes
        }
        var issues: [CurriculumIssue] = []
        for (date, minutes) in perDay where minutes > maxMinutesPerDay {
            issues.append(CurriculumIssue(
                severity: .error, id: "SIM-DAY-OVER-1440", gate: .simulation, path: JSONPointer(),
                messageEn: "profile '\(profile)': \(date.isoString) totals \(minutes) estimated minutes, "
                    + "exceeding the \(maxMinutesPerDay)-minute (24h) sanity ceiling",
                messageAr: "الملف الشخصي '\(profile)': يبلغ إجمالي دقائق \(date.isoString) \(minutes) دقيقة، "
                    + "متجاوزًا سقف الأمان البالغ \(maxMinutesPerDay) دقيقة (24 ساعة)"))
        }
        return issues
    }

    /// Dictionary iteration order is not guaranteed stable run-to-run
    /// (Swift's per-process hash-seed randomization) — sort every issue
    /// list this file returns so gate 4's own output is itself
    /// reproducible, independent of the (unrelated) `StreamSerializer`
    /// determinism proof above.
    static func issueOrder(_ a: CurriculumIssue, _ b: CurriculumIssue) -> Bool {
        if a.id != b.id { return a.id < b.id }
        return a.messageEn < b.messageEn
    }

    // MARK: - Policy synthesis

    /// Builds a policy from the curriculum's allowed days, default pace
    /// and session definitions.
    static func defaultPolicy(for curriculum: CompiledCurriculum) throws -> PlanPolicy {
        let newHifzDays = curriculum.weekdayUnion(forEmitType: "new_hifz")
        let activeDays = newHifzDays.isEmpty ? weekdaysForAnyRule(curriculum) : newHifzDays
        let activeWeekdays: JSONValue = .array(activeDays.sorted().map { .string($0.code) })
        let listeningDays: JSONValue = .array(
            curriculum.weekdayUnion(forEmitType: "listening").sorted().map { .string($0.code) })
        var sessions: [JSONValue] = []
        for id in curriculum.sessionIds {
            sessions.append(.object([
                "id": .string(id),
                "start": .string(curriculum.sessionDefaultTimes[id] ?? "05:00"),
            ]))
        }
        let policyJSON: JSONValue = .object([
            "active_weekdays": activeWeekdays,
            "evidence_policy": .object([:]),
            "memorization_order": .object(["kind": .string("mushaf_forward")]),
            "new_amount": .object([
                "unit": .string(curriculum.defaultPace.unit.rawValue),
                "value": .string(decimalString(curriculum.defaultPace.value)),
            ]),
            "listening_days": listeningDays,
            "recovery_policy": .object(["kind": .string("strict_backlog")]),
            "separate_session_completion": .bool(false),
            "sessions": .array(sessions),
            "target_range": .string("full_quran"),
        ])
        return try PlanPolicy(json: policyJSON)
    }

    private static func weekdaysForAnyRule(_ curriculum: CompiledCurriculum) -> Set<Weekday> {
        var result = Set<Weekday>()
        for rule in curriculum.rules {
            for dayClass in rule.when.dayClasses {
                result.formUnion(curriculum.dayClasses[dayClass] ?? [])
            }
        }
        for trigger in curriculum.triggers {
            for effect in trigger.effects {
                guard case .insertWeek(_, _, let dayRules) = effect else { continue }
                for rule in dayRules {
                    for dayClass in rule.when.dayClasses {
                        result.formUnion(curriculum.dayClasses[dayClass] ?? [])
                    }
                }
            }
        }
        return result
    }

    /// `DecimalValue.description` renders a raw fraction (`"1/2"`), not
    /// decimal notation, and isn't meant to round-trip through
    /// `DecimalValue(string:)` (`PlanPolicy`'s own JSON parser). Every
    /// `DecimalValue` in this codebase is built by parsing decimal text
    /// (`init?(string:)`), so `denominator` is always a power of 10 by
    /// construction — reconstructing the original decimal string from
    /// `units`/`denominator` is exact, no floating point involved.
    static func decimalString(_ value: DecimalValue) -> String {
        if value.denominator == 1 { return String(value.units) }
        var fractionDigits = 0
        var scale = value.denominator
        while scale > 1 { scale /= 10; fractionDigits += 1 }
        let whole = value.units / value.denominator
        let frac = value.units % value.denominator
        let fracText = String(frac)
        let padded = String(repeating: "0", count: max(0, fractionDigits - fracText.count)) + fracText
        return "\(whole).\(padded)"
    }
}
