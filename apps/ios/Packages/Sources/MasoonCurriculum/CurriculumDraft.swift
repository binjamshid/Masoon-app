import MasoonDomain

/// CB-9 (MasoonAuthoring): a typed, EDITABLE model of a `curriculum-v1`
/// document for curriculum editors.
///
/// `CompiledCurriculum` (`CompiledCurriculum.swift`) is the engine's
/// READ-ONLY, execution-shaped view of a curriculum: its loader drops every
/// field the engine itself never consumes (`meta.title`/`description`/
/// `pedagogy_notes`/`origin`/`license_note`/`version`/`corpora`, `Session
/// .anchor`, `Recovery.allowed_policies`, `Advancement`, and more), and it
/// collapses a few JSON *shapes* the engine doesn't need to distinguish
/// (`RuleWhen.day_class` as a bare string vs. a single-element array both
/// become `[String]`; `Calendar.day_classes` values become an unordered
/// `Set<Weekday>`; `TriggerEffect.schedule`'s optional `starting` field is
/// filled with its D-028(5) default and the "was it authored explicitly"
/// bit is lost). None of that is a bug in `CompiledCurriculum` — it is
/// exactly the reduction the ENGINE wants — but it makes `CompiledCurriculum`
/// unusable as the backing model for an editor that must reproduce a
/// curriculum's JSON losslessly (round-tripping an authored document through
/// a builder UI must not silently rewrite `"day_class": "weekday"` into
/// `"day_class": ["weekday"]`, drop an author's `meta.description`, or turn
/// an omitted `starting` key into an explicit one).
///
/// `CurriculumDraft` is therefore a SEPARATE type, not a mutable subclass or
/// wrapper of `CompiledCurriculum`. Design approach:
///   - Every leaf DSL vocabulary type that `CompiledCurriculum.swift`
///     already got right for round-tripping — `IntOrVar`, `AmountOrVar`,
///     `WeekdaySetOrVar`, `PoolWindow`, `PerDaySpec`, `SelectorSpec`,
///     `SelectorRef`, `NotCondition`, `TriggerOn`, `VariableDef.Kind`,
///     plus `MasoonDomain`'s `Weekday`/`QuranUnit`/`QuranAmount`/
///     `CanonicalRange`/`JSONValue` — is REUSED directly, not reinvented.
///     These types are constructed here via their existing public
///     initializers/cases; `CurriculumDraft.swift` does not modify
///     `CompiledCurriculum.swift` in any way.
///   - Every container the loader collapses or default-fills — `RuleWhen`
///     (day_class shape), `RuleEmit` (`info_only`'s absent-vs-`false`),
///     `TriggerEffect` (`schedule.starting`'s absent-vs-default) — gets its
///     own `...Draft` type here, field-compatible in spirit but `Optional`
///     wherever the schema allows the key to be absent, so "absent" and
///     "present with the default value" stay distinguishable all the way
///     through a parse → edit → serialize round trip.
///   - Every field the loader has no reason to touch at all (`meta.title`,
///     `Session.anchor`, `Recovery`, `Advancement`, ...) is modeled fresh,
///     straight off the schema.
///
/// See `CurriculumDraft+Document.swift` for `init(fromDocument:)` /
/// `toDocument()` (the JSON round trip) and `CurriculumDraftTests.swift`
/// for the 15/15 built-in round-trip proof.

// MARK: - Meta

public struct MetaDraft: Sendable {
    public var slug: String
    /// Required by schema (`LocalizedText.ar` is required); `en` optional.
    public var title: [String: String]
    public var description: [String: String]?
    public var pedagogyNotes: [String: String]?
    /// Required key; may be an empty array.
    public var nonNegotiables: [String]
    public var origin: String?
    public var licenseNote: String?
    /// `nil` means the key is ABSENT from the document — the schema's own
    /// stated default is "1.0.0" (PC-2), but applying that default is a
    /// CONSUMER concern, not this model's: filling it in here would turn an
    /// unauthored field into an authored one and break the round trip.
    public var version: String?
    public var corpora: [String]?

