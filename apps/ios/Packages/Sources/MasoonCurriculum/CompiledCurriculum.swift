import MasoonDomain

/// Typed model of `curriculum-v1` compiled definitions (PRD §8.2/§8.3,
/// the curriculum-v1 schema). The loader validates
/// references, including the D-028 `$pace` binding conventions:
/// `$pace` is a reserved variable bound by the engine from
/// `PlanPolicy.new_amount` (falling back to `units.default_pace`); it is
/// treated as always defined; no curriculum may declare a variable named `pace`.

public enum CurriculumError: Error, CustomStringConvertible {
    case malformed(String)
    case invalidReference(String)
    public var description: String {
        switch self {
        case .malformed(let m): return "curriculum malformed: \(m)"
        case .invalidReference(let m): return "curriculum invalid reference: \(m)"
        }
    }
}

// MARK: - Value-or-variable references

public enum IntOrVar: Hashable, Sendable {
    case value(Int)
    case ref(String)

    init?(json: JSONValue) {
        if let i = json.intValue { self = .value(i); return }
        if let s = json.stringValue, s.hasPrefix("$") { self = .ref(String(s.dropFirst())); return }
        return nil
    }
}

public enum AmountOrVar: Hashable, Sendable {
    case value(QuranAmount)
    case ref(String)

    init?(json: JSONValue) {
        if let s = json.stringValue, s.hasPrefix("$") { self = .ref(String(s.dropFirst())); return }
        if let a = QuranAmount(json: json) { self = .value(a); return }
        return nil
    }
}

public enum WeekdaySetOrVar: Hashable, Sendable {
    case value(Set<Weekday>)
    case ref(String)

    init?(json: JSONValue) {
        if let s = json.stringValue, s.hasPrefix("$") { self = .ref(String(s.dropFirst())); return }
        if let arr = json.arrayValue {
            var set: Set<Weekday> = []
            for item in arr {
                guard let code = item.stringValue, let wd = Weekday(code: code) else { return nil }
                set.insert(wd)
            }
            self = .value(set)
            return
        }
        return nil
    }
}

// MARK: - DSL nodes

public struct VariableDef: Sendable {
    public enum Kind: String, Sendable { case int, bool, amount, weekdaySet = "weekday_set", `enum` }
    public let kind: Kind
    public let defaultValue: JSONValue
    public let nonNegotiable: Bool
    public let enumValues: [String]
    /// The bounds the curriculum declares for an int variable (schema `min`/`max`).
    /// Present so a UI can offer the knob without inventing its own range.
    public let minimum: Int?
    public let maximum: Int?
}

/// E-1 (D-038): which prior ḥifẓ a murājaʿah layer rotates.
public enum PoolWindow: Sendable, Equatable {
    case priorHifz
    case recentPages(IntOrVar)
    case recentJuz(IntOrVar)
    /// E-1b (D-043): the exact complement of the recent window — material that
    /// has ROLLED OFF it (ITQAAN's list of pages beyond the active window).
    case allExceptRecentPages(IntOrVar)
    case allExceptRecentJuz(IntOrVar)
}

/// How much of a murājaʿah pool to take each day.
public enum PerDaySpec: Sendable, Equatable {
    /// Grows with WEEKS elapsed, capped at a ceiling.
    case ramp(start: AmountOrVar, step: AmountOrVar, ceiling: AmountOrVar)
    /// E-3a (D-045): cover the whole pool every N days. The amount derives from the
    /// POOL SIZE, so each item's review interval stays FIXED as the corpus grows —
    /// the South-Asian Dhor mechanic, which a ramp cannot express.
    case cycleDays(IntOrVar)
}

public indirect enum SelectorSpec: Sendable {
    case nextContent(amount: AmountOrVar)
    case nextNew(amount: AmountOrVar)
    case ledgerWindow(days: IntOrVar, sundayDays: IntOrVar?)
    case ledgerOffset(daysAgo: IntOrVar)
    case weekToDate
    /// `perDay` is either a weeks-based ramp or E-3a fixed-interval cycling (D-045).
    case poolRotation(pool: PoolWindow, perDay: PerDaySpec, weakBoost: IntOrVar?)
    case completedJuz
    case priorHifzSplit(parts: Int)
    case block(juzCount: IntOrVar)
    case tomorrowNew
    case fixed(ranges: [CanonicalRange])
    case blockSlice(of: String, parts: Int)
    case intersectPriorHifz(of: SelectorRef)
}

public enum SelectorRef: Sendable {
    case named(String)
    case inline(SelectorSpec)
}

public enum TaskDeduplicationMode: String, Sendable {
    case exactExecution = "exact_execution"
}

public enum NotCondition: Hashable, Sendable {
    case firstActiveDay
    case inConsolidationWeek
    case hasFlag(String)
}

public struct RuleWhen: Sendable {
    public let dayClasses: [String]
    public let session: String
    public let dayIn: WeekdaySetOrVar?
    /// D-028(4): explicit rule enablement via a bool variable ref.
    public let enabledVar: String?
    public let notConditions: [NotCondition]
}

