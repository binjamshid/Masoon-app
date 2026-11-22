import MasoonDomain

/// CB-5 gate 3: a fixed, enumerable set of curriculum-authoring lints. Each
/// has a stable ID (`L-07`..`L-15`) so a caller can filter/document/test
/// against a single one. `CurriculumLints.run` is gate 3's entire surface —
/// `CurriculumValidator` calls it once, after gate 2 has produced a
/// reference-valid `CompiledCurriculum`.
///
/// FULL ID LIST (every lint this file implements):
///   L-07  error    duplicate `new_hifz` rules for the same day_class+session.
///   L-08  warning  a `new_hifz` rule's day_class includes Friday, though the
///                  curriculum draws a Friday/other-weekday distinction
///                  elsewhere in its calendar.
///   L-11  error    a Unicode bidirectional-formatting control character
///                  appears anywhere in the draft's authored text.
///   L-12  error    two-or-more rules of the SAME `emit.type` share a
///                  day_class+session pair (per-rule `emit.evidence` is
///                  declined for this stage, D-059 open — see below).
///   L-13  error    a `prep_dhikr` rule declares `emit.select`.
///   L-14  error    a `listening`-type task is scheduled (rule or trigger
///                  `schedule` effect) but `forecast.workload_rates` has no
///                  `listening_lesson` rate.
///   L-15  error    a curriculum declares its own variable named `pace`
///                  (reserved — see the dedicated note on that function).
///
/// Rule/day_class/session identity used by L-07/L-08/L-12/L-13/L-14 comes
/// from `allRules(_:)` below: every top-level day rule (`compiled.rules`)
/// PLUS every inserted-week day rule (`triggers[].effects[].insertWeek`'s
/// `dayRules`) — the same scope `CompiledCurriculum.validateReferences`
/// itself checks (`isDayRule: true` there).
public enum CurriculumLints {
    /// Runs every lint above and returns every finding (lints do not
    /// short-circuit one another — an author benefits from seeing all of
    /// them at once, not just the first).
    public static func run(draft: JSONValue, compiled: CompiledCurriculum) -> [CurriculumIssue] {
        var issues: [CurriculumIssue] = []
        issues += lintL07DuplicateNewHifz(compiled, draft: draft)
        issues += lintL08FridayInNewHifzDayClass(compiled, draft: draft)
        issues += lintL11BidiControlCharacters(draft)
        issues += lintL12AmbiguousSameTypeSharedSession(compiled, draft: draft)
        issues += lintL13PrepDhikrWithSelector(compiled, draft: draft)
        issues += lintL14ListeningWithoutRate(compiled, draft: draft)
        issues += lintL15ReservedPaceVariableName(compiled)
        return issues
    }

    // MARK: - Shared rule scope

    /// Every rule a full pipeline run would ever schedule: top-level day
    /// rules plus every inserted-week day rule. See the file header.
    static func allRules(_ c: CompiledCurriculum) -> [RuleSpec] {
        var all = c.rules
        for trigger in c.triggers {
            for effect in trigger.effects {
                if case .insertWeek(_, _, let dayRules) = effect {
                    all += dayRules
                }
            }
        }
        return all
    }

    // MARK: - L-07: duplicate new_hifz rules per day_class+session

