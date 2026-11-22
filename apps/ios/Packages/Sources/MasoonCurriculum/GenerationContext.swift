import MasoonDomain

/// PlanGenerationContext (PRD §7.2) — every input the pure generator needs.
/// No wall clock, RNG, locale, or I/O: `today`, reference data, and calendar
/// facts are all injected.

public struct OrgException: Hashable, Sendable {
    public let date: LocalDate
    public let className: String

    public init(date: LocalDate, className: String) {
        self.date = date
        self.className = className
    }
}

public struct PlanCalendar: Sendable {
    public let timezone: String
    public let anchorDate: LocalDate
    public let orgExceptions: [LocalDate: String]

    public init(timezone: String, anchorDate: LocalDate, orgExceptions: [OrgException]) {
        self.timezone = timezone
        self.anchorDate = anchorDate
        var map: [LocalDate: String] = [:]
        for e in orgExceptions { map[e.date] = e.className }
        self.orgExceptions = map
    }
}

public struct GenerationWindow: Hashable, Sendable {
    public let from: LocalDate
    public let to: LocalDate

    public init(from: LocalDate, to: LocalDate) {
        self.from = from
        self.to = to
    }
}

/// Batch 3 Stage 3 (PC-3/D-054): every compiled curriculum a plan might need
/// across its `curriculumTimeline` (Fold.swift). `base` is the plan's
/// original/pinned curriculum — every caller that predates D-054 curriculum
/// switching only ever has `base`, so `byKey` defaults to empty and
/// `EngineRun.cur(_:)` (PC-4) resolves to `base` on every date whenever the
/// timeline is empty or a date precedes its earliest entry.
public struct CurriculumSet: Sendable {
    public let base: CompiledCurriculum
    /// Keyed by `"{slug}@{version}"` (matches `FoldedEvents.CurriculumChange`
    /// resolution in Engine.swift). Extra curricula a plan may switch into;
    /// empty for every plan that has never upgraded.
    public let byKey: [String: CompiledCurriculum]

    public init(base: CompiledCurriculum, byKey: [String: CompiledCurriculum] = [:]) {
        self.base = base
        self.byKey = byKey
    }

    /// The pre-Stage-3 single-curriculum reading: `base`, unconditionally.
    public var curriculum: CompiledCurriculum { base }

    /// Resolves which curriculum applies on `date` given a folded curriculum
    /// timeline (D-054, `FoldedEvents.curriculumTimeline`, PC-1): the entry
    /// with the greatest `effectiveFrom <= date` (ties — same `effectiveFrom`
    /// — broken by fold order, later entry wins), else `base` when no entry
    /// applies yet or the timeline is empty. Falls back to `base` when the
    /// resolved entry's `"slug@version"` has no `byKey` match rather than
    /// crashing (PC-4: a timeline may reference a curriculum this context
    /// was never given). Shared by `EngineRun.cur(_:)` (Engine.swift) and
    /// `Forecaster`'s per-date classification so both read one definition.
    public func resolve(on date: LocalDate, timeline: [FoldedEvents.CurriculumChange]) -> CompiledCurriculum {
        var best: FoldedEvents.CurriculumChange? = nil
        for entry in timeline where entry.effectiveFrom <= date {
            if best == nil || entry.effectiveFrom >= best!.effectiveFrom {
                best = entry
            }
        }
        guard let entry = best else { return base }
        return byKey["\(entry.slug)@\(entry.version)"] ?? base
    }
}

public struct PlanGenerationContext: Sendable {
    public let planId: String
    public let planIdBytes: [UInt8]
    /// Batch 3 Stage 3 (PC-3): was a single stored `curriculum:
    /// CompiledCurriculum`; now a `CurriculumSet` so a plan mid-curriculum-
    /// switch (D-054) can resolve a different compiled curriculum per date.
    /// `curriculum` below is a computed accessor returning `curriculumSet.base`
    /// — byte-identical to the old stored property — so every pre-existing
    /// call site (`context.curriculum`) keeps compiling and keeps reading the
    /// SAME value it always did, unchanged.
    public let curriculumSet: CurriculumSet
    public var curriculum: CompiledCurriculum { curriculumSet.base }
    /// Batch 3 Stage 2: widened from concrete `QuranIndex` to `any ContentIndex`
    /// so `MasoonCurriculum` (Engine.swift/Forecaster.swift) can be written
    /// generically. `PlanGenerationContext` itself stays a NON-generic struct
    /// deliberately: it is named as a
    /// bare, unparameterized return/parameter type across MasoonData and
    /// Feature* call sites this stage does not own, and Swift has no default
    /// generic type-parameter syntax, so making it generic would force every
    /// one of those out-of-scope files to add `<QuranIndex>`. Every existing
    /// caller keeps passing a concrete `QuranIndex` here unchanged — Swift
    /// implicitly boxes it into the existential at the call site, zero source
    /// changes required outside this package.
    public let quranIndex: any ContentIndex
    public let policy: PlanPolicy
    public let startingState: LearnerStartingState
    public let calendar: PlanCalendar
    public let events: [PlanEvent]
    public let today: LocalDate
    /// Whether a teacher is available to provide verification. This gates
    /// the engine's self-check fallback for verification that is optional.
    public let hasAssignedTeacher: Bool