    public init(
        slug: String, title: [String: String], description: [String: String]? = nil,
        pedagogyNotes: [String: String]? = nil, nonNegotiables: [String] = [], origin: String? = nil,
        licenseNote: String? = nil, version: String? = nil, corpora: [String]? = nil
    ) {
        self.slug = slug
        self.title = title
        self.description = description
        self.pedagogyNotes = pedagogyNotes
        self.nonNegotiables = nonNegotiables
        self.origin = origin
        self.licenseNote = licenseNote
        self.version = version
        self.corpora = corpora
    }
}

// MARK: - Units

public struct UnitsDraft: Sendable {
    public var allowed: [QuranUnit]
    public var defaultPace: QuranAmount

    public init(allowed: [QuranUnit], defaultPace: QuranAmount) {
        self.allowed = allowed
        self.defaultPace = defaultPace
    }
}

// MARK: - Calendar

public struct CalendarDraft: Sendable {
    public var weekStart: Weekday
    /// day-class name -> weekdays, in AUTHORED ORDER. `CompiledCurriculum`
    /// uses `Set<Weekday>` here (the engine only ever tests membership) —
    /// that would silently reorder an author's `["fri","sat"]` into
    /// whatever order `Set` iterates in, which is not a lossless round trip.
    public var dayClasses: [String: [Weekday]]
    /// Required key; may be an empty array.
    public var exceptionClasses: [String]

    public init(weekStart: Weekday, dayClasses: [String: [Weekday]], exceptionClasses: [String] = []) {
        self.weekStart = weekStart
        self.dayClasses = dayClasses
        self.exceptionClasses = exceptionClasses
    }
}

// MARK: - Sessions

/// `Session.anchor` (`curriculum-v1.schema.json` `SessionAnchor`).
/// `CompiledCurriculum` doesn't parse this at all today (no engine rule
/// consumes it yet); a draft must still round-trip it.
public enum SessionAnchorDraft: Sendable {
    case fixed
    case prayerRelative(prayer: String, offsetMinutes: Int)
}

public struct SessionDraft: Sendable {
    public var id: String
    public var title: [String: String]
    /// Raw `"HH:mm"` text; format is schema/gate-1's concern, not this
    /// model's — a draft mid-edit may transiently hold an invalid time.
    public var defaultTime: String
    public var anchor: SessionAnchorDraft

    public init(id: String, title: [String: String], defaultTime: String, anchor: SessionAnchorDraft) {
        self.id = id
        self.title = title
        self.defaultTime = defaultTime
        self.anchor = anchor
    }
}

// MARK: - Variables

public struct VariableDraft: Sendable {
    public var kind: VariableDef.Kind
    /// Raw, exactly like `CompiledCurriculum.VariableDef.defaultValue` — the
    /// shape varies by `kind` (number/bool/string/weekday array/amount
    /// object) and JSON is already a lossless carrier for all of them, so
    /// there is nothing to gain (and real precision to lose, see
    /// `CurriculumDraft+Document.swift`'s header) by decomposing further.
    public var defaultValue: JSONValue
    public var minimum: Int?
    public var maximum: Int?
    /// Only meaningful for `kind == .enum`; empty when unused (never emits
    /// a `values` key on serialization either way — the schema requires
    /// `values` to be non-empty when present).
    public var enumValues: [String]
    public var nonNegotiable: Bool?
    /// Schema field `CompiledCurriculum.VariableDef` does not carry at all
    /// (unused by all 15 built-ins; still schema-legal, so a draft must be
    /// able to hold it).
    public var locked: Bool?

    public init(
        kind: VariableDef.Kind, defaultValue: JSONValue, minimum: Int? = nil, maximum: Int? = nil,
        enumValues: [String] = [], nonNegotiable: Bool? = nil, locked: Bool? = nil
    ) {
        self.kind = kind
        self.defaultValue = defaultValue
        self.minimum = minimum
        self.maximum = maximum
        self.enumValues = enumValues
        self.nonNegotiable = nonNegotiable
        self.locked = locked
    }
}

// MARK: - Rules