    /// Two (or more) DISTINCT rules both emitting `type: new_hifz` for the
    /// same day_class+session pair — ambiguous which is "the" new-hifz task
    /// for that slot. Verified against all 15 built-ins: zero trips
    /// (`MasoonCurriculumTests`, `testAllBuiltinsCleanOnL07`).
    private static func lintL07DuplicateNewHifz(_ c: CompiledCurriculum, draft: JSONValue) -> [CurriculumIssue] {
        var groups: [RuleGroupKey: Set<String>] = [:]
        for rule in allRules(c) where rule.emit.type == "new_hifz" {
            for dayClass in Set(rule.when.dayClasses) {
                let key = RuleGroupKey(dayClass: dayClass, session: rule.when.session)
                groups[key, default: []].insert(rule.id)
            }
        }
        var issues: [CurriculumIssue] = []
        for key in groups.keys.sorted() {
            let ids = groups[key]!.sorted()
            guard ids.count > 1 else { continue }
            issues.append(CurriculumIssue(
                severity: .error, id: "L-07", gate: .lints,
                path: rulePointer(in: draft, ruleId: ids[0]),
                messageEn: "Rules \(ids.joined(separator: ", ")) all emit new_hifz for day_class "
                    + "'\(key.dayClass)' session '\(key.session)' — ambiguous which is *the* new-hifz task.",
                messageAr: "القواعد \(ids.joined(separator: "، ")) كلها تُصدر مهمة الحفظ الجديد (new_hifz) "
                    + "لنفس فئة اليوم '\(key.dayClass)' والجلسة '\(key.session)' — لا يمكن تحديد أيها المهمة "
                    + "الأساسية للحفظ الجديد."))
        }
        return issues
    }

    // MARK: - L-08: Friday inside a new_hifz day_class, when the curriculum
    // otherwise distinguishes Friday from other weekdays

    /// Warns when one calendar class excludes Friday and another schedules
    /// new memorization on Friday. An undifferentiated calendar can schedule
    /// new memorization every day.
    private static func lintL08FridayInNewHifzDayClass(_ c: CompiledCurriculum, draft: JSONValue) -> [CurriculumIssue] {
        let drawsFridayDistinction = c.dayClasses.values.contains { days in
            !days.isEmpty && !days.contains(.fri)
        }
        guard drawsFridayDistinction else { return [] }

        var issues: [CurriculumIssue] = []
        for rule in allRules(c).sorted(by: { $0.id < $1.id }) where rule.emit.type == "new_hifz" {
            let fridayClasses = rule.when.dayClasses
                .filter { c.dayClasses[$0]?.contains(.fri) == true }
                .sorted()
            guard !fridayClasses.isEmpty else { continue }
            issues.append(CurriculumIssue(
                severity: .warning, id: "L-08", gate: .lints,
                path: rulePointer(in: draft, ruleId: rule.id),
                messageEn: "Rule '\(rule.id)' emits new_hifz on day_class(es) \(fridayClasses) which include "
                    + "Friday, though this curriculum excludes Friday from at least one other day_class — "
                    + "Masoon's default convention is no new memorization on Friday/Saturday.",
                messageAr: "القاعدة '\(rule.id)' تُصدر مهمة حفظ جديد ضمن فئة/فئات اليوم \(fridayClasses) "
                    + "التي تشمل يوم الجمعة، رغم أن هذا المنهج يستثني الجمعة في فئة يوم أخرى — العرف "
                    + "الافتراضي في مصون هو عدم وجود حفظ جديد أيام الجمعة والسبت."))
        }
        return issues
    }

    // MARK: - L-11: Unicode bidi-control characters in authored text

    /// The explicit Unicode bidirectional FORMATTING characters (UAX #9
    /// §3.4) plus the two directional marks and the Arabic Letter Mark —
    /// U+061C, U+200E, U+200F, U+202A-U+202E, U+2066-U+2069. This is the
    /// same set common bidi-injection defenses check (e.g. the "Trojan
    /// Source" CVE-2021-42574 class of attack: U+202E RIGHT-TO-LEFT
    /// OVERRIDE and friends can visually reorder text to disguise its real
    /// content). Rejected outright (not just the override/embed subset)
    /// because these are AUTHORED TEXT fields in an RTL-first app —
    /// SwiftUI's own bidi algorithm handles correct mixed-direction
    /// rendering without any author needing to embed explicit control
    /// characters, so there is no legitimate authoring reason to need one
    /// here, and every legitimate reason to refuse them from untrusted
    /// input. Scans EVERY string value in the whole draft document (not
    /// only `LocalizedText`-shaped fields like `meta.title`/`rules[].label`/
    /// `explanation`) — a strict superset, simpler to implement correctly
    /// and unable to miss a future authored-text field this file's author
    /// forgot to enumerate. Verified against all 15 built-in YAML sources:
    /// zero trips.
    private static let bidiControlScalars: Set<Unicode.Scalar> = [
        "\u{061C}", // ARABIC LETTER MARK
        "\u{200E}", // LEFT-TO-RIGHT MARK
        "\u{200F}", // RIGHT-TO-LEFT MARK
        "\u{202A}", // LEFT-TO-RIGHT EMBEDDING
        "\u{202B}", // RIGHT-TO-LEFT EMBEDDING
        "\u{202C}", // POP DIRECTIONAL FORMATTING
        "\u{202D}", // LEFT-TO-RIGHT OVERRIDE
        "\u{202E}", // RIGHT-TO-LEFT OVERRIDE
        "\u{2066}", // LEFT-TO-RIGHT ISOLATE
        "\u{2067}", // RIGHT-TO-LEFT ISOLATE
        "\u{2068}", // FIRST STRONG ISOLATE
        "\u{2069}", // POP DIRECTIONAL ISOLATE
    ]

