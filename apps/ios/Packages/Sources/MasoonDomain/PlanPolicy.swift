/// PlanPolicy per PRD §7.2 and the fixture input shape (ENGINE_PARITY §4.1).

public enum TargetRange: Hashable, Sendable {
    case fullQuran
    case ranges([CanonicalRange])
}

public enum MemorizationOrderKind: Hashable, Sendable {
    case mushafForward
    case juzAmmaBackward
    case customList([CanonicalRange])
}

public enum RecoveryPolicy: Hashable, Sendable {
    case strictBacklog
    case redistribute(days: Int, maxExtra: QuranAmount?)
    case pauseAndResume
}

public struct SessionSpec: Hashable, Sendable {
    public let id: String
    public let start: String  // "HH:mm" wall clock

    public init(id: String, start: String) {
        self.id = id
        self.start = start
    }
}

public struct RampSpec: Hashable, Sendable {
    public let start: QuranAmount
    public let step: QuranAmount

    public init(start: QuranAmount, step: QuranAmount) {
        self.start = start
        self.step = step
    }
}

public struct PlanPolicy: Sendable, Equatable {
    public var newAmount: QuranAmount
    public var targetRange: TargetRange
    public var memorizationOrder: MemorizationOrderKind
    public var activeWeekdays: Set<Weekday>
    public var sessions: [SessionSpec]
    public var separateSessionCompletion: Bool
    public var listeningDays: Set<Weekday>
    public var listeningCount: Int
    public var takrarCount: Int
    public var takrarSpacingMinutes: Int
    public var murajaahDailyCeiling: QuranAmount
    public var murajaahRamp: RampSpec?
    public var recoveryPolicy: RecoveryPolicy
    /// Curriculum variable overrides — the authoritative channel for tuning
    /// DSL `$variables` (D-028).
    public var variableOverrides: [String: JSONValue]
    public var cycleWeekMode: String?
    /// task_type -> EvidenceSpec JSON override (parsed lazily against curriculum vars).
    public var evidencePolicy: [String: JSONValue]

    /// ENGINE_SEMANTICS §11.21: which of the five non-optional policy fields in
    /// the closed policy-field -> DSL-variable map this value EXPLICITLY
    /// specified, as opposed to silently taking a struct default because the
    /// source JSON omitted the key.
    ///
    /// Without this distinction, a synthesized default could replace a
    /// curriculum's own default for an omitted field.
    ///
    /// `murajaahRamp` and `cycleWeekMode` need no entry: they are already
    /// Optional, so nil already means absent.
    public var explicitPolicyFields: Set<String> = []

    /// The five §11.21 keys, in the spelling `explicitPolicyFields` and every
    /// patch builder use. Exposed so a candidate builder can ask "is this a
    /// gated field?" without re-listing them and drifting.
    public static let gatedPolicyFieldKeys: Set<String> = [
        "takrar_count", "takrar_spacing_minutes", "listening_days",
        "listening_count", "murajaah_daily_ceiling",
    ]

    // MARK: - Explicit-marking setters (§11.21)
    //
    // A UI that builds a candidate policy by assigning the struct field
    // directly (`candidate.murajaahDailyCeiling = …`) sets the VALUE but not
    // the PRESENCE, and presence is what `VariableResolver.namedPolicyField`
    // gates the DSL binding on. The result was a preview that silently
    // discarded the learner's edit: the candidate carried the new ceiling in
    // a struct field the engine had been told to ignore.
    //
    // These setters are the supported way to express "the learner chose
    // this". They mirror exactly what `applying(patch:)` does when the same
    // field arrives in a real `plan.policy_changed` patch, so a previewed
    // candidate and the committed event resolve through identical rules —
    // which is the whole correctness requirement for a preview.

    public mutating func setTakrarCount(_ value: Int) {
        takrarCount = value
        explicitPolicyFields.insert("takrar_count")
    }

    public mutating func setTakrarSpacingMinutes(_ value: Int) {
        takrarSpacingMinutes = value
        explicitPolicyFields.insert("takrar_spacing_minutes")
    }

    public mutating func setListeningDays(_ value: Set<Weekday>) {
        listeningDays = value
        explicitPolicyFields.insert("listening_days")
    }

    public mutating func setListeningCount(_ value: Int) {
        listeningCount = value
        explicitPolicyFields.insert("listening_count")
    }

    public mutating func setMurajaahDailyCeiling(_ value: QuranAmount) {
        murajaahDailyCeiling = value
        explicitPolicyFields.insert("murajaah_daily_ceiling")
    }

    public enum ParseError: Error, CustomStringConvertible {
        case malformed(String)
        public var description: String {
            if case .malformed(let m) = self { return "policy error: \(m)" }
            return "policy error"
        }
    }