/// Preserves whether `RuleWhen.day_class` was authored as a string or array.
public enum DayClassSpec: Sendable {
    case single(String)
    case multiple([String])

    public var names: [String] {
        switch self {
        case .single(let s): return [s]
        case .multiple(let names): return names
        }
    }
}

public struct RuleWhenDraft: Sendable {
    public var dayClass: DayClassSpec
    public var session: String
    /// Schema types `RuleWhen.day_in` as `VarRef` ONLY (never a literal
    /// weekday array) — `WeekdaySetOrVar` is reused anyway (mirrors
    /// `CompiledCurriculum`) because it is already exactly the right leaf
    /// type; its `.value` case is simply unreachable for any schema-valid
    /// document.
    public var dayIn: WeekdaySetOrVar?
    /// Variable NAME only (no `$`), matching `CompiledCurriculum.RuleWhen
    /// .enabledVar`.
    public var enabledVar: String?
    /// Empty when the `not` key is absent — schema requires `minItems: 1`
    /// when present, so "absent" and "empty" can never both be legal,
    /// making this the same safe collapse `CompiledCurriculum` already uses.
    public var notConditions: [NotCondition]

    public init(
        dayClass: DayClassSpec, session: String, dayIn: WeekdaySetOrVar? = nil, enabledVar: String? = nil,
        notConditions: [NotCondition] = []
    ) {
        self.dayClass = dayClass
        self.session = session
        self.dayIn = dayIn
        self.enabledVar = enabledVar
        self.notConditions = notConditions
    }
}

/// `RuleEmit.window` (`curriculum-v1.schema.json` `TaskWindow`). A small
/// named struct rather than `CompiledCurriculum`'s bare tuple — friendlier
/// for a future SwiftUI form binding two `Weekday` pickers.
public struct RuleWindowDraft: Sendable {
    public var opens: Weekday
    public var closes: Weekday

    public init(opens: Weekday, closes: Weekday) {
        self.opens = opens
        self.closes = closes
    }
}

public struct RuleEmitDraft: Sendable {
    /// Raw `TaskType` string, exactly like `CompiledCurriculum.RuleEmit
    /// .type` (not decomposed into a closed Swift enum there either).
    public var type: String
    public var select: SelectorRef?
    public var repetitions: IntOrVar?
    public var spacingMinutes: IntOrVar?
    public var listenCount: IntOrVar?
    public var window: RuleWindowDraft?
    /// Preserves whether `info_only` was omitted or explicitly set.
    public var infoOnly: Bool?
    public var ordering: Int
    public var label: [String: String]?
    public var estMinutes: Int?

    public init(
        type: String, select: SelectorRef? = nil, repetitions: IntOrVar? = nil, spacingMinutes: IntOrVar? = nil,
        listenCount: IntOrVar? = nil, window: RuleWindowDraft? = nil, infoOnly: Bool? = nil, ordering: Int,
        label: [String: String]? = nil, estMinutes: Int? = nil
    ) {
        self.type = type
        self.select = select
        self.repetitions = repetitions
        self.spacingMinutes = spacingMinutes
        self.listenCount = listenCount
        self.window = window
        self.infoOnly = infoOnly
        self.ordering = ordering
        self.label = label
        self.estMinutes = estMinutes
    }
}

public struct RuleSpecDraft: Sendable {
    public var id: String
    public var when: RuleWhenDraft
    public var emit: RuleEmitDraft
    public var explanation: [String: String]?
    /// Empty when the `suppressed_by` key is absent (same "empty is never
    /// separately legal" argument as `notConditions`).
    public var suppressedBy: [String]

    public init(
        id: String, when: RuleWhenDraft, emit: RuleEmitDraft, explanation: [String: String]? = nil,
        suppressedBy: [String] = []
    ) {
        self.id = id
        self.when = when
        self.emit = emit
        self.explanation = explanation
        self.suppressedBy = suppressedBy
    }
}

// MARK: - Triggers

public struct ScheduleEffectDraft: Sendable {
    public var type: String
    public var select: SelectorRef
    public var distributeOverDays: Int?
    public var intoSession: String?
    /// Preserves whether `starting` was omitted or explicitly set to
    /// `next_active_day`. The compiled model supplies this default when absent.
    public var starting: String?
    public var label: [String: String]?
    public var estMinutes: Int?