    public enum ContextError: Error, CustomStringConvertible {
        case invalid(String)
        public var description: String {
            if case .invalid(let m) = self { return "generation context error: \(m)" }
            return "generation context error"
        }
    }

    public init(
        planId: String,
        curriculum: CompiledCurriculum,
        /// PC-3/PC-7: extra compiled curricula the plan may switch into,
        /// keyed by `"{slug}@{version}"`. Every caller predating D-054 omits
        /// this — defaults to empty, which is exactly the pre-Stage-3
        /// single-curriculum behavior (`CurriculumSet.curriculum == base`
        /// always).
        curriculumByKey: [String: CompiledCurriculum] = [:],
        quranIndex: any ContentIndex,
        policy: PlanPolicy,
        startingState: LearnerStartingState,
        calendar: PlanCalendar,
        events: [PlanEvent],
        today: LocalDate,
        /// L12: absent/omitted ⇒ `true` (a teacher is assumed present), which
        /// is byte-identical to every pre-existing caller's behavior.
        hasAssignedTeacher: Bool = true
    ) throws {
        guard let bytes = UUIDv5.parse(planId) else {
            throw ContextError.invalid("plan_id is not a UUID: \(planId)")
        }
        self.planId = planId
        self.planIdBytes = bytes
        self.curriculumSet = CurriculumSet(base: curriculum, byKey: curriculumByKey)
        self.quranIndex = quranIndex
        self.policy = policy
        self.startingState = startingState
        self.calendar = calendar
        self.events = events
        self.today = today
        self.hasAssignedTeacher = hasAssignedTeacher
    }
}

// MARK: - Variable resolution (D-028, ENGINE_SEMANTICS §11.21)

/// Resolves DSL `$var` references for a given effective policy.
///
/// Resolution order (§11.21, closed map — mirrors TypeScript
/// `resolveVariables` in `_shared/engine/dsl.ts`):
/// `policy.variable_overrides[name]` → named policy field (below) →
/// curriculum default. `$pace` is reserved separately: it binds
/// `PlanPolicy.new_amount`, falling back to `units.default_pace` (D-028(1))
/// — untouched here.
///
/// The named-field tier is a CLOSED map of exactly seven bindings (copied
/// verbatim from `dsl.ts`'s `mapIf` calls — do not add to this list without
/// updating TypeScript first, they must stay identical):
///   takrar_count        <- policy.takrarCount
///   takrar_spacing_min  <- policy.takrarSpacingMinutes
///   listening_days      <- policy.listeningDays
///   listening_count     <- policy.listeningCount
///   murajaah_ceiling    <- policy.murajaahDailyCeiling
///   murajaah_ramp_step  <- policy.murajaahRamp?.step
///   cycle_week_mode     <- policy.cycleWeekMode
/// A binding only applies when the curriculum actually DECLARES that
/// variable (`curriculum.variables[name] != nil`), matching TypeScript's
/// `mapIf`'s `values.has(name)` gate — a curriculum that never declares
/// e.g. `takrar_count` is completely unaffected. An optional policy field
/// that is `nil` (`murajaahRamp?.step`, `cycleWeekMode`) falls through to
/// the curriculum default rather than binding `nil`. A binding ALSO only
/// applies when the policy actually SPECIFIED that field — matching
/// TypeScript's `v !== undefined` check in `mapIf`, where an omitted JSON
/// key leaves `policy.takrar_count` genuinely `undefined`. `PlanPolicy` has
/// no such "absent" representation for its five non-optional §11.21 fields
/// (an omitted key parses to a synthesized struct default, e.g. `5` for
/// `takrar_count`), so `PlanPolicy.explicitPolicyFields` carries that
/// presence information out-of-band; see `namedPolicyField` below.
struct VariableResolver {
    let curriculum: CompiledCurriculum
    let policy: PlanPolicy