    public init(json: JSONValue) throws {
        guard let obj = json.objectValue else { throw ParseError.malformed("policy is not an object") }

        guard let amountJSON = obj["new_amount"], let amount = QuranAmount(json: amountJSON) else {
            throw ParseError.malformed("new_amount missing or malformed")
        }
        self.newAmount = amount

        if let targetStr = obj["target_range"]?.stringValue {
            guard targetStr == "full_quran" else { throw ParseError.malformed("unknown target_range '\(targetStr)'") }
            self.targetRange = .fullQuran
        } else if let arr = obj["target_range"]?.arrayValue {
            var ranges: [CanonicalRange] = []
            for item in arr {
                guard let r = CanonicalRange(json: item) else { throw ParseError.malformed("bad target range") }
                ranges.append(r)
            }
            self.targetRange = .ranges(ranges)
        } else {
            self.targetRange = .fullQuran
        }

        if let orderObj = obj["memorization_order"]?.objectValue, let kind = orderObj["kind"]?.stringValue {
            switch kind {
            case "mushaf_forward":
                self.memorizationOrder = .mushafForward
            case "juz_amma_backward":
                self.memorizationOrder = .juzAmmaBackward
            case "custom_list":
                var list: [CanonicalRange] = []
                for item in orderObj["list"]?.arrayValue ?? [] {
                    guard let r = CanonicalRange(json: item) else { throw ParseError.malformed("bad custom_list range") }
                    list.append(r)
                }
                guard !list.isEmpty else { throw ParseError.malformed("custom_list must not be empty") }
                self.memorizationOrder = .customList(list)
            default:
                throw ParseError.malformed("unknown memorization_order kind '\(kind)'")
            }
        } else {
            self.memorizationOrder = .mushafForward
        }

        func weekdaySet(_ key: String, default def: Set<Weekday>) throws -> Set<Weekday> {
            guard let arr = obj[key]?.arrayValue else { return def }
            var out: Set<Weekday> = []
            for item in arr {
                guard let code = item.stringValue, let wd = Weekday(code: code) else {
                    throw ParseError.malformed("bad weekday in \(key)")
                }
                out.insert(wd)
            }
            return out
        }
        self.activeWeekdays = try weekdaySet("active_weekdays", default: [.sun, .mon, .tue, .wed, .thu])
        self.listeningDays = try weekdaySet("listening_days", default: [.sat, .sun, .mon, .tue, .wed])

        var sessions: [SessionSpec] = []
        for item in obj["sessions"]?.arrayValue ?? [] {
            guard let id = item["id"]?.stringValue else { throw ParseError.malformed("session missing id") }
            sessions.append(SessionSpec(id: id, start: item["start"]?.stringValue ?? ""))
        }
        self.sessions = sessions

        self.separateSessionCompletion = obj["separate_session_completion"]?.boolValue ?? true
        self.listeningCount = obj["listening_count"]?.intValue ?? 2
        self.takrarCount = obj["takrar_count"]?.intValue ?? 5
        self.takrarSpacingMinutes = obj["takrar_spacing_minutes"]?.intValue ?? 15

        if let ceilingJSON = obj["murajaah_daily_ceiling"], let ceiling = QuranAmount(json: ceilingJSON) {
            self.murajaahDailyCeiling = ceiling
        } else {
            self.murajaahDailyCeiling = QuranAmount(unit: .juz, value: DecimalValue(integer: 2))
        }

        if let rampObj = obj["murajaah_ramp"]?.objectValue,
           let startJSON = rampObj["start"], let start = QuranAmount(json: startJSON),
           let stepJSON = rampObj["step"], let step = QuranAmount(json: stepJSON) {
            self.murajaahRamp = RampSpec(start: start, step: step)
        } else {
            self.murajaahRamp = nil
        }

        if let recoveryObj = obj["recovery_policy"]?.objectValue, let kind = recoveryObj["kind"]?.stringValue {
            switch kind {
            case "strict_backlog":
                self.recoveryPolicy = .strictBacklog
            case "redistribute":
                let days = recoveryObj["days"]?.intValue ?? 3
                let maxExtra = recoveryObj["max_extra"].flatMap { QuranAmount(json: $0) }
                self.recoveryPolicy = .redistribute(days: days, maxExtra: maxExtra)
            case "pause_and_resume":
                self.recoveryPolicy = .pauseAndResume
            default:
                throw ParseError.malformed("unknown recovery_policy kind '\(kind)'")
            }
        } else {
            self.recoveryPolicy = .strictBacklog
        }

        self.variableOverrides = obj["variable_overrides"]?.objectValue ?? [:]
        self.cycleWeekMode = obj["cycle_week_mode"]?.stringValue
        self.evidencePolicy = obj["evidence_policy"]?.objectValue ?? [:]
        // §11.21 — record which of the five defaulted fields the caller
        // actually supplied. See `explicitPolicyFields`.
        var explicit: Set<String> = []
        for key in PlanPolicy.gatedPolicyFieldKeys where obj[key] != nil {
            explicit.insert(key)
        }
        self.explicitPolicyFields = explicit
    }