    public init(
        type: String, select: SelectorRef, distributeOverDays: Int? = nil, intoSession: String? = nil,
        starting: String? = nil, label: [String: String]? = nil, estMinutes: Int? = nil
    ) {
        self.type = type
        self.select = select
        self.distributeOverDays = distributeOverDays
        self.intoSession = intoSession
        self.starting = starting
        self.label = label
        self.estMinutes = estMinutes
    }
}

public struct InsertWeekEffectDraft: Sendable {
    public var name: String
    public var modeVar: String?
    /// May legitimately be `[]` (schema `minItems: 0`) — a pure pause week
    /// (E-5/D-047) adds no rules of its own.
    public var dayRules: [RuleSpecDraft]

    public init(name: String, modeVar: String? = nil, dayRules: [RuleSpecDraft] = []) {
        self.name = name
        self.modeVar = modeVar
        self.dayRules = dayRules
    }
}

public enum TriggerEffectDraft: Sendable {
    case schedule(ScheduleEffectDraft)
    case insertWeek(InsertWeekEffectDraft)
    case setFlag(name: String, until: String?)
    case clearFlag(name: String)
    case completePlan
}

public struct TriggerSpecDraft: Sendable {
    public var id: String
    /// Reused directly from `CompiledCurriculum` — `TriggerOn` has no
    /// default-fill or shape-collapsing issue (`.boundary`'s `every`,
    /// `.cursorReaches`, `.taskFailed` are all either required or cleanly
    /// `Optional` already).
    public var on: TriggerOn
    public var effects: [TriggerEffectDraft]

    public init(id: String, on: TriggerOn, effects: [TriggerEffectDraft]) {
        self.id = id
        self.on = on
        self.effects = effects
    }
}

// MARK: - Recovery / Advancement / Forecast

public struct RecoveryDraft: Sendable {
    public var allowedPolicies: [String]
    /// Swift property named `defaultPolicy` (not `default`, a keyword) —
    /// maps to the JSON key `"default"` in `CurriculumDraft+Document.swift`.
    public var defaultPolicy: String
    public var escalationDays: Int

    public init(allowedPolicies: [String], defaultPolicy: String, escalationDays: Int) {
        self.allowedPolicies = allowedPolicies
        self.defaultPolicy = defaultPolicy
        self.escalationDays = escalationDays
    }
}

public struct AdvancementDraft: Sendable {
    public var requireVerified: Bool?

    public init(requireVerified: Bool? = nil) {
        self.requireVerified = requireVerified
    }
}

public struct ForecastDraft: Sendable {
    /// Raw JSONValue per rate/factor name, not `DecimalValue` — see
    /// `CurriculumDraft+Document.swift`'s header for why (workload rates are
    /// schema-`integer`, always safe, but `strength_factors` are schema-
    /// `number` and every real built-in authors non-integer values like
    /// `1.5`/`1.2`; raw pass-through is the simplest representation that
    /// cannot mis-reformat either one).
    public var workloadRates: [String: JSONValue]
    public var strengthFactors: [String: JSONValue]

    public init(workloadRates: [String: JSONValue], strengthFactors: [String: JSONValue]) {
        self.workloadRates = workloadRates
        self.strengthFactors = strengthFactors
    }
}

// MARK: - CurriculumDraft