    private static func lintL11BidiControlCharacters(_ draft: JSONValue) -> [CurriculumIssue] {
        var issues: [CurriculumIssue] = []

        func walk(_ value: JSONValue, _ path: JSONPointer) {
            switch value {
            case .string(let s):
                let hits = Set(s.unicodeScalars.filter { bidiControlScalars.contains($0) })
                guard !hits.isEmpty else { return }
                let codepoints = hits.sorted { $0.value < $1.value }
                    .map { "U+" + String($0.value, radix: 16, uppercase: true) }
                    .joined(separator: ", ")
                issues.append(CurriculumIssue(
                    severity: .error, id: "L-11", gate: .lints, path: path,
                    messageEn: "Text at \(path.description.isEmpty ? "(root)" : path.description) contains a "
                        + "Unicode bidirectional control character (\(codepoints)) — rejected as untrusted "
                        + "input in an RTL app.",
                    messageAr: "النص في \(path.description.isEmpty ? "الجذر" : path.description) يحتوي على "
                        + "رمز تحكم باتجاه الكتابة (\(codepoints)) — تم رفضه لأنه نص غير موثوق في تطبيق يدعم "
                        + "الكتابة من اليمين لليسار."))
            case .array(let arr):
                for (i, el) in arr.enumerated() { walk(el, path.appending(index: i)) }
            case .object(let obj):
                for key in obj.keys.sorted() { walk(obj[key]!, path.appending(key)) }
            case .bool, .number, .null:
                break
            }
        }
        walk(draft, JSONPointer())
        return issues
    }

    // MARK: - L-12: same emit.type sharing a day_class+session (hard error)

    /// Evidence specifications are resolved by task type. Two rules of
    /// that type in the same session and day class cannot carry independent
    /// evidence specifications. Task IDs and counters are still per rule.
    private static func lintL12AmbiguousSameTypeSharedSession(
        _ c: CompiledCurriculum, draft: JSONValue
    ) -> [CurriculumIssue] {
        // Exact-execution mode is an explicit authored decision that
        // identical same-session work shares one evidence/completion. The
        // deduplicator preserves provenance and maps every source rotation
        // to that one UID, so L-12's "must be independent" premise does not
        // apply to this opt-in curriculum.
        if c.taskDeduplication == .exactExecution { return [] }
        var groups: [RuleTypeGroupKey: Set<String>] = [:]
        for rule in allRules(c) {
            for dayClass in Set(rule.when.dayClasses) {
                let key = RuleTypeGroupKey(dayClass: dayClass, session: rule.when.session, type: rule.emit.type)
                groups[key, default: []].insert(rule.id)
            }
        }
        var issues: [CurriculumIssue] = []
        for key in groups.keys.sorted() {
            let ids = groups[key]!.sorted()
            guard ids.count > 1 else { continue }
            issues.append(CurriculumIssue(
                severity: .error, id: "L-12", gate: .lints,
                path: rulePointer(in: draft, ruleId: ids[0]),
                messageEn: "Rules \(ids.joined(separator: ", ")) all emit '\(key.type)' for day_class "
                    + "'\(key.dayClass)' session '\(key.session)'. Per-rule evidence overrides do not exist "
                    + "yet (D-059 open) — two or more same-type rules sharing a day_class+session cannot get "
                    + "independent evidence/counter tracking today. Split them into distinct sessions or "
                    + "day_classes.",
                messageAr: "القواعد \(ids.joined(separator: "، ")) كلها تُصدر نوع المهمة '\(key.type)' "
                    + "لنفس فئة اليوم '\(key.dayClass)' والجلسة '\(key.session)'. لا يوجد حالياً دعم لتخصيص "
                    + "دليل إثبات (evidence) مستقل لكل قاعدة — لا يمكن تمييز عدّاداتها. افصل هذه القواعد "
                    + "إلى جلسات أو فئات أيام مختلفة."))
        }
        return issues
    }