public struct RuleEmit: Sendable {
    public let type: String
    public let select: SelectorRef?
    public let repetitions: IntOrVar?
    public let spacingMinutes: IntOrVar?
    public let listenCount: IntOrVar?
    public let window: (opens: Weekday, closes: Weekday)?
    public let infoOnly: Bool
    public let ordering: Int
    /// B:CB-1/D-053 (Stage 1 schema; Stage 3 engine wiring, CB-2). OPTIONAL
    /// authored display label overriding the presentation layer's generic
    /// per-type title (`{"ar": …, "en": …}`, same shape/precedent as
    /// `RuleSpec.explanation`). `nil` when unauthored — no existing built-in
    /// curriculum sets this.
    public let label: [String: String]?
    /// B:CB-1/D-054. OPTIONAL authored minute estimate overriding the
    /// rate-lookup forecast for this rule's emitted tasks — checked FIRST in
    /// `EngineRun.estimateMinutes`, before the `prep_dhikr` zero-out, before
    /// any rate lookup. `nil` when unauthored (every built-in curriculum
    /// today) falls through to existing behavior unchanged.
    public let estMinutes: Int?
}

public struct RuleSpec: Sendable {
    public let id: String
    public let when: RuleWhen
    public let emit: RuleEmit
    /// Optional explanation authored next to the rule
    /// (`{"ar": …, "en": …}`), mirroring the `Session.title` precedent so
    /// authoring a rule and its explanation are the same act. `nil` when the
    /// curriculum author has not (yet) written one — the presentation layer
    /// must fall back to an honest generic line, never invented pedagogy.
    public let explanation: [String: String]?
    public let suppressedBy: [String]
}

public enum TriggerOn: Sendable {
    case boundary(kind: String, every: IntOrVar?)
    case cursorReaches(CanonicalRange)
    /// E-5 (D-047): fires when the task emitted by `rule` on a CLOSED day was not
    /// verified.
    case taskFailed(rule: String)
}

public enum TriggerEffect: Sendable {
    /// `label`/`estMinutes`: B:CB-1/D-053/D-054, CB-2. Mirror `RuleEmit`'s
    /// fields for trigger-scheduled tasks, whose synthetic
    /// `"<triggerId>.<type>"` origin id matches no literal `RuleEmit`.
    case schedule(
        type: String, select: SelectorRef, distributeOverDays: Int?, intoSession: String?, starting: String,
        label: [String: String]?, estMinutes: Int?)
    case insertWeek(name: String, modeVar: String?, dayRules: [RuleSpec])
    case setFlag(name: String, until: String?)
    case clearFlag(name: String)
    case completePlan
}

public struct TriggerSpec: Sendable {
    public let id: String
    public let on: TriggerOn
    public let effects: [TriggerEffect]
}

public struct CompiledCurriculum: Sendable {
    public let slug: String
    public let nonNegotiables: [String]
    public let allowedUnits: [QuranUnit]
    public let defaultPace: QuranAmount
    public let weekStart: Weekday
    /// day-class name -> weekdays
    public let dayClasses: [String: Set<Weekday>]
    public let exceptionClasses: [String]
    /// session ids in declared order (serialization tie-break rank)
    public let sessionIds: [String]
    /// session id -> localized titles the curriculum declares (`{"ar": …, "en": …}`).
    public let sessionTitles: [String: [String: String]]
    /// session id -> the curriculum's authored `default_time` ("HH:mm"),
    /// REQUIRED by the schema (curriculum-v1.schema.json:206) and already
    /// consumed by the Kotlin and TypeScript engines. iOS must seed session
    /// start times from this, not a hardcoded morning/evening guess.
    public let sessionDefaultTimes: [String: String]
    public let variables: [String: VariableDef]
    public let selectors: [String: SelectorSpec]
    public let rules: [RuleSpec]
    public let triggers: [TriggerSpec]
    public let taskDeduplication: TaskDeduplicationMode?
    public let recoveryDefault: String
    public let escalationDays: Int
    /// E-4b (D-046): advancement requires a VERIFIED pass — a teacher-rejected
    /// (mardūd) sabaq holds the cursor (and owes debt like any fail, D-048).
    ///
    /// NB (D-048): there is deliberately no `gate` knob. It once meant "an
    /// unmastered portion owes no debt"; a fail becomes debt, so it had nothing
    /// left to do and was removed rather than kept as a misleading no-op.
    public let requireVerified: Bool
    /// task_type (or "default") -> raw evidence JSON (resolved against variables at emit time)
    public let evidenceDefaults: [String: JSONValue]
    /// workload rates as exact decimals, keyed by rate name
    public let workloadRates: [String: DecimalValue]
    /// strength factors scaled x1000
    public let strengthFactorsScaled: [Strength: Int64]
    /// C:PCC-8/PCC-13. Which content corpora this curriculum applies to
    /// (`meta.corpora`, curriculum-v1.schema.json). Absence in the source
    /// document means Qur'an-only (the pre-existing, unstated default for
    /// all 15 built-ins) — `load(json:)` below applies that default, so this
    /// is never empty. Presentation-only: nothing in generation/forecasting
    /// reads this field, so its presence cannot affect `expected.stream`
    /// output for any fixture (additive metadata, same pattern as Stage 2's
    /// `CanonicalRange`/`CanonicalPosition` alias additions).
    public let corpora: [String]