    /// Applies a policy patch (`plan.policy_changed` / `override.applied`):
    /// fields present in the patch replace the corresponding policy fields.
    public func applying(patch: JSONValue) -> PlanPolicy {
        guard let patchObj = patch.objectValue else { return self }
        var copy = self
        if let amountJSON = patchObj["new_amount"], let amount = QuranAmount(json: amountJSON) {
            copy.newAmount = amount
        }
        if let arr = patchObj["active_weekdays"]?.arrayValue {
            let parsed = arr.compactMap { $0.stringValue.flatMap(Weekday.init(code:)) }
            if parsed.count == arr.count { copy.activeWeekdays = Set(parsed) }
        }
        if let arr = patchObj["listening_days"]?.arrayValue {
            let parsed = arr.compactMap { $0.stringValue.flatMap(Weekday.init(code:)) }
            if parsed.count == arr.count {
                copy.listeningDays = Set(parsed)
                copy.explicitPolicyFields.insert("listening_days")
            }
        }
        if let v = patchObj["listening_count"]?.intValue {
            copy.listeningCount = v
            copy.explicitPolicyFields.insert("listening_count")
        }
        if let v = patchObj["takrar_count"]?.intValue {
            copy.takrarCount = v
            copy.explicitPolicyFields.insert("takrar_count")
        }
        if let v = patchObj["takrar_spacing_minutes"]?.intValue {
            copy.takrarSpacingMinutes = v
            copy.explicitPolicyFields.insert("takrar_spacing_minutes")
        }
        if let ceilingJSON = patchObj["murajaah_daily_ceiling"], let ceiling = QuranAmount(json: ceilingJSON) {
            copy.murajaahDailyCeiling = ceiling
            copy.explicitPolicyFields.insert("murajaah_daily_ceiling")
        }
        // PC-6(b): `murajaah_ramp: null` is an explicit "clear the override,
        // fall back to the curriculum DSL default ramp" signal — this field
        // holds ONE ramp value (not a dict of per-name overrides), so "clear"
        // means reset it to `nil` (absent ⇒ still "don't touch", matching
        // every other key's house style; only a present JSON `null` clears).
        if let node = patchObj["murajaah_ramp"] {
            if node.isNull {
                copy.murajaahRamp = nil
            } else if let rampObj = node.objectValue,
                      let startJSON = rampObj["start"], let start = QuranAmount(json: startJSON),
                      let stepJSON = rampObj["step"], let step = QuranAmount(json: stepJSON) {
                copy.murajaahRamp = RampSpec(start: start, step: step)
            }
        }
        if let recoveryObj = patchObj["recovery_policy"]?.objectValue, let kind = recoveryObj["kind"]?.stringValue {
            switch kind {
            case "strict_backlog": copy.recoveryPolicy = .strictBacklog
            case "redistribute":
                copy.recoveryPolicy = .redistribute(
                    days: recoveryObj["days"]?.intValue ?? 3,
                    maxExtra: recoveryObj["max_extra"].flatMap { QuranAmount(json: $0) })
            case "pause_and_resume": copy.recoveryPolicy = .pauseAndResume
            default: break
            }
        }
        // PC-6(b): `variable_overrides: null` clears EVERY existing override
        // back to the curriculum's own DSL defaults (a per-name dict — "clear"
        // means empty the whole dict, not merge-in-nothing, which the pre-
        // existing `{}` behavior already accomplished and remains ambiguous
        // with "no change"). A present object still field-wise merges,
        // unchanged.
        if let node = patchObj["variable_overrides"] {
            if node.isNull {
                copy.variableOverrides = [:]
            } else if let overrides = node.objectValue {
                for (k, v) in overrides { copy.variableOverrides[k] = v }
            }
        }
        if let mode = patchObj["cycle_week_mode"]?.stringValue { copy.cycleWeekMode = mode }
        // PC-6(b): same null-clears-the-whole-dict semantic as
        // `variable_overrides` above (evidence_policy is likewise a per-
        // task-type dict of overrides, not a single value).
        if let node = patchObj["evidence_policy"] {
            if node.isNull {
                copy.evidencePolicy = [:]
            } else if let evidence = node.objectValue {
                for (k, v) in evidence { copy.evidencePolicy[k] = v }
            }
        }
        // PC-6(a): `sessions` was declared on `PlanPolicy` already but never
        // wired into `applying(patch:)` — a `sessions` key in a patch was
        // silently dropped. Wire it up the same way every other array-typed
        // key here works: a present, fully-parseable array replaces the
        // field wholesale; anything else (missing key, malformed entry)
        // leaves `copy.sessions` untouched.
        if let arr = patchObj["sessions"]?.arrayValue {
            var sessions: [SessionSpec] = []
            var ok = true
            for item in arr {
                guard let id = item["id"]?.stringValue else { ok = false; break }
                sessions.append(SessionSpec(id: id, start: item["start"]?.stringValue ?? ""))
            }
            if ok { copy.sessions = sessions }
        }
        // PC-6(a): same gap as `sessions` — declared on the struct, never
        // patchable.
        if let v = patchObj["separate_session_completion"]?.boolValue {
            copy.separateSessionCompletion = v
        }
        return copy
    }
}