    // MARK: - L-13: prep_dhikr with a selector

    /// `prep_dhikr` (tasbih/istighfar preparation) is info-only across all
    /// 15 built-ins that use it — every one declares `info_only: true` and
    /// none declares `select` (verified by direct inspection, not assumed).
    /// `Engine.swift`'s `estimateMinutes` zero-outs `prep_dhikr`
    /// unconditionally before any rate lookup, confirming the engine itself
    /// treats it as never content-bearing. A `select`/selector on a
    /// `prep_dhikr` rule can therefore never do anything useful and is
    /// rejected outright. Verified against all 15 built-ins: zero trips.
    private static func lintL13PrepDhikrWithSelector(_ c: CompiledCurriculum, draft: JSONValue) -> [CurriculumIssue] {
        var issues: [CurriculumIssue] = []
        for rule in allRules(c).sorted(by: { $0.id < $1.id })
        where rule.emit.type == "prep_dhikr" && rule.emit.select != nil {
            issues.append(CurriculumIssue(
                severity: .error, id: "L-13", gate: .lints,
                path: rulePointer(in: draft, ruleId: rule.id),
                messageEn: "Rule '\(rule.id)' is type prep_dhikr but declares a select/selector — prep_dhikr "
                    + "is an info-only preparation task (tasbih/istighfar), never content-selecting.",
                messageAr: "القاعدة '\(rule.id)' من نوع prep_dhikr (تحضير كالتسبيح والاستغفار) لكنها تُحدد "
                    + "selector لاختيار محتوى — مهام prep_dhikr إعلامية فقط ولا تختار محتوى قرآنياً أبداً."))
        }
        return issues
    }

    // MARK: - L-14: listening scheduled without a listening_lesson rate

    /// A listening task requires a listening workload rate for forecasts.
    private static func lintL14ListeningWithoutRate(_ c: CompiledCurriculum, draft: JSONValue) -> [CurriculumIssue] {
        guard c.workloadRates["listening_lesson"] == nil else { return [] }

        let offendingRuleIds = allRules(c)
            .filter { $0.emit.type == "listening" }
            .map(\.id)
            .sorted()
        let offendingTriggerIds = c.triggers
            .filter { trigger in
                trigger.effects.contains { effect in
                    if case .schedule(let type, _, _, _, _, _, _) = effect { return type == "listening" }
                    return false
                }
            }
            .map(\.id)
            .sorted()
        guard !offendingRuleIds.isEmpty || !offendingTriggerIds.isEmpty else { return [] }

        let names = offendingRuleIds.map { "rule '\($0)'" } + offendingTriggerIds.map { "trigger '\($0)'" }
        let path = offendingRuleIds.first.map { rulePointer(in: draft, ruleId: $0) }
            ?? triggerPointer(in: draft, triggerId: offendingTriggerIds[0])
        return [CurriculumIssue(
            severity: .error, id: "L-14", gate: .lints, path: path,
            messageEn: "\(names.joined(separator: ", ")) schedule(s) listening-type tasks, but "
                + "forecast.workload_rates declares no 'listening_lesson' rate — the forecast cannot "
                + "estimate minutes for these tasks.",
            messageAr: "\(names.joined(separator: "، ")) تُصدر مهام استماع (listening) لكن "
                + "forecast.workload_rates لا يحدد معدل 'listening_lesson' — لا يمكن للتوقع (forecast) "
                + "تقدير الوقت لهذه المهام.")]
    }