    /// Explicit initializer (rather than the implicit memberwise one) so
    /// `corpora` can default to `["quran"]` for any pre-existing call site
    /// that predates this field (test fixtures that construct a mutated
    /// copy from an existing instance's other fields).
    public init(
        slug: String, nonNegotiables: [String], allowedUnits: [QuranUnit], defaultPace: QuranAmount,
        weekStart: Weekday, dayClasses: [String: Set<Weekday>], exceptionClasses: [String], sessionIds: [String],
        sessionTitles: [String: [String: String]], sessionDefaultTimes: [String: String],
        variables: [String: VariableDef], selectors: [String: SelectorSpec], rules: [RuleSpec],
        triggers: [TriggerSpec], taskDeduplication: TaskDeduplicationMode? = nil,
        recoveryDefault: String, escalationDays: Int, requireVerified: Bool,
        evidenceDefaults: [String: JSONValue], workloadRates: [String: DecimalValue],
        strengthFactorsScaled: [Strength: Int64], corpora: [String] = ["quran"]
    ) {
        self.slug = slug
        self.nonNegotiables = nonNegotiables
        self.allowedUnits = allowedUnits
        self.defaultPace = defaultPace
        self.weekStart = weekStart
        self.dayClasses = dayClasses
        self.exceptionClasses = exceptionClasses
        self.sessionIds = sessionIds
        self.sessionTitles = sessionTitles
        self.sessionDefaultTimes = sessionDefaultTimes
        self.variables = variables
        self.selectors = selectors
        self.rules = rules
        self.triggers = triggers
        self.taskDeduplication = taskDeduplication
        self.recoveryDefault = recoveryDefault
        self.escalationDays = escalationDays
        self.requireVerified = requireVerified
        self.evidenceDefaults = evidenceDefaults
        self.workloadRates = workloadRates
        self.strengthFactorsScaled = strengthFactorsScaled
        self.corpora = corpora
    }

    /// The curriculum's own name for a session, in the UI language. Arabic mode
    /// takes `ar`; the two English-skeleton modes take `en` (D-036).
    public func sessionTitle(id: String, arabic: Bool) -> String? {
        guard let title = sessionTitles[id] else { return nil }
        return arabic ? (title["ar"] ?? title["en"]) : (title["en"] ?? title["ar"])
    }

    /// The curriculum's explanation for a rule id, in the UI
    /// language (arabic mode takes `ar`; the two English-skeleton modes take
    /// `en`). `nil` when the rule declares none — callers must fall back to
    /// an honest generic line, never invented pedagogy.
    public func explanation(forRuleId id: String, arabic: Bool) -> String? {
        func text(_ dict: [String: String]?) -> String? {
            guard let dict else { return nil }
            return arabic ? (dict["ar"] ?? dict["en"]) : (dict["en"] ?? dict["ar"])
        }
        if let rule = rules.first(where: { $0.id == id }), let text = text(rule.explanation) {
            return text
        }
        // Inserted-week day rules (E-5) keep their declared ids too.
        for trigger in triggers {
            for effect in trigger.effects {
                if case .insertWeek(_, _, let dayRules) = effect,
                   let rule = dayRules.first(where: { $0.id == id }),
                   let text = text(rule.explanation) {
                    return text
                }
            }
        }
        // CB-2: the SPLIT trigger id step `label(forRuleId:)` below performs —
        // trigger-scheduled tasks (Engine.swift §11.2) get a synthetic
        // "<triggerId>.<type>" origin id matching no literal rule id from
        // either step above, so this function fell through to the generic
        // `nil` fallback for them too, same as everything else unmatched.
        // Added here for identical resolution SHAPE to `label(forRuleId:)`.
        // Genuinely inert by construction, not just by luck: `ScheduleEffect`
        // (unlike `RuleEmit`) carries no `explanation` field in the schema —
        // only `RuleSpec` does — so there is no text this step could ever
        // find; it can never return non-nil, and therefore cannot change any
        // existing curriculum's `explanation(forRuleId:)` result. Verified:
        // none of the 15 built-ins are affected (nothing IS affected, since
        // this branch is unreachable-to-a-result by schema construction).
        for trigger in triggers {
            for effect in trigger.effects {
                guard case .schedule(let type, _, _, _, _, _, _) = effect,
                      id == "\(trigger.id).\(type)"
                else { continue }
                return nil
            }
        }
        return nil
    }

    /// The curriculum's own authored display label for a rule/schedule-
    /// effect origin id, in the UI language (CB-2, B:CB-1/D-053/D-054).
    /// Resolution order: rule id -> inserted-week rule -> SPLIT trigger id
    /// (the synthetic `"<triggerId>.<type>"` form Engine.swift stamps on
    /// trigger-scheduled tasks, §11.2) -> nil. `nil` at every step (every
    /// built-in curriculum today authors no `label`) means the CALLER falls
    /// back to its own generic per-type label — mirrors
    /// `explanation(forRuleId:)`'s house pattern exactly (return `nil`, let
    /// the presentation layer supply the honest generic line) rather than
    /// baking a presentation-layer fallback table into this lower package.
    public func label(forRuleId id: String, arabic: Bool) -> String? {
        func text(_ dict: [String: String]?) -> String? {
            guard let dict else { return nil }
            return arabic ? (dict["ar"] ?? dict["en"]) : (dict["en"] ?? dict["ar"])
        }
        if let rule = rules.first(where: { $0.id == id }), let text = text(rule.emit.label) {
            return text
        }
        for trigger in triggers {
            for effect in trigger.effects {
                if case .insertWeek(_, _, let dayRules) = effect,
                   let rule = dayRules.first(where: { $0.id == id }),
                   let text = text(rule.emit.label) {
                    return text
                }
            }
        }
        for trigger in triggers {
            for effect in trigger.effects {
                guard case .schedule(let type, _, _, _, _, let scheduleLabel, _) = effect,
                      id == "\(trigger.id).\(type)",
                      let text = text(scheduleLabel)
                else { continue }
                return text
            }
        }
        return nil
    }

    public func dayClass(of weekday: Weekday) -> String? {
        // Deterministic: check classes in sorted-name order (classes are disjoint by construction).
        for name in dayClasses.keys.sorted() {
            if dayClasses[name]!.contains(weekday) { return name }
        }
        return nil
    }