/// The full editable document. All top-level fields mirror
/// `curriculum-v1.schema.json`'s root object: `meta`/`units`/`calendar`/
/// `sessions`/`variables`/`selectors`/`rules`/`triggers`/`forecast` are
/// schema-required (non-optional here); `recovery`/`advancement`/
/// `evidence_defaults` are schema-optional (`Optional` here, `nil` meaning
/// the key is absent from the document, never meaning "use the schema's
/// stated default" — see each field's own doc comment).
public struct CurriculumDraft: Sendable {
    public var meta: MetaDraft
    public var units: UnitsDraft
    public var calendar: CalendarDraft
    public var sessions: [SessionDraft]
    /// variable name -> definition.
    public var variables: [String: VariableDraft]
    /// selector name -> spec. Reused directly from `CompiledCurriculum`
    /// (`SelectorSpec`/`SelectorRef`/`PoolWindow`/`PerDaySpec` have no
    /// default-fill or shape-collapsing issue anywhere in their parse).
    public var selectors: [String: SelectorSpec]
    /// Optional root-level exact-execution task deduplication mode.
    public var taskDeduplication: TaskDeduplicationMode?
    /// Schema requires `minItems: 1`; a draft mid-edit may transiently be
    /// empty, so this stays a plain (non-`Optional`, non-enforced) array —
    /// enforcing "at least one rule" is gate 1/2's job (`CurriculumValidator`
    /// via CB-3/CB-5), not this model's.
    public var rules: [RuleSpecDraft]
    public var triggers: [TriggerSpecDraft]
    public var recovery: RecoveryDraft?
    public var advancement: AdvancementDraft?
    /// Raw pass-through, exactly like `CompiledCurriculum.evidenceDefaults`
    /// (an `EvidenceSpec` is author-composable data resolved against
    /// variables at emit time, not something this model needs typed access
    /// to). `nil` = key absent (schema `minProperties: 1` when present, so
    /// "absent" and "empty" can never both be legal — same collapse
    /// `CompiledCurriculum` already relies on for this exact field).
    public var evidenceDefaults: [String: JSONValue]?
    public var forecast: ForecastDraft

    public init(
        meta: MetaDraft, units: UnitsDraft, calendar: CalendarDraft, sessions: [SessionDraft],
        variables: [String: VariableDraft] = [:], selectors: [String: SelectorSpec] = [:],
        taskDeduplication: TaskDeduplicationMode? = nil,
        rules: [RuleSpecDraft] = [], triggers: [TriggerSpecDraft] = [], recovery: RecoveryDraft? = nil,
        advancement: AdvancementDraft? = nil, evidenceDefaults: [String: JSONValue]? = nil,
        forecast: ForecastDraft
    ) {
        self.meta = meta
        self.units = units
        self.calendar = calendar
        self.sessions = sessions
        self.variables = variables
        self.selectors = selectors
        self.taskDeduplication = taskDeduplication
        self.rules = rules
        self.triggers = triggers
        self.recovery = recovery
        self.advancement = advancement
        self.evidenceDefaults = evidenceDefaults
        self.forecast = forecast
    }
}

// MARK: - Reserved-name guard (D-028)

extension CurriculumDraft {
    /// D-028: `$pace` is bound by the engine from `PlanPolicy.new_amount`
    /// (falling back to `units.default_pace`); no curriculum may declare its
    /// own variable named `pace` (`CompiledCurriculum.swift`'s
    /// `CurriculumLoader.load` throws `CurriculumError.invalidReference` on
    /// this at gate 2). `$pace` REFERENCES (`IntOrVar`/`AmountOrVar
    /// .ref("pace")`, e.g. a `next_new.amount: "$pace"` selector) are a
    /// separate, legitimate, and common case — 13 of the 15 built-ins use
    /// one — and are unaffected by this guard, which only concerns
    /// DECLARING a variable under this name.
    public static let reservedVariableName = "pace"

    /// Safe entry point for a builder UI to add/rename a variable: rejects
    /// the reserved name up front instead of silently producing a draft
    /// that gate 2 will reject later with a less actionable error. Direct
    /// mutation of `.variables[name] = ...` remains possible (this is an
    /// editable model, not a locked-down one) and is NOT guarded — exactly
    /// as hand-authoring the JSON directly would also not be guarded until
    /// validation runs; this method exists so the common UI path doesn't
    /// have to reimplement the check.
    @discardableResult
    public mutating func setVariable(name: String, _ definition: VariableDraft) throws -> VariableDraft? {
        guard name != Self.reservedVariableName else {
            throw CurriculumError.invalidReference(
                "variable name 'pace' is reserved (D-028: $pace binds PlanPolicy.new_amount)")
        }
        return variables.updateValue(definition, forKey: name)
    }
}