    /// The seven §11.21 policy-field bindings, encoded in the same JSON
    /// shapes `Forecaster.policyPatch` already uses for these fields (int ->
    /// `.number`, amount -> `{"unit","value"}` with a decimal-string value,
    /// weekday set -> sorted array of codes, enum -> `.string`) so the
    /// existing `int`/`bool`/`amount`/`weekdaySet`/`str` accessors below
    /// keep working unchanged. Returns `nil` when this policy field doesn't
    /// apply to `name` (not one of the seven), or the policy never actually
    /// specified it.
    ///
    /// FIVE of the seven (`takrar_count`, `takrar_spacing_min`,
    /// `listening_days`, `listening_count`, `murajaah_ceiling`) are backed
    /// by a NON-optional `PlanPolicy` field: `PlanPolicy.init(json:)`
    /// synthesizes a struct default (e.g. `takrarCount = 5`) whenever the
    /// source JSON omits the key, so the struct value alone cannot tell "the
    /// learner/supervisor set 5" apart from "nobody set anything." Binding
    /// unconditionally on those five made the named-field tier fire even
    /// when nothing had been specified, clobbering curricula whose own DSL
    /// default differs from `PlanPolicy`'s struct default (e.g. pomodoro
    /// declares `takrar_count` default 15; an absent policy field
    /// synthesizes struct default 5, which must NOT win). Gate each of the
    /// five on `PlanPolicy.explicitPolicyFields` — populated by `PlanPolicy`
    /// itself from actual JSON/patch key presence — so an absent field
    /// falls straight through to the curriculum default, exactly matching
    /// `mapIf`'s `v !== undefined` check in `dsl.ts`.
    ///
    /// The remaining two (`murajaah_ramp_step` via `murajaahRamp?.step`,
    /// `cycle_week_mode`) are already `Optional` on `PlanPolicy` and
    /// genuinely `nil` when absent — presence is already exactly
    /// representable there, so they need no entry in `explicitPolicyFields`.
    private func namedPolicyField(_ name: String) -> JSONValue? {
        switch name {
        case "takrar_count":
            guard policy.explicitPolicyFields.contains("takrar_count") else { return nil }
            return .number(String(policy.takrarCount))
        case "takrar_spacing_min":
            guard policy.explicitPolicyFields.contains("takrar_spacing_minutes") else { return nil }
            return .number(String(policy.takrarSpacingMinutes))
        case "listening_days":
            guard policy.explicitPolicyFields.contains("listening_days") else { return nil }
            return .array(policy.listeningDays.sorted().map { .string($0.code) })
        case "listening_count":
            guard policy.explicitPolicyFields.contains("listening_count") else { return nil }
            return .number(String(policy.listeningCount))
        case "murajaah_ceiling":
            guard policy.explicitPolicyFields.contains("murajaah_daily_ceiling") else { return nil }
            return VariableResolver.amountJSON(policy.murajaahDailyCeiling)
        case "murajaah_ramp_step":
            return policy.murajaahRamp.map { VariableResolver.amountJSON($0.step) }
        case "cycle_week_mode":
            return policy.cycleWeekMode.map { .string($0) }
        default:
            return nil
        }
    }

    private static func amountJSON(_ a: QuranAmount) -> JSONValue {
        // Matches `Forecaster.policyPatch`'s `amount(_:)` shape exactly.
        .object(["unit": .string(a.unit.rawValue), "value": .string(Forecaster.decimalString(a.value))])
    }

    private func rawValue(_ name: String) -> JSONValue? {
        if let override = policy.variableOverrides[name] { return override }
        // §11.21: the named policy field only wins when the curriculum
        // actually declares this variable — otherwise fall straight through
        // to the (absent) curriculum default, same as before this tier
        // existed.
        if curriculum.variables[name] != nil, let named = namedPolicyField(name) {
            return named
        }
        return curriculum.variables[name]?.defaultValue
    }

    func int(_ ref: IntOrVar?) -> Int? {
        switch ref {
        case .value(let v)?: return v
        case .ref(let name)?: return rawValue(name)?.intValue
        case nil: return nil
        }
    }

    func bool(_ name: String) -> Bool? {
        rawValue(name)?.boolValue
    }

    func string(_ name: String) -> String? {
        rawValue(name)?.stringValue
    }

    func amount(_ ref: AmountOrVar?) -> QuranAmount? {
        switch ref {
        case .value(let v)?:
            return v
        case .ref(let name)?:
            if name == "pace" { return policy.newAmount }
            return rawValue(name).flatMap { QuranAmount(json: $0) }
        case nil:
            return nil
        }
    }

    func weekdaySet(_ ref: WeekdaySetOrVar?) -> Set<Weekday>? {
        switch ref {
        case .value(let v)?:
            return v
        case .ref(let name)?:
            guard let arr = rawValue(name)?.arrayValue else { return nil }
            var set: Set<Weekday> = []
            for item in arr {
                guard let code = item.stringValue, let wd = Weekday(code: code) else { return nil }
                set.insert(wd)
            }
            return set
        case nil:
            return nil
        }
    }

    /// Resolves an evidence-spec JSON (curriculum default or policy override),
    /// mapping `$var` counter targets through the variable table.
    func evidence(_ json: JSONValue) -> EvidenceSpec? {
        EvidenceSpec.parse(json) { value in
            if let i = value.intValue { return i }
            if let s = value.stringValue, s.hasPrefix("$") {
                return self.int(.ref(String(s.dropFirst())))
            }
            return nil
        }
    }
}