    /// The union of weekdays across every `day_class` at least one rule of
    /// `emitType` fires on — including day rules an `insert_week` trigger
    /// effect inserts (a consolidation/failure week's own `day_rules`,
    /// D-047). Empty when the curriculum declares no rule of that emit type
    /// at all (e.g. `"new_hifz"` on a revision-only curriculum like
    /// 7-Manzil/Muraja'ah-Only, or `"listening"` on a curriculum that never
    /// schedules listening). Callers must treat an empty result as "this
    /// curriculum has no opinion here, leave the existing policy value
    /// alone" — never as "scheduled on zero days."
    ///
    /// Batch 3 Stage 6 (PC-11): this is the SAME derivation
    /// `FeatureOnboarding.OnboardingPolicyBuilder.policyJSON` used inline for
    /// `active_weekdays` before this stage — centralized here (the layer
    /// both `FeatureOnboarding` and `MasoonData`'s `CurriculumSwitchValidator`
    /// can reach) so a fresh onboarding plan and a curriculum switch's
    /// reconciling patch can never silently diverge on what "this
    /// curriculum's new-hifz/listening days" means by running two
    /// independently hand-rolled parsers over the same `rules`/`dayClasses`.
    public func weekdayUnion(forEmitType emitType: String) -> Set<Weekday> {
        var classes = Set(rules.filter { $0.emit.type == emitType }.flatMap { $0.when.dayClasses })
        for trigger in triggers {
            for effect in trigger.effects {
                if case .insertWeek(_, _, let dayRules) = effect {
                    classes.formUnion(dayRules.filter { $0.emit.type == emitType }.flatMap { $0.when.dayClasses })
                }
            }
        }
        var weekdays = Set<Weekday>()
        for dc in classes { weekdays.formUnion(dayClasses[dc] ?? []) }
        return weekdays
    }

    /// `weekdayUnion(forEmitType: "new_hifz")` — the days this curriculum
    /// schedules NEW memorization on.
    public var newHifzWeekdays: Set<Weekday> { weekdayUnion(forEmitType: "new_hifz") }
}

// MARK: - Loader