    // MARK: - L-15: reserved 'pace' variable name

    /// Checks the reserved name when given a directly constructed curriculum.
    private static func lintL15ReservedPaceVariableName(_ c: CompiledCurriculum) -> [CurriculumIssue] {
        guard c.variables["pace"] != nil else { return [] }
        return [CurriculumIssue(
            severity: .error, id: "L-15", gate: .lints, path: JSONPointer(["variables", "pace"]),
            messageEn: "Variable name 'pace' is reserved — $pace is bound internally by the engine from the "
                + "plan's new_amount and is always treated as defined. An authored curriculum must not "
                + "declare its own 'pace' variable.",
            messageAr: "اسم المتغير 'pace' محجوز — يربطه المحرك داخلياً بمعدّل الحفظ الجديد (new_amount) "
                + "ويُعامل دائماً كمعرَّف. لا يجوز لمنهج مؤلَّف أن يعرّف متغيراً باسم 'pace'.")]
    }

    // MARK: - Shared grouping keys

    private struct RuleGroupKey: Hashable, Comparable {
        let dayClass: String
        let session: String
        static func < (lhs: RuleGroupKey, rhs: RuleGroupKey) -> Bool {
            (lhs.dayClass, lhs.session) < (rhs.dayClass, rhs.session)
        }
    }

    private struct RuleTypeGroupKey: Hashable, Comparable {
        let dayClass: String
        let session: String
        let type: String
        static func < (lhs: RuleTypeGroupKey, rhs: RuleTypeGroupKey) -> Bool {
            (lhs.dayClass, lhs.session, lhs.type) < (rhs.dayClass, rhs.session, rhs.type)
        }
    }

    // MARK: - Draft JSONPointer lookup (best-effort)

    /// Finds `ruleId`'s location in the raw draft: either `rules[i]`, or
    /// `triggers[t].effects[e].insert_week.day_rules[r]` for an
    /// inserted-week rule. Falls back to `/rules` (a reasonable generic
    /// anchor) if the id can't be found — should not happen for a rule
    /// `allRules(_:)` sourced from a `CompiledCurriculum` freshly compiled
    /// from this exact `draft`, but this function never force-unwraps on
    /// the assumption.
    private static func rulePointer(in draft: JSONValue, ruleId: String) -> JSONPointer {
        if let rules = draft["rules"]?.arrayValue {
            for (i, r) in rules.enumerated() where r["id"]?.stringValue == ruleId {
                return JSONPointer(["rules"]).appending(index: i)
            }
        }
        if let triggers = draft["triggers"]?.arrayValue {
            for (t, trigger) in triggers.enumerated() {
                guard let effects = trigger["effects"]?.arrayValue else { continue }
                for (e, effect) in effects.enumerated() {
                    guard let dayRules = effect["insert_week"]?["day_rules"]?.arrayValue else { continue }
                    for (r, rule) in dayRules.enumerated() where rule["id"]?.stringValue == ruleId {
                        return JSONPointer(["triggers"]).appending(index: t)
                            .appending("effects").appending(index: e)
                            .appending("insert_week").appending("day_rules").appending(index: r)
                    }
                }
            }
        }
        return JSONPointer(["rules"])
    }

    /// Finds `triggerId`'s location in the raw draft (`triggers[i]`).
    private static func triggerPointer(in draft: JSONValue, triggerId: String) -> JSONPointer {
        if let triggers = draft["triggers"]?.arrayValue {
            for (t, trigger) in triggers.enumerated() where trigger["id"]?.stringValue == triggerId {
                return JSONPointer(["triggers"]).appending(index: t)
            }
        }
        return JSONPointer(["triggers"])
    }
}
