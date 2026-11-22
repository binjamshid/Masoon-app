import MasoonDomain

/// CB-9: `CurriculumDraft`'s JSON round trip — `init(fromDocument:)` (parse)
/// and `toDocument()` (serialize) — plus the small serialization helpers the
/// reused `CompiledCurriculum` leaf types (`IntOrVar`, `AmountOrVar`,
/// `WeekdaySetOrVar`, `QuranAmount`, `CanonicalRange`, `NotCondition`) need
/// to go back to `JSONValue`. `CompiledCurriculum.swift` itself is never
/// modified — every addition here is either a new type (`CurriculumDraft.
/// swift`) or a new `extension` on an existing public type, both purely
/// additive and therefore inert against the master byte-identical-fixtures
/// rule for this stage.
///
/// ## Why numbers are handled the way they are
///
/// `DecimalValue.description` produces a fraction for non-integers,
/// which is invalid as a JSON numeric token. The decimal serializer below
/// reconstructs the original digit count from the power-of-ten denominator.
///
/// `forecast.workload_rates`/`strength_factors` and `evidence_defaults`
/// deliberately do NOT go through `DecimalValue`/`QuranAmount` at all: they
/// stay raw `JSONValue`, exactly mirroring `CompiledCurriculum
/// .evidenceDefaults`'s existing precedent. `strength_factors` in particular
/// is schema-`number` (not `integer`) and EVERY one of the 15 built-ins
/// authors non-integer values (`{"weak":1.5,"moderate":1.2,"strong":1}`) —
/// raw pass-through is the simplest representation that cannot mis-format
/// them, needed or not.
///
/// Uses sorted object keys, preserves numeric tokens and applies JSON
/// string escaping to produce deterministic output.
enum CurriculumDraftJSONText {
    static func serialize(_ value: JSONValue) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    private static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .number(let raw):
            out += raw
        case .string(let s):
            writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let dict):
            out += "{"
            for (i, key) in dict.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                writeString(key, into: &out)
                out += ":"
                write(dict[key]!, into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let digits = "0123456789abcdef"
                    var hex = ""
                    for shift in [12, 8, 4, 0] {
                        let nibble = Int((scalar.value >> UInt32(shift)) & 0xF)
                        hex.append(digits[digits.index(digits.startIndex, offsetBy: nibble)])
                    }
                    out += "\\u\(hex)"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

// MARK: - DecimalValue / leaf-type serialization

extension DecimalValue {
    /// Exact JSON number token: `units / denominator`, where `denominator`
    /// is always a power of ten (see this file's header). Unlike
    /// `description` (an exact-arithmetic debug form, `"units/denominator"`
    /// for non-integers), this always produces valid, original-digit-count-
    /// preserving JSON number text.
    var jsonNumberToken: String {
        guard denominator != 1 else { return String(units) }
        var pow10: Int64 = 1
        var remaining = denominator
        var digits = 0
        while remaining > 1 {
            remaining /= 10
            pow10 *= 10
            digits += 1
        }
        let whole = units / pow10
        let frac = units % pow10
        let fracDigits = String(frac)
        let padded = String(repeating: "0", count: max(0, digits - fracDigits.count)) + fracDigits
        return "\(whole).\(padded)"
    }
}

extension QuranAmount {
    func toJSONValue() -> JSONValue {
        .object(["unit": .string(unit.rawValue), "value": .number(value.jsonNumberToken)])
    }
}

extension CanonicalRange {
    /// `riwayah` is not round-tripped (mirrors `CompiledCurriculum`'s own
    /// `CanonicalRange.init?(json:)`, which never reads it either); none of
    /// the 15 built-ins ever author it (verified).
    func toJSONValue() -> JSONValue {
        .object([
            "surah": .number(String(surah)),
            "ayah_start": .number(String(ayahStart)),
            "ayah_end": .number(String(ayahEnd)),
        ])
    }
}

extension IntOrVar {
    func toJSON() -> JSONValue {
        switch self {
        case .value(let v): return .number(String(v))
        case .ref(let name): return .string("$\(name)")
        }
    }
}

extension AmountOrVar {
    func toJSON() -> JSONValue {
        switch self {
        case .value(let amount): return amount.toJSONValue()
        case .ref(let name): return .string("$\(name)")
        }
    }
}

extension WeekdaySetOrVar {
    /// `.value` is unreachable for any schema-valid document: the schema's
    /// only reference site for this shape, `RuleWhen.day_in`, types the
    /// field as `VarRef` ONLY (`curriculum-v1.schema.json`), never a literal
    /// weekday array — gate 1 rejects a literal array there before this
    /// code would ever see it. Handled anyway (sorted ascending) so the
    /// type stays total.
    func toJSON() -> JSONValue {
        switch self {
        case .value(let set): return .array(set.sorted().map { .string($0.code) })
        case .ref(let name): return .string("$\(name)")
        }
    }
}

extension NotCondition {
    func toJSON() -> JSONValue {
        switch self {
        case .firstActiveDay: return .string("first_active_day")
        case .inConsolidationWeek: return .string("in_consolidation_week")
        case .hasFlag(let name): return .object(["has_flag": .string(name)])
        }
    }
}

// MARK: - Document round trip

extension CurriculumDraft {
    /// Parses a `curriculum-v1` JSON document into an editable draft.
    /// Structural (shape) checks only — throws `CurriculumError.malformed`
    /// when a required key/shape is missing, but does NOT re-implement
    /// schema value-format validation (regex patterns, enum membership,
    /// numeric ranges) or gate-2 reference validation: those remain
    /// `JSONSchemaValidator`'s (CB-3) and `CurriculumLoader`'s jobs,
    /// reachable together via `CurriculumValidator.validate` (CB-5) once a
    /// caller has a `CurriculumDraft` and calls `.toDocument()` on it.
    public init(fromDocument json: JSONValue) throws {
        guard let root = json.objectValue else { throw CurriculumError.malformed("root is not an object") }

        guard let metaJSON = root["meta"] else { throw CurriculumError.malformed("meta missing") }
        let meta = try CurriculumDraftCoding.parseMeta(metaJSON)

        guard let unitsJSON = root["units"] else { throw CurriculumError.malformed("units missing") }
        let units = try CurriculumDraftCoding.parseUnits(unitsJSON)

        guard let calendarJSON = root["calendar"] else { throw CurriculumError.malformed("calendar missing") }
        let calendar = try CurriculumDraftCoding.parseCalendar(calendarJSON)

        guard let sessionsArr = root["sessions"]?.arrayValue, !sessionsArr.isEmpty else {
            throw CurriculumError.malformed("sessions missing")
        }
        let sessions = try sessionsArr.map { try CurriculumDraftCoding.parseSession($0) }

        var variables: [String: VariableDraft] = [:]
        for (name, defJSON) in root["variables"]?.objectValue ?? [:] {
            variables[name] = try CurriculumDraftCoding.parseVariable(name: name, json: defJSON)
        }

        var selectors: [String: SelectorSpec] = [:]
        for (name, specJSON) in root["selectors"]?.objectValue ?? [:] {
            selectors[name] = try CurriculumDraftCoding.parseSelectorSpec(specJSON, context: "selectors.\(name)")
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

        guard let rulesArr = root["rules"]?.arrayValue, !rulesArr.isEmpty else {
            throw CurriculumError.malformed("rules must not be empty")
        }
        let rules = try rulesArr.map { try CurriculumDraftCoding.parseRule($0) }

        let triggers = try (root["triggers"]?.arrayValue ?? []).map { try CurriculumDraftCoding.parseTrigger($0) }

        let recovery = try root["recovery"].map { try CurriculumDraftCoding.parseRecovery($0) }
        let advancement = try root["advancement"].map { try CurriculumDraftCoding.parseAdvancement($0) }
        let evidenceDefaults = root["evidence_defaults"]?.objectValue

        guard let forecastJSON = root["forecast"] else { throw CurriculumError.malformed("forecast missing") }
        let forecast = try CurriculumDraftCoding.parseForecast(forecastJSON)

        self.init(
            meta: meta, units: units, calendar: calendar, sessions: sessions, variables: variables,
            selectors: selectors, taskDeduplication: taskDeduplication,
            rules: rules, triggers: triggers, recovery: recovery, advancement: advancement,
            evidenceDefaults: evidenceDefaults, forecast: forecast)
    }

    /// Serializes back to a `curriculum-v1` JSON document. Never fills in a
    /// schema default for an absent optional field — every `Optional` field
    /// in this model omits its JSON key entirely when `nil` (see each
    /// field's doc comment in `CurriculumDraft.swift`), which is the
    /// property the round-trip proof depends on. Object key insertion order
    /// below is irrelevant: `JSONValue.object` is dictionary-backed, so
    /// downstream structural/canonical comparisons never see it.
    public func toDocument() -> JSONValue {
        var obj: [String: JSONValue] = [
            "meta": CurriculumDraftCoding.metaToJSON(meta),
            "units": CurriculumDraftCoding.unitsToJSON(units),
            "calendar": CurriculumDraftCoding.calendarToJSON(calendar),
            "sessions": .array(sessions.map { CurriculumDraftCoding.sessionToJSON($0) }),
            "variables": .object(
                variables.reduce(into: [:]) { $0[$1.key] = CurriculumDraftCoding.variableToJSON($1.value) }),
            "selectors": .object(
                selectors.reduce(into: [:]) { $0[$1.key] = CurriculumDraftCoding.selectorSpecToJSON($1.value) }),
            "rules": .array(rules.map { CurriculumDraftCoding.ruleToJSON($0) }),
            "triggers": .array(triggers.map { CurriculumDraftCoding.triggerToJSON($0) }),
            "forecast": CurriculumDraftCoding.forecastToJSON(forecast),
        ]
        if let recovery { obj["recovery"] = CurriculumDraftCoding.recoveryToJSON(recovery) }
        if let taskDeduplication {
            obj["task_deduplication"] = .object(["mode": .string(taskDeduplication.rawValue)])
        }
        if let advancement { obj["advancement"] = CurriculumDraftCoding.advancementToJSON(advancement) }
        if let evidenceDefaults { obj["evidence_defaults"] = .object(evidenceDefaults) }
        return .object(obj)
    }

    /// Deterministic canonical text for `toDocument()`'s output — see this
    /// file's header for why this isn't `MasoonData.JSONText` itself. Useful
    /// standalone too: a future publish flow needing canonical text to
    /// hash or diff of compiled curriculum definitions can use
    /// this directly instead of re-deriving it.
    public func canonicalJSONText() -> String {
        CurriculumDraftJSONText.serialize(toDocument())
    }
}

// MARK: - Parsing/serialization plumbing

/// Module-internal (not file-private — see `SelectorSpec+JSON.swift`'s doc
/// comment for the one cross-file, same-module reuse: CB-11's builder needs
/// `parseSelectorSpec`/`selectorSpecToJSON` at single-selector granularity)
/// coding namespace: every JSONValue <-> Draft-type conversion that isn't a
/// single-line leaf mapping lives here, so `CurriculumDraft`'s own
/// `init(fromDocument:)`/`toDocument()` stay a short, readable top-level
/// assembly of these pieces (mirrors the shape of `CompiledCurriculum
/// .CurriculumLoader`'s own private parsing helpers, which this
/// deliberately cannot call — see `CurriculumDraft.swift`'s header). Still
/// invisible outside this MODULE (no `public`) — `SelectorSpec+JSON.swift`'s
/// two-function `public extension` remains the only externally reachable
/// surface.
enum CurriculumDraftCoding {

    // MARK: value-or-var requireds (fail loud, unlike a bare `.flatMap` that
    // would silently collapse a present-but-unparseable value to `nil` —
    // deliberately stricter than `CurriculumLoader`'s own equivalents, since
    // an authoring/round-trip tool losing data silently is worse than one
    // that throws).

    static func requireIntOrVar(_ json: JSONValue, _ context: String) throws -> IntOrVar {
        guard let v = IntOrVar(json: json) else {
            throw CurriculumError.malformed("\(context): expected an integer or a $var reference")
        }
        return v
    }

    static func requireAmountOrVar(_ json: JSONValue, _ context: String) throws -> AmountOrVar {
        guard let v = AmountOrVar(json: json) else {
            throw CurriculumError.malformed("\(context): expected a Quran amount or a $var reference")
        }
        return v
    }

    static func requireWeekdaySetOrVar(_ json: JSONValue, _ context: String) throws -> WeekdaySetOrVar {
        guard let v = WeekdaySetOrVar(json: json) else {
            throw CurriculumError.malformed("\(context): expected a weekday set or a $var reference")
        }
        return v
    }

    // MARK: Meta

    static func parseMeta(_ json: JSONValue) throws -> MetaDraft {
        guard let obj = json.objectValue, let slug = obj["slug"]?.stringValue else {
            throw CurriculumError.malformed("meta.slug missing")
        }
        guard let titleObj = obj["title"]?.objectValue, titleObj["ar"]?.stringValue != nil else {
            throw CurriculumError.malformed("meta.title.ar missing")
        }
        guard let nonNegotiablesArr = obj["non_negotiables"]?.arrayValue else {
            throw CurriculumError.malformed("meta.non_negotiables missing")
        }
        return MetaDraft(
            slug: slug,
            title: titleObj.compactMapValues(\.stringValue),
            description: obj["description"]?.objectValue?.compactMapValues(\.stringValue),
            pedagogyNotes: obj["pedagogy_notes"]?.objectValue?.compactMapValues(\.stringValue),
            nonNegotiables: nonNegotiablesArr.compactMap(\.stringValue),
            origin: obj["origin"]?.stringValue,
            licenseNote: obj["license_note"]?.stringValue,
            version: obj["version"]?.stringValue,
            corpora: obj["corpora"]?.arrayValue?.compactMap(\.stringValue))
    }

    static func metaToJSON(_ meta: MetaDraft) -> JSONValue {
        var obj: [String: JSONValue] = [
            "slug": .string(meta.slug),
            "title": .object(meta.title.mapValues { .string($0) }),
            "non_negotiables": .array(meta.nonNegotiables.map { .string($0) }),
        ]
        if let d = meta.description { obj["description"] = .object(d.mapValues { .string($0) }) }
        if let p = meta.pedagogyNotes { obj["pedagogy_notes"] = .object(p.mapValues { .string($0) }) }
        if let o = meta.origin { obj["origin"] = .string(o) }
        if let l = meta.licenseNote { obj["license_note"] = .string(l) }
        if let v = meta.version { obj["version"] = .string(v) }
        if let c = meta.corpora { obj["corpora"] = .array(c.map { .string($0) }) }
        return .object(obj)
    }

    // MARK: Units

    static func parseUnits(_ json: JSONValue) throws -> UnitsDraft {
        guard let obj = json.objectValue, let allowedArr = obj["allowed"]?.arrayValue else {
            throw CurriculumError.malformed("units.allowed missing")
        }
        var allowed: [QuranUnit] = []
        for item in allowedArr {
            guard let s = item.stringValue, let unit = QuranUnit(rawValue: s) else {
                throw CurriculumError.malformed("units.allowed: bad unit")
            }
            allowed.append(unit)
        }
        guard let paceJSON = obj["default_pace"], let pace = QuranAmount(json: paceJSON) else {
            throw CurriculumError.malformed("units.default_pace missing or malformed")
        }
        return UnitsDraft(allowed: allowed, defaultPace: pace)
    }

    static func unitsToJSON(_ units: UnitsDraft) -> JSONValue {
        .object([
            "allowed": .array(units.allowed.map { .string($0.rawValue) }),
            "default_pace": units.defaultPace.toJSONValue(),
        ])
    }

    // MARK: Calendar

    static func parseCalendar(_ json: JSONValue) throws -> CalendarDraft {
        guard let obj = json.objectValue,
              let weekStartCode = obj["week_start"]?.stringValue, let weekStart = Weekday(code: weekStartCode),
              let dayClassesObj = obj["day_classes"]?.objectValue
        else { throw CurriculumError.malformed("calendar missing or malformed") }
        var dayClasses: [String: [Weekday]] = [:]
        for (name, value) in dayClassesObj {
            guard let arr = value.arrayValue else {
                throw CurriculumError.malformed("calendar.day_classes.\(name) not an array")
            }
            var days: [Weekday] = []
            for item in arr {
                guard let code = item.stringValue, let wd = Weekday(code: code) else {
                    throw CurriculumError.malformed("calendar.day_classes.\(name): bad weekday")
                }
                days.append(wd)
            }
            dayClasses[name] = days
        }
        let exceptionClasses = (obj["exception_classes"]?.arrayValue ?? []).compactMap(\.stringValue)
        return CalendarDraft(weekStart: weekStart, dayClasses: dayClasses, exceptionClasses: exceptionClasses)
    }

    static func calendarToJSON(_ cal: CalendarDraft) -> JSONValue {
        var dayClassesObj: [String: JSONValue] = [:]
        for (name, days) in cal.dayClasses {
            dayClassesObj[name] = .array(days.map { .string($0.code) })
        }
        return .object([
            "week_start": .string(cal.weekStart.code),
            "day_classes": .object(dayClassesObj),
            "exception_classes": .array(cal.exceptionClasses.map { .string($0) }),
        ])
    }

    // MARK: Sessions

    static func parseSessionAnchor(_ json: JSONValue, sessionId: String) throws -> SessionAnchorDraft {
        if json.stringValue == "fixed" { return .fixed }
        if let obj = json.objectValue, let pr = obj["prayer_relative"]?.objectValue,
           let prayer = pr["prayer"]?.stringValue, let offset = pr["offset_min"]?.intValue {
            return .prayerRelative(prayer: prayer, offsetMinutes: offset)
        }
        throw CurriculumError.malformed("session \(sessionId): anchor malformed")
    }

    static func sessionAnchorToJSON(_ anchor: SessionAnchorDraft) -> JSONValue {
        switch anchor {
        case .fixed: return .string("fixed")
        case .prayerRelative(let prayer, let offset):
            return .object(["prayer_relative": .object(["prayer": .string(prayer), "offset_min": .number(String(offset))])])
        }
    }

    static func parseSession(_ json: JSONValue) throws -> SessionDraft {
        guard let obj = json.objectValue, let id = obj["id"]?.stringValue else {
            throw CurriculumError.malformed("session missing id")
        }
        guard let titleObj = obj["title"]?.objectValue else {
            throw CurriculumError.malformed("session \(id): title missing")
        }
        guard let defaultTime = obj["default_time"]?.stringValue else {
            throw CurriculumError.malformed("session \(id): default_time missing")
        }
        guard let anchorJSON = obj["anchor"] else {
            throw CurriculumError.malformed("session \(id): anchor missing")
        }
        return SessionDraft(
            id: id, title: titleObj.compactMapValues(\.stringValue), defaultTime: defaultTime,
            anchor: try parseSessionAnchor(anchorJSON, sessionId: id))
    }

    static func sessionToJSON(_ session: SessionDraft) -> JSONValue {
        .object([
            "id": .string(session.id),
            "title": .object(session.title.mapValues { .string($0) }),
            "default_time": .string(session.defaultTime),
            "anchor": sessionAnchorToJSON(session.anchor),
        ])
    }

    // MARK: Variables

    static func parseVariable(name: String, json: JSONValue) throws -> VariableDraft {
        guard let obj = json.objectValue,
              let kindStr = obj["type"]?.stringValue,
              let kind = VariableDef.Kind(rawValue: kindStr),
              let defaultValue = obj["default"]
        else { throw CurriculumError.malformed("variable \(name) malformed") }
        return VariableDraft(
            kind: kind,
            defaultValue: defaultValue,
            minimum: obj["min"]?.intValue,
            maximum: obj["max"]?.intValue,
            enumValues: (obj["values"]?.arrayValue ?? []).compactMap(\.stringValue),
            nonNegotiable: obj["non_negotiable"]?.boolValue,
            locked: obj["locked"]?.boolValue)
    }

    static func variableToJSON(_ v: VariableDraft) -> JSONValue {
        var obj: [String: JSONValue] = [
            "type": .string(v.kind.rawValue),
            "default": v.defaultValue,
        ]
        if let min = v.minimum { obj["min"] = .number(String(min)) }
        if let max = v.maximum { obj["max"] = .number(String(max)) }
        if !v.enumValues.isEmpty { obj["values"] = .array(v.enumValues.map { .string($0) }) }
        if let nn = v.nonNegotiable { obj["non_negotiable"] = .bool(nn) }
        if let l = v.locked { obj["locked"] = .bool(l) }
        return .object(obj)
    }

    // MARK: Selectors (mirrors `CurriculumLoader.parseSelector`, which is
    // `private` to that type and therefore not callable from here)

    static func parseSelectorSpec(_ json: JSONValue, context: String) throws -> SelectorSpec {
        guard let obj = json.objectValue, obj.count == 1, let key = obj.keys.first, let body = obj[key] else {
            throw CurriculumError.malformed("\(context): selector must have exactly one kind")
        }
        switch key {
        case "next_content":
            guard let amountJSON = body["amount"] else {
                throw CurriculumError.malformed("\(context): next_content.amount missing")
            }
            return .nextContent(amount: try requireAmountOrVar(amountJSON, "\(context).next_content.amount"))
        case "next_new":
            guard let amountJSON = body["amount"] else {
                throw CurriculumError.malformed("\(context): next_new.amount missing")
            }
            return .nextNew(amount: try requireAmountOrVar(amountJSON, "\(context).next_new.amount"))
        case "ledger_window":
            guard let daysJSON = body["days"] else {
                throw CurriculumError.malformed("\(context): ledger_window.days missing")
            }
            let days = try requireIntOrVar(daysJSON, "\(context).ledger_window.days")
            let sunday = try body["sunday_days"].map { try requireIntOrVar($0, "\(context).ledger_window.sunday_days") }
            return .ledgerWindow(days: days, sundayDays: sunday)
        case "ledger_offset":
            guard let daysAgoJSON = body["days_ago"] else {
                throw CurriculumError.malformed("\(context): ledger_offset.days_ago missing")
            }
            return .ledgerOffset(daysAgo: try requireIntOrVar(daysAgoJSON, "\(context).ledger_offset.days_ago"))
        case "week_to_date":
            return .weekToDate
        case "pool_rotation":
            guard let poolJSON = body["pool"] else {
                throw CurriculumError.malformed("\(context): pool_rotation.pool missing")
            }
            let pool = try parsePoolWindow(poolJSON, context: context)
            guard let perDayJSON = body["per_day"] else {
                throw CurriculumError.malformed("\(context): pool_rotation.per_day missing")
            }
            let perDay = try parsePerDaySpec(perDayJSON, context: context)
            let weakBoost = try body["weak_boost"].map { try requireIntOrVar($0, "\(context).pool_rotation.weak_boost") }
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
            guard let countJSON = body["juz_count"], body["which"]?.stringValue == "last" else {
                throw CurriculumError.malformed("\(context): block malformed")
            }
            return .block(juzCount: try requireIntOrVar(countJSON, "\(context).block.juz_count"))
        case "tomorrow_new":
            return .tomorrowNew
        case "fixed":
            guard let rangeArr = body["range"]?.arrayValue, !rangeArr.isEmpty else {
                throw CurriculumError.malformed("\(context): fixed.range malformed")
            }
            let ranges = try rangeArr.map { el -> CanonicalRange in
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
                throw CurriculumError.malformed("\(context): intersect_prior_hifz.of missing")
            }
            return .intersectPriorHifz(of: try parseSelectorRef(inner, context: "\(context).intersect_prior_hifz.of"))
        default:
            throw CurriculumError.malformed("\(context): unknown selector kind '\(key)'")
        }
    }

    static func parsePoolWindow(_ json: JSONValue, context: String) throws -> PoolWindow {
        if json.stringValue == "prior_hifz" { return .priorHifz }
        guard let obj = json.objectValue else { throw CurriculumError.malformed("\(context): pool malformed") }
        if let v = obj["recent_pages"] { return .recentPages(try requireIntOrVar(v, "\(context).pool.recent_pages")) }
        if let v = obj["recent_juz"] { return .recentJuz(try requireIntOrVar(v, "\(context).pool.recent_juz")) }
        if let v = obj["all_except_recent_pages"] {
            return .allExceptRecentPages(try requireIntOrVar(v, "\(context).pool.all_except_recent_pages"))
        }
        if let v = obj["all_except_recent_juz"] {
            return .allExceptRecentJuz(try requireIntOrVar(v, "\(context).pool.all_except_recent_juz"))
        }
        throw CurriculumError.malformed("\(context): pool malformed")
    }

    static func parsePerDaySpec(_ json: JSONValue, context: String) throws -> PerDaySpec {
        if let ramp = json["ramp"]?.objectValue {
            guard let startJSON = ramp["start"], let stepJSON = ramp["step"], let ceilingJSON = ramp["ceiling"] else {
                throw CurriculumError.malformed("\(context): ramp malformed")
            }
            return .ramp(
                start: try requireAmountOrVar(startJSON, "\(context).ramp.start"),
                step: try requireAmountOrVar(stepJSON, "\(context).ramp.step"),
                ceiling: try requireAmountOrVar(ceilingJSON, "\(context).ramp.ceiling"))
        }
        if let cd = json["cycle_days"] {
            return .cycleDays(try requireIntOrVar(cd, "\(context).cycle_days"))
        }
        throw CurriculumError.malformed("\(context): per_day malformed")
    }

    static func parseSelectorRef(_ json: JSONValue, context: String) throws -> SelectorRef {
        if let name = json.stringValue { return .named(name) }
        return .inline(try parseSelectorSpec(json, context: context))
    }

    static func selectorRefToJSON(_ ref: SelectorRef) -> JSONValue {
        switch ref {
        case .named(let name): return .string(name)
        case .inline(let spec): return selectorSpecToJSON(spec)
        }
    }

    static func selectorSpecToJSON(_ spec: SelectorSpec) -> JSONValue {
        switch spec {
        case .nextContent(let amount):
            return .object(["next_content": .object(["amount": amount.toJSON()])])
        case .nextNew(let amount):
            return .object(["next_new": .object(["amount": amount.toJSON()])])
        case .ledgerWindow(let days, let sunday):
            var obj: [String: JSONValue] = ["days": days.toJSON()]
            if let sunday { obj["sunday_days"] = sunday.toJSON() }
            return .object(["ledger_window": .object(obj)])
        case .ledgerOffset(let daysAgo):
            return .object(["ledger_offset": .object(["days_ago": daysAgo.toJSON()])])
        case .weekToDate:
            return .object(["week_to_date": .object([:])])
        case .poolRotation(let pool, let perDay, let weakBoost):
            var obj: [String: JSONValue] = ["pool": poolWindowToJSON(pool), "per_day": perDaySpecToJSON(perDay)]
            if let weakBoost { obj["weak_boost"] = weakBoost.toJSON() }
            return .object(["pool_rotation": .object(obj)])
        case .completedJuz:
            return .object(["completed_juz": .object(["which": .string("last")])])
        case .priorHifzSplit(let parts):
            return .object(["prior_hifz_split": .object(["parts": .number(String(parts))])])
        case .block(let count):
            return .object(["block": .object(["juz_count": count.toJSON(), "which": .string("last")])])
        case .tomorrowNew:
            return .object(["tomorrow_new": .object([:])])
        case .fixed(let ranges):
            return .object(["fixed": .object(["range": .array(ranges.map { $0.toJSONValue() })])])
        case .blockSlice(let of, let parts):
            return .object(["block_slice": .object(["of": .string(of), "parts": .number(String(parts))])])
        case .intersectPriorHifz(let ref):
            return .object(["intersect_prior_hifz": .object(["of": selectorRefToJSON(ref)])])
        }
    }

    static func poolWindowToJSON(_ pool: PoolWindow) -> JSONValue {
        switch pool {
        case .priorHifz: return .string("prior_hifz")
        case .recentPages(let n): return .object(["recent_pages": n.toJSON()])
        case .recentJuz(let n): return .object(["recent_juz": n.toJSON()])
        case .allExceptRecentPages(let n): return .object(["all_except_recent_pages": n.toJSON()])
        case .allExceptRecentJuz(let n): return .object(["all_except_recent_juz": n.toJSON()])
        }
    }

    static func perDaySpecToJSON(_ perDay: PerDaySpec) -> JSONValue {
        switch perDay {
        case .ramp(let start, let step, let ceiling):
            return .object(["ramp": .object(["start": start.toJSON(), "step": step.toJSON(), "ceiling": ceiling.toJSON()])])
        case .cycleDays(let n):
            return .object(["cycle_days": n.toJSON()])
        }
    }

    // MARK: Rules

    static func parseRuleWhen(_ whenObj: [String: JSONValue], ruleId: String) throws -> RuleWhenDraft {
        guard let session = whenObj["session"]?.stringValue else {
            throw CurriculumError.malformed("rule \(ruleId): when.session missing")
        }
        let dayClass: DayClassSpec
        if let single = whenObj["day_class"]?.stringValue {
            dayClass = .single(single)
        } else if let arr = whenObj["day_class"]?.arrayValue {
            let names = arr.compactMap(\.stringValue)
            guard names.count == arr.count, !names.isEmpty else {
                throw CurriculumError.malformed("rule \(ruleId): when.day_class array malformed")
            }
            dayClass = .multiple(names)
        } else {
            throw CurriculumError.malformed("rule \(ruleId): when.day_class missing")
        }
        var enabledVar: String? = nil
        if let enabled = whenObj["enabled"]?.stringValue {
            guard enabled.hasPrefix("$") else {
                throw CurriculumError.malformed("rule \(ruleId): when.enabled must be a $var ref")
            }
            enabledVar = String(enabled.dropFirst())
        }
        let dayIn = try whenObj["day_in"].map { try requireWeekdaySetOrVar($0, "rule \(ruleId).when.day_in") }
        var notConditions: [NotCondition] = []
        for item in whenObj["not"]?.arrayValue ?? [] {
            if let s = item.stringValue {
                switch s {
                case "first_active_day": notConditions.append(.firstActiveDay)
                case "in_consolidation_week": notConditions.append(.inConsolidationWeek)
                default: throw CurriculumError.malformed("rule \(ruleId): unknown not-condition '\(s)'")
                }
            } else if let flag = item["has_flag"]?.stringValue {
                notConditions.append(.hasFlag(flag))
            } else {
                throw CurriculumError.malformed("rule \(ruleId): bad not-condition")
            }
        }
        return RuleWhenDraft(
            dayClass: dayClass, session: session, dayIn: dayIn, enabledVar: enabledVar, notConditions: notConditions)
    }

    static func ruleWhenToJSON(_ when: RuleWhenDraft) -> JSONValue {
        var obj: [String: JSONValue] = [
            "day_class": when.dayClass.jsonValue,
            "session": .string(when.session),
        ]
        if let dayIn = when.dayIn { obj["day_in"] = dayIn.toJSON() }
        if let enabledVar = when.enabledVar { obj["enabled"] = .string("$\(enabledVar)") }
        if !when.notConditions.isEmpty { obj["not"] = .array(when.notConditions.map { $0.toJSON() }) }
        return .object(obj)
    }

    static func parseRuleEmit(_ emitObj: [String: JSONValue], ruleId: String) throws -> RuleEmitDraft {
        guard let type = emitObj["type"]?.stringValue else {
            throw CurriculumError.malformed("rule \(ruleId): emit.type missing")
        }
        guard let ordering = emitObj["ordering"]?.intValue else {
            throw CurriculumError.malformed("rule \(ruleId): emit.ordering missing")
        }
        let select = try emitObj["select"].map { try parseSelectorRef($0, context: "rule \(ruleId).select") }
        let repetitions = try emitObj["repetitions"].map { try requireIntOrVar($0, "rule \(ruleId).repetitions") }
        let spacing = try emitObj["spacing_minutes"].map { try requireIntOrVar($0, "rule \(ruleId).spacing_minutes") }
        let listenCount = try emitObj["listen_count"].map { try requireIntOrVar($0, "rule \(ruleId).listen_count") }
        var window: RuleWindowDraft? = nil
        if let w = emitObj["window"]?.objectValue {
            guard let opensCode = w["opens"]?.stringValue, let opens = Weekday(code: opensCode),
                  let closesCode = w["closes"]?.stringValue, let closes = Weekday(code: closesCode)
            else { throw CurriculumError.malformed("rule \(ruleId): emit.window malformed") }
            window = RuleWindowDraft(opens: opens, closes: closes)
        }
        return RuleEmitDraft(
            type: type, select: select, repetitions: repetitions, spacingMinutes: spacing, listenCount: listenCount,
            window: window, infoOnly: emitObj["info_only"]?.boolValue, ordering: ordering,
            label: emitObj["label"]?.objectValue?.compactMapValues(\.stringValue), estMinutes: emitObj["est_minutes"]?.intValue)
    }

    static func ruleEmitToJSON(_ emit: RuleEmitDraft) -> JSONValue {
        var obj: [String: JSONValue] = [
            "type": .string(emit.type),
            "ordering": .number(String(emit.ordering)),
        ]
        if let select = emit.select { obj["select"] = selectorRefToJSON(select) }
        if let r = emit.repetitions { obj["repetitions"] = r.toJSON() }
        if let s = emit.spacingMinutes { obj["spacing_minutes"] = s.toJSON() }
        if let l = emit.listenCount { obj["listen_count"] = l.toJSON() }
        if let w = emit.window {
            obj["window"] = .object(["opens": .string(w.opens.code), "closes": .string(w.closes.code)])
        }
        if let infoOnly = emit.infoOnly { obj["info_only"] = .bool(infoOnly) }
        if let label = emit.label { obj["label"] = .object(label.mapValues { .string($0) }) }
        if let est = emit.estMinutes { obj["est_minutes"] = .number(String(est)) }
        return .object(obj)
    }

    static func parseRule(_ json: JSONValue) throws -> RuleSpecDraft {
        guard let obj = json.objectValue, let id = obj["id"]?.stringValue else {
            throw CurriculumError.malformed("rule missing id")
        }
        guard let whenObj = obj["when"]?.objectValue else {
            throw CurriculumError.malformed("rule \(id): when missing")
        }
        guard let emitObj = obj["emit"]?.objectValue else {
            throw CurriculumError.malformed("rule \(id): emit missing")
        }
        return RuleSpecDraft(
            id: id,
            when: try parseRuleWhen(whenObj, ruleId: id),
            emit: try parseRuleEmit(emitObj, ruleId: id),
            explanation: obj["explanation"]?.objectValue?.compactMapValues(\.stringValue),
            suppressedBy: (obj["suppressed_by"]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    static func ruleToJSON(_ rule: RuleSpecDraft) -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(rule.id),
            "when": ruleWhenToJSON(rule.when),
            "emit": ruleEmitToJSON(rule.emit),
        ]
        if let explanation = rule.explanation { obj["explanation"] = .object(explanation.mapValues { .string($0) }) }
        if !rule.suppressedBy.isEmpty { obj["suppressed_by"] = .array(rule.suppressedBy.map { .string($0) }) }
        return .object(obj)
    }

    // MARK: Triggers

    static func parseTriggerOn(_ json: JSONValue, triggerId: String) throws -> TriggerOn {
        guard let onObj = json.objectValue else { throw CurriculumError.malformed("trigger \(triggerId): on missing") }
        if let boundary = onObj["boundary"]?.stringValue {
            let every = try onObj["every"].map { try requireIntOrVar($0, "trigger \(triggerId).on.every") }
            return .boundary(kind: boundary, every: every)
        } else if let reach = onObj["cursor_reaches"], let range = CanonicalRange(json: reach) {
            return .cursorReaches(range)
        } else if let rule = onObj["task_failed"]?["rule"]?.stringValue {
            return .taskFailed(rule: rule)
        } else {
            throw CurriculumError.malformed("trigger \(triggerId): on malformed")
        }
    }

    static func triggerOnToJSON(_ on: TriggerOn) -> JSONValue {
        switch on {
        case .boundary(let kind, let every):
            var obj: [String: JSONValue] = ["boundary": .string(kind)]
            if let every { obj["every"] = every.toJSON() }
            return .object(obj)
        case .cursorReaches(let range):
            return .object(["cursor_reaches": range.toJSONValue()])
        case .taskFailed(let rule):
            return .object(["task_failed": .object(["rule": .string(rule)])])
        }
    }

    static func parseTriggerEffect(_ json: JSONValue, triggerId: String) throws -> TriggerEffectDraft {
        guard let effectObj = json.objectValue, effectObj.count == 1, let key = effectObj.keys.first,
              let body = effectObj[key]
        else { throw CurriculumError.malformed("trigger \(triggerId): effect malformed") }
        switch key {
        case "schedule":
            guard let bodyObj = body.objectValue, let type = bodyObj["type"]?.stringValue,
                  let selectJSON = bodyObj["select"]
            else { throw CurriculumError.malformed("trigger \(triggerId): schedule malformed") }
            return .schedule(
                ScheduleEffectDraft(
                    type: type,
                    select: try parseSelectorRef(selectJSON, context: "trigger \(triggerId).schedule.select"),
                    distributeOverDays: bodyObj["distribute_over_days"]?.intValue,
                    intoSession: bodyObj["into_session"]?.stringValue,
                    starting: bodyObj["starting"]?.stringValue,
                    label: bodyObj["label"]?.objectValue?.compactMapValues(\.stringValue),
                    estMinutes: bodyObj["est_minutes"]?.intValue))
        case "insert_week":
            guard let bodyObj = body.objectValue, let name = bodyObj["name"]?.stringValue,
                  let rulesJSON = bodyObj["day_rules"]?.arrayValue
            else { throw CurriculumError.malformed("trigger \(triggerId): insert_week malformed") }
            return .insertWeek(
                InsertWeekEffectDraft(
                    name: name, modeVar: bodyObj["mode_var"]?.stringValue,
                    dayRules: try rulesJSON.map { try parseRule($0) }))
        case "set_flag":
            guard let bodyObj = body.objectValue, let name = bodyObj["name"]?.stringValue else {
                throw CurriculumError.malformed("trigger \(triggerId): set_flag malformed")
            }
            return .setFlag(name: name, until: bodyObj["until"]?.stringValue)
        case "clear_flag":
            guard let bodyObj = body.objectValue, let name = bodyObj["name"]?.stringValue else {
                throw CurriculumError.malformed("trigger \(triggerId): clear_flag malformed")
            }
            return .clearFlag(name: name)
        case "complete_plan":
            return .completePlan
        default:
            throw CurriculumError.malformed("trigger \(triggerId): unknown effect '\(key)'")
        }
    }

    static func triggerEffectToJSON(_ effect: TriggerEffectDraft) -> JSONValue {
        switch effect {
        case .schedule(let s):
            var obj: [String: JSONValue] = [
                "type": .string(s.type),
                "select": selectorRefToJSON(s.select),
            ]
            if let d = s.distributeOverDays { obj["distribute_over_days"] = .number(String(d)) }
            if let session = s.intoSession { obj["into_session"] = .string(session) }
            if let starting = s.starting { obj["starting"] = .string(starting) }
            if let label = s.label { obj["label"] = .object(label.mapValues { .string($0) }) }
            if let est = s.estMinutes { obj["est_minutes"] = .number(String(est)) }
            return .object(["schedule": .object(obj)])
        case .insertWeek(let w):
            var obj: [String: JSONValue] = [
                "name": .string(w.name),
                "day_rules": .array(w.dayRules.map { ruleToJSON($0) }),
            ]
            if let modeVar = w.modeVar { obj["mode_var"] = .string(modeVar) }
            return .object(["insert_week": .object(obj)])
        case .setFlag(let name, let until):
            var obj: [String: JSONValue] = ["name": .string(name)]
            if let until { obj["until"] = .string(until) }
            return .object(["set_flag": .object(obj)])
        case .clearFlag(let name):
            return .object(["clear_flag": .object(["name": .string(name)])])
        case .completePlan:
            return .object(["complete_plan": .object([:])])
        }
    }

    static func parseTrigger(_ json: JSONValue) throws -> TriggerSpecDraft {
        guard let obj = json.objectValue, let id = obj["id"]?.stringValue else {
            throw CurriculumError.malformed("trigger missing id")
        }
        guard let onJSON = obj["on"] else { throw CurriculumError.malformed("trigger \(id): on missing") }
        let effects = try (obj["effects"]?.arrayValue ?? []).map { try parseTriggerEffect($0, triggerId: id) }
        return TriggerSpecDraft(id: id, on: try parseTriggerOn(onJSON, triggerId: id), effects: effects)
    }

    static func triggerToJSON(_ trigger: TriggerSpecDraft) -> JSONValue {
        .object([
            "id": .string(trigger.id),
            "on": triggerOnToJSON(trigger.on),
            "effects": .array(trigger.effects.map { triggerEffectToJSON($0) }),
        ])
    }

    // MARK: Recovery / Advancement / Forecast

    static func parseRecovery(_ json: JSONValue) throws -> RecoveryDraft {
        guard let obj = json.objectValue,
              let policiesArr = obj["allowed_policies"]?.arrayValue,
              let defaultPolicy = obj["default"]?.stringValue,
              let escalationDays = obj["escalation_days"]?.intValue
        else { throw CurriculumError.malformed("recovery malformed") }
        let policies = policiesArr.compactMap(\.stringValue)
        guard policies.count == policiesArr.count else {
            throw CurriculumError.malformed("recovery.allowed_policies malformed")
        }
        return RecoveryDraft(allowedPolicies: policies, defaultPolicy: defaultPolicy, escalationDays: escalationDays)
    }

    static func recoveryToJSON(_ r: RecoveryDraft) -> JSONValue {
        .object([
            "allowed_policies": .array(r.allowedPolicies.map { .string($0) }),
            "default": .string(r.defaultPolicy),
            "escalation_days": .number(String(r.escalationDays)),
        ])
    }

    static func parseAdvancement(_ json: JSONValue) throws -> AdvancementDraft {
        guard let obj = json.objectValue else { throw CurriculumError.malformed("advancement malformed") }
        return AdvancementDraft(requireVerified: obj["require_verified"]?.boolValue)
    }

    static func advancementToJSON(_ a: AdvancementDraft) -> JSONValue {
        var obj: [String: JSONValue] = [:]
        if let rv = a.requireVerified { obj["require_verified"] = .bool(rv) }
        return .object(obj)
    }

    static func parseForecast(_ json: JSONValue) throws -> ForecastDraft {
        guard let obj = json.objectValue,
              let ratesObj = obj["workload_rates"]?.objectValue,
              let factorsObj = obj["strength_factors"]?.objectValue
        else { throw CurriculumError.malformed("forecast missing or malformed") }
        return ForecastDraft(workloadRates: ratesObj, strengthFactors: factorsObj)
    }

    static func forecastToJSON(_ f: ForecastDraft) -> JSONValue {
        .object([
            "workload_rates": .object(f.workloadRates),
            "strength_factors": .object(f.strengthFactors),
        ])
    }
}

extension DayClassSpec {
    var jsonValue: JSONValue {
        switch self {
        case .single(let s): return .string(s)
        case .multiple(let names): return .array(names.map { .string($0) })
        }
    }
}