public enum CurriculumLoader {
    public static func load(json: JSONValue) throws -> CompiledCurriculum {
        guard let root = json.objectValue else { throw CurriculumError.malformed("root is not an object") }

        // meta
        guard let meta = root["meta"]?.objectValue, let slug = meta["slug"]?.stringValue else {
            throw CurriculumError.malformed("meta.slug missing")
        }
        let nonNegotiables = (meta["non_negotiables"]?.arrayValue ?? []).compactMap(\.stringValue)
        // C:PCC-8/PCC-13. Absence means Qur'an-only (schema-documented default).
        let corpora = meta["corpora"]?.arrayValue?.compactMap(\.stringValue) ?? ["quran"]

        // units
        guard let units = root["units"]?.objectValue,
              let allowedJSON = units["allowed"]?.arrayValue,
              let paceJSON = units["default_pace"], let defaultPace = QuranAmount(json: paceJSON)
        else { throw CurriculumError.malformed("units missing or malformed") }
        var allowed: [QuranUnit] = []
        for item in allowedJSON {
            guard let s = item.stringValue, let unit = QuranUnit(rawValue: s) else {
                throw CurriculumError.malformed("bad unit in units.allowed")
            }
            allowed.append(unit)
        }

        // calendar
        guard let calendar = root["calendar"]?.objectValue,
              let weekStartCode = calendar["week_start"]?.stringValue,
              let weekStart = Weekday(code: weekStartCode),
              let dayClassesJSON = calendar["day_classes"]?.objectValue
        else { throw CurriculumError.malformed("calendar missing or malformed") }
        var dayClasses: [String: Set<Weekday>] = [:]
        for (name, value) in dayClassesJSON {
            guard let arr = value.arrayValue else { throw CurriculumError.malformed("day_classes.\(name) not an array") }
            var set: Set<Weekday> = []
            for item in arr {
                guard let code = item.stringValue, let wd = Weekday(code: code) else {
                    throw CurriculumError.malformed("bad weekday in day_classes.\(name)")
                }
                set.insert(wd)
            }
            dayClasses[name] = set
        }
        let exceptionClasses = (calendar["exception_classes"]?.arrayValue ?? []).compactMap(\.stringValue)

        // sessions
        guard let sessionsJSON = root["sessions"]?.arrayValue, !sessionsJSON.isEmpty else {
            throw CurriculumError.malformed("sessions missing")
        }
        var sessionIds: [String] = []
        var sessionTitles: [String: [String: String]] = [:]
        var sessionDefaultTimes: [String: String] = [:]
        for item in sessionsJSON {
            guard let id = item["id"]?.stringValue else { throw CurriculumError.malformed("session missing id") }
            sessionIds.append(id)
            if let title = item["title"]?.objectValue {
                sessionTitles[id] = title.compactMapValues(\.stringValue)
            }
            if let defaultTime = item["default_time"]?.stringValue {
                sessionDefaultTimes[id] = defaultTime
            }
        }

        // variables (D-028: no curriculum may declare a variable named "pace")
        var variables: [String: VariableDef] = [:]
        for (name, def) in root["variables"]?.objectValue ?? [:] {
            if name == "pace" {
                throw CurriculumError.invalidReference("variable name 'pace' is reserved (D-028: $pace binds PlanPolicy.new_amount)")
            }
            guard let obj = def.objectValue,
                  let kindStr = obj["type"]?.stringValue,
                  let kind = VariableDef.Kind(rawValue: kindStr),
                  let defaultValue = obj["default"]
            else { throw CurriculumError.malformed("variable \(name) malformed") }
            variables[name] = VariableDef(
                kind: kind,
                defaultValue: defaultValue,
                nonNegotiable: obj["non_negotiable"]?.boolValue ?? false,
                enumValues: (obj["values"]?.arrayValue ?? []).compactMap(\.stringValue),
                minimum: obj["min"]?.intValue,
                maximum: obj["max"]?.intValue)
        }

        // selectors
        var selectors: [String: SelectorSpec] = [:]
        for (name, spec) in root["selectors"]?.objectValue ?? [:] {
            selectors[name] = try parseSelector(spec, context: "selectors.\(name)")
        }

        // rules
        var rules: [RuleSpec] = []
        for item in root["rules"]?.arrayValue ?? [] {
            rules.append(try parseRule(item))
        }
        guard !rules.isEmpty else { throw CurriculumError.malformed("rules must not be empty") }

        // triggers
        var triggers: [TriggerSpec] = []
        for item in root["triggers"]?.arrayValue ?? [] {
            triggers.append(try parseTrigger(item))
        }

        let taskDeduplication: TaskDeduplicationMode?
        if let rawMode = root["task_deduplication"]?["mode"]?.stringValue {
            guard let mode = TaskDeduplicationMode(rawValue: rawMode) else {
                throw CurriculumError.malformed("task_deduplication.mode malformed")
            }
            taskDeduplication = mode
        } else {
            taskDeduplication = nil
        }

        // recovery
        let recovery = root["recovery"]?.objectValue
        let recoveryDefault = recovery?["default"]?.stringValue ?? "strict_backlog"
        let escalationDays = recovery?["escalation_days"]?.intValue ?? 3

        // advancement (E-4b, D-046); absent ⇒ any completion advances
        var requireVerified = false
        if let adv = root["advancement"]?.objectValue, let rv = adv["require_verified"] {
            guard let b = rv.boolValue else {
                throw CurriculumError.malformed("advancement.require_verified must be a boolean")
            }
            requireVerified = b
        }

        // evidence defaults (raw; targets may hold $var refs)
        let evidenceDefaults = root["evidence_defaults"]?.objectValue ?? [:]

        // forecast
        guard let forecast = root["forecast"]?.objectValue,
              let ratesJSON = forecast["workload_rates"]?.objectValue,
              let factorsJSON = forecast["strength_factors"]?.objectValue
        else { throw CurriculumError.malformed("forecast missing") }
        var rates: [String: DecimalValue] = [:]
        for (name, value) in ratesJSON {
            guard let d = value.decimalValue else { throw CurriculumError.malformed("bad workload rate \(name)") }
            rates[name] = d
        }
        var factors: [Strength: Int64] = [:]
        for strength in [Strength.weak, .moderate, .strong] {
            guard let d = factorsJSON[strength.rawValue]?.decimalValue else {
                throw CurriculumError.malformed("missing strength factor \(strength.rawValue)")
            }
            factors[strength] = d.scaled(by: 1000)
        }

        let curriculum = CompiledCurriculum(
            slug: slug,
            nonNegotiables: nonNegotiables,
            allowedUnits: allowed,
            defaultPace: defaultPace,
            weekStart: weekStart,
            dayClasses: dayClasses,
            exceptionClasses: exceptionClasses,
            sessionIds: sessionIds,
            sessionTitles: sessionTitles,
            sessionDefaultTimes: sessionDefaultTimes,
            variables: variables,
            selectors: selectors,
            rules: rules,
            triggers: triggers,
            taskDeduplication: taskDeduplication,
            recoveryDefault: recoveryDefault,
            escalationDays: escalationDays,
            requireVerified: requireVerified,
            evidenceDefaults: evidenceDefaults,
            workloadRates: rates,
            strengthFactorsScaled: factors,
            corpora: corpora)

        try validateReferences(curriculum)
        return curriculum
    }

    // MARK: parsing helpers

    private static func parseSelector(_ json: JSONValue, context: String) throws -> SelectorSpec {
        guard let obj = json.objectValue, obj.count == 1, let key = obj.keys.first, let body = obj[key] else {
            throw CurriculumError.malformed("\(context): selector must have exactly one kind")
        }
        switch key {
        case "next_content":
            guard let amountJSON = body["amount"], let amount = AmountOrVar(json: amountJSON) else {
                throw CurriculumError.malformed("\(context): next_content.amount malformed")
            }
            return .nextContent(amount: amount)
        case "next_new":
            guard let amountJSON = body["amount"], let amount = AmountOrVar(json: amountJSON) else {
                throw CurriculumError.malformed("\(context): next_new.amount malformed")
            }
            return .nextNew(amount: amount)
        case "ledger_window":
            guard let daysJSON = body["days"], let days = IntOrVar(json: daysJSON) else {
                throw CurriculumError.malformed("\(context): ledger_window.days malformed")
            }
            let sunday = body["sunday_days"].flatMap { IntOrVar(json: $0) }
            return .ledgerWindow(days: days, sundayDays: sunday)
        case "ledger_offset":
            guard let json = body["days_ago"], let daysAgo = IntOrVar(json: json) else {
                throw CurriculumError.malformed("\(context): ledger_offset.days_ago malformed")
            }
            return .ledgerOffset(daysAgo: daysAgo)
        case "week_to_date":
            return .weekToDate
        case "pool_rotation":
            let perDay: PerDaySpec
            if let ramp = body["per_day"]?["ramp"]?.objectValue {
                guard let startJSON = ramp["start"], let start = AmountOrVar(json: startJSON),
                      let stepJSON = ramp["step"], let step = AmountOrVar(json: stepJSON),
                      let ceilingJSON = ramp["ceiling"], let ceiling = AmountOrVar(json: ceilingJSON)
                else { throw CurriculumError.malformed("\(context): pool_rotation ramp malformed") }
                perDay = .ramp(start: start, step: step, ceiling: ceiling)
            } else if let cd = body["per_day"]?["cycle_days"], let n = IntOrVar(json: cd) {
                perDay = .cycleDays(n)
            } else {
                throw CurriculumError.malformed("\(context): pool_rotation per_day malformed")
            }
            let pool: PoolWindow
            if body["pool"]?.stringValue == "prior_hifz" {
                pool = .priorHifz
            } else if let po = body["pool"]?.objectValue,
                      let rp = po["recent_pages"], let n = IntOrVar(json: rp) {
                pool = .recentPages(n)
            } else if let po = body["pool"]?.objectValue,
                      let rj = po["recent_juz"], let n = IntOrVar(json: rj) {
                pool = .recentJuz(n)
            } else if let po = body["pool"]?.objectValue,
                      let rp = po["all_except_recent_pages"], let n = IntOrVar(json: rp) {
                pool = .allExceptRecentPages(n)
            } else if let po = body["pool"]?.objectValue,
                      let rj = po["all_except_recent_juz"], let n = IntOrVar(json: rj) {
                pool = .allExceptRecentJuz(n)
            } else {
                throw CurriculumError.malformed("\(context): pool_rotation.pool malformed")
            }
            let weakBoost = body["weak_boost"].flatMap { IntOrVar(json: $0) }
            return .poolRotation(pool: pool, perDay: perDay, weakBoost: weakBoost)
        case "completed_juz":
            guard body["which"]?.stringValue == "last" else {
                throw CurriculumError.malformed("\(context): completed_juz.which must be 'last'")
            }
            return .completedJuz
        case "prior_hifz_split":
            guard let parts = body["parts"]?.intValue, parts >= 1 else {
                throw CurriculumError.malformed("\(context): prior_hifz_split.parts malformed")
            }
            return .priorHifzSplit(parts: parts)
        case "block":
            guard let countJSON = body["juz_count"], let count = IntOrVar(json: countJSON),
                  body["which"]?.stringValue == "last"
            else { throw CurriculumError.malformed("\(context): block malformed") }
            return .block(juzCount: count)
        case "tomorrow_new":
            return .tomorrowNew
        case "fixed":
            guard let rangeJSON = body["range"], let arr = rangeJSON.arrayValue, !arr.isEmpty else {
                throw CurriculumError.malformed("\(context): fixed.range malformed")
            }
            let ranges = try arr.map { el -> CanonicalRange in
                guard let r = CanonicalRange(json: el) else {
                    throw CurriculumError.malformed("\(context): fixed.range item malformed")
                }
                return r
            }
            return .fixed(ranges: ranges)
        case "block_slice":
            guard let of = body["of"]?.stringValue, let parts = body["parts"]?.intValue, parts >= 1 else {
                throw CurriculumError.malformed("\(context): block_slice malformed")
            }
            return .blockSlice(of: of, parts: parts)
        case "intersect_prior_hifz":
            guard let inner = body["of"] else {
                throw CurriculumError.malformed("\(context): intersect_prior_hifz.of malformed")
            }
            return .intersectPriorHifz(of: try parseSelectorRef(inner, context: "\(context).intersect_prior_hifz.of"))
        default:
            throw CurriculumError.malformed("\(context): unknown selector kind '\(key)'")
        }
    }

    private static func parseSelectorRef(_ json: JSONValue, context: String) throws -> SelectorRef {
        if let name = json.stringValue { return .named(name) }
        return .inline(try parseSelector(json, context: context))
    }

    private static func parseRule(_ json: JSONValue) throws -> RuleSpec {
        guard let obj = json.objectValue, let id = obj["id"]?.stringValue else {
            throw CurriculumError.malformed("rule missing id")
        }
        guard let whenObj = obj["when"]?.objectValue,
              let session = whenObj["session"]?.stringValue
        else { throw CurriculumError.malformed("rule \(id): when malformed") }

        var dayClasses: [String] = []
        if let single = whenObj["day_class"]?.stringValue {
            dayClasses = [single]
        } else if let arr = whenObj["day_class"]?.arrayValue {
            dayClasses = arr.compactMap(\.stringValue)
            guard dayClasses.count == arr.count else { throw CurriculumError.malformed("rule \(id): bad day_class array") }
        } else {
            throw CurriculumError.malformed("rule \(id): day_class missing")
        }

        var enabledVar: String? = nil
        if let enabled = whenObj["enabled"]?.stringValue {
            guard enabled.hasPrefix("$") else { throw CurriculumError.malformed("rule \(id): enabled must be a $var ref (D-028)") }
            enabledVar = String(enabled.dropFirst())
        }

        let dayIn = whenObj["day_in"].flatMap { WeekdaySetOrVar(json: $0) }

        var notConditions: [NotCondition] = []
        for item in whenObj["not"]?.arrayValue ?? [] {
            if let s = item.stringValue {
                switch s {
                case "first_active_day": notConditions.append(.firstActiveDay)
                case "in_consolidation_week": notConditions.append(.inConsolidationWeek)
                default: throw CurriculumError.malformed("rule \(id): unknown not-condition '\(s)'")
                }
            } else if let flag = item["has_flag"]?.stringValue {
                notConditions.append(.hasFlag(flag))
            } else {
                throw CurriculumError.malformed("rule \(id): bad not-condition")
            }
        }

        guard let emitObj = obj["emit"]?.objectValue,
              let type = emitObj["type"]?.stringValue,
              let ordering = emitObj["ordering"]?.intValue
        else { throw CurriculumError.malformed("rule \(id): emit malformed") }

        var window: (Weekday, Weekday)? = nil
        if let windowObj = emitObj["window"]?.objectValue {
            guard let opensCode = windowObj["opens"]?.stringValue, let opens = Weekday(code: opensCode),
                  let closesCode = windowObj["closes"]?.stringValue, let closes = Weekday(code: closesCode)
            else { throw CurriculumError.malformed("rule \(id): window malformed") }
            window = (opens, closes)
        }

        let emit = RuleEmit(
            type: type,
            select: try emitObj["select"].map { try parseSelectorRef($0, context: "rule \(id).select") },
            repetitions: emitObj["repetitions"].flatMap { IntOrVar(json: $0) },
            spacingMinutes: emitObj["spacing_minutes"].flatMap { IntOrVar(json: $0) },
            listenCount: emitObj["listen_count"].flatMap { IntOrVar(json: $0) },
            window: window,
            infoOnly: emitObj["info_only"]?.boolValue ?? false,
            ordering: ordering,
            label: emitObj["label"]?.objectValue?.compactMapValues(\.stringValue),
            estMinutes: emitObj["est_minutes"]?.intValue)

        let explanation = obj["explanation"]?.objectValue?.compactMapValues(\.stringValue)

        return RuleSpec(
            id: id,
            when: RuleWhen(dayClasses: dayClasses, session: session, dayIn: dayIn,
                           enabledVar: enabledVar, notConditions: notConditions),
            emit: emit,
            explanation: explanation,
            suppressedBy: (obj["suppressed_by"]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    private static func parseTrigger(_ json: JSONValue) throws -> TriggerSpec {
        guard let obj = json.objectValue, let id = obj["id"]?.stringValue else {
            throw CurriculumError.malformed("trigger missing id")
        }
        let on: TriggerOn
        if let onObj = obj["on"]?.objectValue, let boundary = onObj["boundary"]?.stringValue {
            on = .boundary(kind: boundary, every: onObj["every"].flatMap { IntOrVar(json: $0) })
        } else if let reach = obj["on"]?["cursor_reaches"], let range = CanonicalRange(json: reach) {
            on = .cursorReaches(range)
        } else if let rule = obj["on"]?["task_failed"]?["rule"]?.stringValue {
            on = .taskFailed(rule: rule)
        } else {
            throw CurriculumError.malformed("trigger \(id): on malformed")
        }

        var effects: [TriggerEffect] = []
        for item in obj["effects"]?.arrayValue ?? [] {
            guard let effectObj = item.objectValue, effectObj.count == 1,
                  let key = effectObj.keys.first, let body = effectObj[key]
            else { throw CurriculumError.malformed("trigger \(id): effect malformed") }
            switch key {
            case "schedule":
                guard let type = body["type"]?.stringValue, let selectJSON = body["select"] else {
                    throw CurriculumError.malformed("trigger \(id): schedule malformed")
                }
                effects.append(.schedule(
                    type: type,
                    select: try parseSelectorRef(selectJSON, context: "trigger \(id).schedule.select"),
                    distributeOverDays: body["distribute_over_days"]?.intValue,
                    intoSession: body["into_session"]?.stringValue,
                    // D-028(5): `starting` defaults to next_active_day.
                    starting: body["starting"]?.stringValue ?? "next_active_day",
                    label: body["label"]?.objectValue?.compactMapValues(\.stringValue),
                    estMinutes: body["est_minutes"]?.intValue))
            case "insert_week":
                guard let name = body["name"]?.stringValue, let rulesJSON = body["day_rules"]?.arrayValue else {
                    throw CurriculumError.malformed("trigger \(id): insert_week malformed")
                }
                var dayRules: [RuleSpec] = []
                for r in rulesJSON { dayRules.append(try parseRule(r)) }
                effects.append(.insertWeek(name: name, modeVar: body["mode_var"]?.stringValue, dayRules: dayRules))
            case "set_flag":
                guard let name = body["name"]?.stringValue else {
                    throw CurriculumError.malformed("trigger \(id): set_flag malformed")
                }
                effects.append(.setFlag(name: name, until: body["until"]?.stringValue))
            case "clear_flag":
                guard let name = body["name"]?.stringValue else {
                    throw CurriculumError.malformed("trigger \(id): clear_flag malformed")
                }
                effects.append(.clearFlag(name: name))
            case "complete_plan":
                effects.append(.completePlan)
            default:
                throw CurriculumError.malformed("trigger \(id): unknown effect '\(key)'")
            }
        }
        return TriggerSpec(id: id, on: on, effects: effects)
    }

    // MARK: reference validation (PRD §8.4 stage 2, engine-side subset)

    private static func validateReferences(_ c: CompiledCurriculum) throws {
        // D-028(1): $pace is always defined; every other $var must resolve.
        func checkVar(_ name: String, kindHint: String, where context: String) throws {
            if name == "pace" { return }
            guard c.variables[name] != nil else {
                throw CurriculumError.invalidReference("\(context) references undeclared variable $\(name)")
            }
        }
        func checkIntOrVar(_ v: IntOrVar?, _ context: String) throws {
            if case .ref(let name)? = v { try checkVar(name, kindHint: "int", where: context) }
        }
        func checkAmountOrVar(_ v: AmountOrVar?, _ context: String) throws {
            if case .ref(let name)? = v { try checkVar(name, kindHint: "amount", where: context) }
        }
        func checkSelector(_ spec: SelectorSpec, _ context: String) throws {
            switch spec {
            case .nextContent(let amount), .nextNew(let amount):
                try checkAmountOrVar(amount, context)
            case .ledgerWindow(let days, let sundayDays):
                try checkIntOrVar(days, context)
                try checkIntOrVar(sundayDays, context)
            case .ledgerOffset(let daysAgo):
                try checkIntOrVar(daysAgo, context)
            case .poolRotation(let pool, let perDay, let weakBoost):
                switch pool {
                case .priorHifz: break
                case .recentPages(let n), .recentJuz(let n),
                     .allExceptRecentPages(let n), .allExceptRecentJuz(let n):
                    try checkIntOrVar(n, context)
                }
                switch perDay {
                case .ramp(let start, let step, let ceiling):
                    try checkAmountOrVar(start, context)
                    try checkAmountOrVar(step, context)
                    try checkAmountOrVar(ceiling, context)
                case .cycleDays(let n):
                    try checkIntOrVar(n, context)
                }
                try checkIntOrVar(weakBoost, context)
            case .block(let count):
                try checkIntOrVar(count, context)
            case .blockSlice(let of, _):
                guard c.selectors[of] != nil else {
                    throw CurriculumError.invalidReference("\(context): block_slice.of references unknown selector '\(of)'")
                }
            case .intersectPriorHifz(let ref):
                try checkSelectorRef(ref, "\(context).intersect_prior_hifz")
            case .weekToDate, .completedJuz, .priorHifzSplit, .tomorrowNew, .fixed:
                break
            }
        }
        func checkSelectorRef(_ ref: SelectorRef?, _ context: String) throws {
            switch ref {
            case .named(let name)?:
                guard let spec = c.selectors[name] else {
                    throw CurriculumError.invalidReference("\(context) references unknown selector '\(name)'")
                }
                try checkSelector(spec, "selector \(name)")
            case .inline(let spec)?:
                try checkSelector(spec, context)
            case nil:
                break
            }
        }
        func checkRule(_ rule: RuleSpec, triggerIds: Set<String>, isDayRule: Bool) throws {
            for dc in rule.when.dayClasses {
                guard c.dayClasses[dc] != nil || c.exceptionClasses.contains(dc) else {
                    throw CurriculumError.invalidReference("rule \(rule.id): unknown day_class '\(dc)'")
                }
            }
            guard c.sessionIds.contains(rule.when.session) else {
                throw CurriculumError.invalidReference("rule \(rule.id): unknown session '\(rule.when.session)'")
            }
            if let enabledVar = rule.when.enabledVar {
                try checkVar(enabledVar, kindHint: "bool", where: "rule \(rule.id).when.enabled")
            }
            if case .ref(let name)? = rule.when.dayIn {
                try checkVar(name, kindHint: "weekday_set", where: "rule \(rule.id).when.day_in")
            }
            try checkSelectorRef(rule.emit.select, "rule \(rule.id)")
            try checkIntOrVar(rule.emit.repetitions, "rule \(rule.id).repetitions")
            try checkIntOrVar(rule.emit.spacingMinutes, "rule \(rule.id).spacing_minutes")
            try checkIntOrVar(rule.emit.listenCount, "rule \(rule.id).listen_count")
            if !isDayRule {
                for trigger in rule.suppressedBy {
                    guard triggerIds.contains(trigger) else {
                        throw CurriculumError.invalidReference("rule \(rule.id): suppressed_by unknown trigger '\(trigger)'")
                    }
                }
            }
        }

        let triggerIds = Set(c.triggers.map(\.id))
        var ruleIds = Set<String>()
        for rule in c.rules {
            guard ruleIds.insert(rule.id).inserted else {
                throw CurriculumError.invalidReference("duplicate rule id '\(rule.id)'")
            }
            try checkRule(rule, triggerIds: triggerIds, isDayRule: false)
        }
        for name in c.selectors.keys.sorted() {
            try checkSelector(c.selectors[name]!, "selector \(name)")
        }
        for trigger in c.triggers {
            // E-5 (D-047): task_failed must name a real rule.
            if case .taskFailed(let ruleId) = trigger.on {
                guard c.rules.contains(where: { $0.id == ruleId }) else {
                    throw CurriculumError.invalidReference(
                        "trigger \(trigger.id): on.task_failed references unknown rule '\(ruleId)'")
                }
            }
            for effect in trigger.effects {
                switch effect {
                case .schedule(_, let select, _, let intoSession, let starting, _, _):
                    try checkSelectorRef(select, "trigger \(trigger.id)")
                    if let session = intoSession {
                        guard c.sessionIds.contains(session) else {
                            throw CurriculumError.invalidReference("trigger \(trigger.id): unknown session '\(session)'")
                        }
                    }
                    guard starting == "next_active_day" else {
                        throw CurriculumError.invalidReference("trigger \(trigger.id): unsupported starting '\(starting)'")
                    }
                case .insertWeek(_, let modeVar, let dayRules):
                    if let mv = modeVar {
                        try checkVar(mv, kindHint: "enum", where: "trigger \(trigger.id).mode_var")
                    }
                    for rule in dayRules {
                        try checkRule(rule, triggerIds: triggerIds, isDayRule: true)
                    }
                case .setFlag, .clearFlag, .completePlan:
                    break
                }
            }
            if case .boundary(_, let every) = trigger.on {
                try checkIntOrVar(every, "trigger \(trigger.id).on.every")
            }
        }
    }
}
