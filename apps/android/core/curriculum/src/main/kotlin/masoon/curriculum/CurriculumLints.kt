package masoon.curriculum

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import masoon.domain.Weekday

/**
 * B7-C gate 3: a fixed, enumerable set of curriculum-authoring lints (Kotlin port of
 * `apps/ios/Packages/Sources/MasoonCurriculum/CurriculumLints.swift`). Each has a stable ID
 * (`L-07`..`L-15`) so a caller can filter/document/test against a single one. [CurriculumLints.run]
 * is gate 3's entire surface -- [CurriculumValidator] calls it once, after gate 2 has produced a
 * reference-valid [CompiledCurriculum].
 *
 * FULL ID LIST (every lint this file implements -- L-09/L-10 are intentionally absent, gaps by
 * design, not an oversight):
 *   L-07  error    duplicate `new_hifz` rules for the same day_class+session.
 *   L-08  warning  a `new_hifz` rule's day_class includes Friday, though the curriculum draws a
 *                  Friday/other-weekday distinction elsewhere in its calendar.
 *   L-11  error    a Unicode bidirectional-formatting control character appears anywhere in the
 *                  draft's authored text.
 *   L-12  error    two-or-more rules of the SAME `emit.type` share a day_class+session pair
 *                  (per-rule `emit.evidence` is declined for this stage, D-059 open).
 *   L-13  error    a `prep_dhikr` rule declares `emit.select`.
 *   L-14  error    a `listening`-type task is scheduled (rule or trigger `schedule` effect) but
 *                  `forecast.workload_rates` has no `listening_lesson` rate.
 *   L-15  error    a curriculum declares its own variable named `pace` (reserved).
 *
 * Rule/day_class/session identity used by L-07/L-08/L-12/L-13/L-14 comes from [allRules]: every
 * top-level day rule ([CompiledCurriculum.rules]) PLUS every inserted-week day rule
 * (`triggers[].effects[].InsertWeek.dayRules`) -- the same scope `CurriculumLoader`'s own
 * reference validation checks, so a rule hidden inside a five-juz-cycle consolidation week is not
 * silently exempt from these lints.
 */
object CurriculumLints {
    /**
     * Runs every lint above and returns every finding (lints do not short-circuit one another --
     * an author benefits from seeing all of them at once, not just the first).
     */
    fun run(draft: JsonElement, compiled: CompiledCurriculum): List<CurriculumIssue> {
        val issues = mutableListOf<CurriculumIssue>()
        issues += lintL07DuplicateNewHifz(compiled, draft)
        issues += lintL08FridayInNewHifzDayClass(compiled, draft)
        issues += lintL11BidiControlCharacters(draft)
        issues += lintL12AmbiguousSameTypeSharedSession(compiled, draft)
        issues += lintL13PrepDhikrWithSelector(compiled, draft)
        issues += lintL14ListeningWithoutRate(compiled, draft)
        issues += lintL15ReservedPaceVariableName(compiled)
        return issues
    }

    // -- Shared rule scope -----------------------------------------------------------------

    /** Every rule a full pipeline run would ever schedule: top-level day rules plus every inserted-week day rule. */
    internal fun allRules(c: CompiledCurriculum): List<RuleSpec> {
        val all = mutableListOf<RuleSpec>()
        all += c.rules
        for (trigger in c.triggers) {
            for (effect in trigger.effects) {
                if (effect is TriggerEffect.InsertWeek) all += effect.dayRules
            }
        }
        return all
    }

    // -- L-07: duplicate new_hifz rules per day_class+session -------------------------------

    private data class RuleGroupKey(val dayClass: String, val session: String)

    /**
     * Two (or more) DISTINCT rules both emitting `type: new_hifz` for the same day_class+session
     * pair -- ambiguous which is "the" new-hifz task for that slot.
     */
    private fun lintL07DuplicateNewHifz(c: CompiledCurriculum, draft: JsonElement): List<CurriculumIssue> {
        val groups = LinkedHashMap<RuleGroupKey, MutableSet<String>>()
        for (rule in allRules(c)) {
            if (rule.emit.type != "new_hifz") continue
            for (dayClass in rule.whenSpec.dayClasses.toSet()) {
                groups.getOrPut(RuleGroupKey(dayClass, rule.whenSpec.session)) { mutableSetOf() }.add(rule.id)
            }
        }
        val issues = mutableListOf<CurriculumIssue>()
        for (key in groups.keys.sortedWith(compareBy({ it.dayClass }, { it.session }))) {
            val ids = groups.getValue(key).sorted()
            if (ids.size <= 1) continue
            issues += CurriculumIssue(
                severity = IssueSeverity.ERROR, id = "L-07", gate = ValidationGate.LINTS,
                path = rulePointer(draft, ids[0]),
                messageEn = "Rules ${ids.joinToString(", ")} all emit new_hifz for day_class " +
                    "'${key.dayClass}' session '${key.session}' — ambiguous which is *the* new-hifz task.",
                messageAr = "القواعد ${ids.joinToString("، ")} كلها تُصدر مهمة الحفظ الجديد (new_hifz) " +
                    "لنفس فئة اليوم '${key.dayClass}' والجلسة '${key.session}' — لا يمكن تحديد أيها المهمة " +
                    "الأساسية للحفظ الجديد.",
            )
        }
        return issues
    }

    // -- L-08: Friday inside a new_hifz day_class, when the curriculum otherwise distinguishes it --

    /**
     * The default calendar convention (weekdays Sunday-Thursday; Friday/Saturday carry no new
     * memorization) is Maknoon's own convention, not a hard product-wide invariant -- some
     * built-ins legitimately schedule new_hifz on every day of the week including Friday via a
     * single, undifferentiated `daily` day_class. Naively flagging "a new_hifz rule's day_class
     * contains fri" would trip those. The calibrated trigger below only fires when the
     * curriculum's OWN calendar draws a Friday/other-weekday distinction SOMEWHERE (i.e. at least
     * one declared day_class contains another weekday but excludes Friday) yet a new_hifz rule
     * still schedules onto a day_class that includes Friday -- a genuine internal inconsistency,
     * not a curriculum design that never distinguishes days at all.
     */
    private fun lintL08FridayInNewHifzDayClass(c: CompiledCurriculum, draft: JsonElement): List<CurriculumIssue> {
        val drawsFridayDistinction = c.calendar.dayClasses.values.any { days -> days.isNotEmpty() && Weekday.FRI !in days }
        if (!drawsFridayDistinction) return emptyList()

        val issues = mutableListOf<CurriculumIssue>()
        for (rule in allRules(c).sortedBy { it.id }) {
            if (rule.emit.type != "new_hifz") continue
            val fridayClasses = rule.whenSpec.dayClasses
                .filter { c.calendar.dayClasses[it]?.contains(Weekday.FRI) == true }
                .sorted()
            if (fridayClasses.isEmpty()) continue
            issues += CurriculumIssue(
                severity = IssueSeverity.WARNING, id = "L-08", gate = ValidationGate.LINTS,
                path = rulePointer(draft, rule.id),
                messageEn = "Rule '${rule.id}' emits new_hifz on day_class(es) $fridayClasses which include " +
                    "Friday, though this curriculum excludes Friday from at least one other day_class — " +
                    "The default calendar convention is no new memorization on Friday/Saturday.",
                messageAr = "القاعدة '${rule.id}' تُصدر مهمة حفظ جديد ضمن فئة/فئات اليوم $fridayClasses " +
                    "التي تشمل يوم الجمعة، رغم أن هذا المنهج يستثني الجمعة في فئة يوم أخرى — العرف " +
                    "الافتراضي في مصون هو عدم وجود حفظ جديد أيام الجمعة والسبت.",
            )
        }
        return issues
    }

    // -- L-11: Unicode bidi-control characters in authored text -----------------------------

    /**
     * The explicit Unicode bidirectional FORMATTING characters (UAX #9 §3.4) plus the two
     * directional marks and the Arabic Letter Mark -- U+061C, U+200E, U+200F, U+202A-U+202E,
     * U+2066-U+2069. This is the same set common bidi-injection defenses check (e.g. the
     * "Trojan Source" CVE-2021-42574 class of attack: U+202E RIGHT-TO-LEFT OVERRIDE and friends
     * can visually reorder text to disguise its real content). Rejected outright (not just the
     * override/embed subset) because these are AUTHORED TEXT fields in an RTL-first app --
     * Compose's own bidi algorithm handles correct mixed-direction rendering without any author
     * needing to embed explicit control characters, so there is no legitimate authoring reason to
     * need one here, and every legitimate reason to refuse them from untrusted input. Scans EVERY
     * string value in the whole draft document (not only `LocalizedText`-shaped fields) -- a
     * strict superset, simpler to implement correctly and unable to miss a future authored-text
     * field this file's author forgot to enumerate. All characters here are in the Basic
     * Multilingual Plane, so a plain Kotlin `Char` (UTF-16 code unit) comparison, with no
     * surrogate-pair handling, is exact.
     *
     * Deliberately written as `\u` escapes, never as literal invisible characters pasted into
     * this source file: this file is itself IEEE-editor/terminal/diff-rendered text, and pasting
     * the very Trojan-Source-class characters this lint defends against would risk the source
     * being silently reordered or mis-copied by exactly the class of tool this lint exists to
     * distrust.
     */
    private val bidiControlChars: Set<Char> = setOf(
        '\u061C', // ARABIC LETTER MARK
        '\u200E', // LEFT-TO-RIGHT MARK
        '\u200F', // RIGHT-TO-LEFT MARK
        '\u202A', // LEFT-TO-RIGHT EMBEDDING
        '\u202B', // RIGHT-TO-LEFT EMBEDDING
        '\u202C', // POP DIRECTIONAL FORMATTING
        '\u202D', // LEFT-TO-RIGHT OVERRIDE
        '\u202E', // RIGHT-TO-LEFT OVERRIDE
        '\u2066', // LEFT-TO-RIGHT ISOLATE
        '\u2067', // RIGHT-TO-LEFT ISOLATE
        '\u2068', // FIRST STRONG ISOLATE
        '\u2069', // POP DIRECTIONAL ISOLATE
    )

    private fun lintL11BidiControlCharacters(draft: JsonElement): List<CurriculumIssue> {
        val issues = mutableListOf<CurriculumIssue>()

        fun walk(value: JsonElement, path: JSONPointer) {
            when (value) {
                is JsonPrimitive -> {
                    if (!value.isString) return
                    val hits = value.content.toCharArray().filter { it in bidiControlChars }.toSortedSet()
                    if (hits.isEmpty()) return
                    val codepoints = hits.joinToString(", ") { "U+" + it.code.toString(16).uppercase() }
                    val where = path.toString().ifEmpty { "(root)" }
                    val whereAr = path.toString().ifEmpty { "الجذر" }
                    issues += CurriculumIssue(
                        severity = IssueSeverity.ERROR, id = "L-11", gate = ValidationGate.LINTS, path = path,
                        messageEn = "Text at $where contains a Unicode bidirectional control character " +
                            "($codepoints) — rejected as untrusted input in an RTL app.",
                        messageAr = "النص في $whereAr يحتوي على رمز تحكم باتجاه الكتابة ($codepoints) — تم " +
                            "رفضه لأنه نص غير موثوق في تطبيق يدعم الكتابة من اليمين لليسار.",
                    )
                }
                is JsonArray -> value.forEachIndexed { i, el -> walk(el, path.appending(i)) }
                is JsonObject -> for (key in value.keys.sorted()) walk(value.getValue(key), path.appending(key))
                is JsonNull -> Unit
            }
        }
        walk(draft, JSONPointer())
        return issues
    }

    // -- L-12: same emit.type sharing a day_class+session (hard error) ----------------------

    private data class RuleTypeGroupKey(val dayClass: String, val session: String, val type: String)

    /**
     * THE FOUNDER GATE for per-rule `emit.evidence` overrides is unresolved this stage (declined
     * -- no `emit.evidence` schema field or engine support added). D-059 (open) documents the
     * fallback for the declined case exactly as implemented here: two or more rules of the SAME
     * `emit.type` sharing a day_class+session pair is a HARD ERROR, because
     * `curriculum.evidenceDefaults` is resolved by `type` alone (`Engine.kt`:
     * `evidenceFor(type, ...)`), so such rules are structurally unable to get independent evidence
     * specs today.
     *
     * IMPLEMENTED EXACTLY AS THE WORK ITEM SPECIFIES, per its own explicit instruction not to
     * loosen this check even if it trips a built-in. It does trip several of the 15 built-ins
     * (verified against the compiled JSON under `contracts/curricula` — see `CurriculumLintsTest`)
     * — this is the "serious finding" the work item anticipated and asked to have reported rather
     * than silently loosened. Shipped as specified regardless.
     */
    private fun lintL12AmbiguousSameTypeSharedSession(c: CompiledCurriculum, draft: JsonElement): List<CurriculumIssue> {
        // Exact-execution mode explicitly merges identical work to one UID
        // and advances every source rotation on that completion.
        if (c.taskDeduplication == TaskDeduplicationMode.EXACT_EXECUTION) return emptyList()
        val groups = LinkedHashMap<RuleTypeGroupKey, MutableSet<String>>()
        for (rule in allRules(c)) {
            for (dayClass in rule.whenSpec.dayClasses.toSet()) {
                val key = RuleTypeGroupKey(dayClass, rule.whenSpec.session, rule.emit.type)
                groups.getOrPut(key) { mutableSetOf() }.add(rule.id)
            }
        }
        val issues = mutableListOf<CurriculumIssue>()
        for (key in groups.keys.sortedWith(compareBy({ it.dayClass }, { it.session }, { it.type }))) {
            val ids = groups.getValue(key).sorted()
            if (ids.size <= 1) continue
            issues += CurriculumIssue(
                severity = IssueSeverity.ERROR, id = "L-12", gate = ValidationGate.LINTS,
                path = rulePointer(draft, ids[0]),
                messageEn = "Rules ${ids.joinToString(", ")} all emit '${key.type}' for day_class " +
                    "'${key.dayClass}' session '${key.session}'. Per-rule evidence overrides do not exist " +
                    "yet (D-059 open) — two or more same-type rules sharing a day_class+session cannot get " +
                    "independent evidence/counter tracking today. Split them into distinct sessions or " +
                    "day_classes.",
                messageAr = "القواعد ${ids.joinToString("، ")} كلها تُصدر نوع المهمة '${key.type}' " +
                    "لنفس فئة اليوم '${key.dayClass}' والجلسة '${key.session}'. لا يوجد حالياً دعم لتخصيص " +
                    "دليل إثبات (evidence) مستقل لكل قاعدة — لا يمكن تمييز عدّاداتها. افصل هذه القواعد " +
                    "إلى جلسات أو فئات أيام مختلفة.",
            )
        }
        return issues
    }

    // -- L-13: prep_dhikr with a selector ----------------------------------------------------

    /**
     * `prep_dhikr` (tasbih/istighfar preparation) is info-only across every built-in that uses it
     * -- each declares `info_only: true` and none declares `select`. `Engine.kt`'s
     * `estMinutes` zero-outs `prep_dhikr` unconditionally before any rate lookup, confirming the
     * engine itself treats it as never content-bearing. A `select`/selector on a `prep_dhikr` rule
     * can therefore never do anything useful and is rejected outright.
     */
    private fun lintL13PrepDhikrWithSelector(c: CompiledCurriculum, draft: JsonElement): List<CurriculumIssue> {
        val issues = mutableListOf<CurriculumIssue>()
        for (rule in allRules(c).sortedBy { it.id }) {
            if (rule.emit.type != "prep_dhikr" || rule.emit.select == null) continue
            issues += CurriculumIssue(
                severity = IssueSeverity.ERROR, id = "L-13", gate = ValidationGate.LINTS,
                path = rulePointer(draft, rule.id),
                messageEn = "Rule '${rule.id}' is type prep_dhikr but declares a select/selector — prep_dhikr " +
                    "is an info-only preparation task (tasbih/istighfar), never content-selecting.",
                messageAr = "القاعدة '${rule.id}' من نوع prep_dhikr (تحضير كالتسبيح والاستغفار) لكنها تُحدد " +
                    "selector لاختيار محتوى — مهام prep_dhikr إعلامية فقط ولا تختار محتوى قرآنياً أبداً.",
            )
        }
        return issues
    }

    // -- L-14: listening scheduled without a listening_lesson rate --------------------------

    private fun lintL14ListeningWithoutRate(c: CompiledCurriculum, draft: JsonElement): List<CurriculumIssue> {
        if (c.forecast.workloadRates.containsKey("listening_lesson")) return emptyList()

        val offendingRuleIds = allRules(c).filter { it.emit.type == "listening" }.map { it.id }.sorted()
        val offendingTriggerIds = c.triggers
            .filter { trigger -> trigger.effects.any { it is TriggerEffect.Schedule && it.type == "listening" } }
            .map { it.id }
            .sorted()
        if (offendingRuleIds.isEmpty() && offendingTriggerIds.isEmpty()) return emptyList()

        val names = offendingRuleIds.map { "rule '$it'" } + offendingTriggerIds.map { "trigger '$it'" }
        val path = offendingRuleIds.firstOrNull()?.let { rulePointer(draft, it) }
            ?: triggerPointer(draft, offendingTriggerIds[0])
        return listOf(
            CurriculumIssue(
                severity = IssueSeverity.ERROR, id = "L-14", gate = ValidationGate.LINTS, path = path,
                messageEn = "${names.joinToString(", ")} schedule(s) listening-type tasks, but " +
                    "forecast.workload_rates declares no 'listening_lesson' rate — the forecast cannot " +
                    "estimate minutes for these tasks.",
                messageAr = "${names.joinToString("، ")} تُصدر مهام استماع (listening) لكن " +
                    "forecast.workload_rates لا يحدد معدل 'listening_lesson' — لا يمكن للتوقع (forecast) " +
                    "تقدير الوقت لهذه المهام.",
            ),
        )
    }

    // -- L-15: reserved 'pace' variable name -------------------------------------------------

    /**
     * Enforces gate 2's `pace` name-collision fix here too, as its own lint ID, per the work
     * item's explicit instruction. By the time gate 3 runs, `compiled.variables["pace"]` can never
     * actually be non-null in the full [CurriculumValidator] pipeline: `CurriculumLoader.load`'s
     * `variables` parsing (gate 2) already throws for a top-level `variables.pace` declaration
     * before gate 2 can even produce a [CompiledCurriculum] (see `CurriculumLoader.RESERVED_PACE_VAR`),
     * so a document with that shape is stopped at gate 2 and gate 3 never runs at all. This lint is
     * genuinely unreachable via the full pipeline today; it is implemented anyway, exactly as
     * instructed, as a second independent layer — if the loader's guard is ever weakened or
     * removed without this file being updated in lockstep, this lint still catches it. Tested
     * directly against a hand-built [CompiledCurriculum] (bypassing the loader) rather than via
     * the pipeline, since the pipeline can never reach it.
     */
    private fun lintL15ReservedPaceVariableName(c: CompiledCurriculum): List<CurriculumIssue> {
        if (!c.variables.containsKey("pace")) return emptyList()
        return listOf(
            CurriculumIssue(
                severity = IssueSeverity.ERROR, id = "L-15", gate = ValidationGate.LINTS,
                path = JSONPointer(listOf("variables", "pace")),
                messageEn = "Variable name 'pace' is reserved — \$pace is bound internally by the engine from " +
                    "the plan's new_amount and is always treated as defined. An authored curriculum must not " +
                    "declare its own 'pace' variable.",
                messageAr = "اسم المتغير 'pace' محجوز — يربطه المحرك داخلياً بمعدّل الحفظ الجديد (new_amount) " +
                    "ويُعامل دائماً كمعرَّف. لا يجوز لمنهج مؤلَّف أن يعرّف متغيراً باسم 'pace'.",
            ),
        )
    }

    // -- Draft JSONPointer lookup (best-effort) ----------------------------------------------

    private fun stringField(el: JsonElement?, key: String): String? =
        ((el as? JsonObject)?.get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content

    /**
     * Finds [ruleId]'s location in the raw draft: either `rules[i]`, or
     * `triggers[t].effects[e].insert_week.day_rules[r]` for an inserted-week rule. Falls back to
     * `/rules` (a reasonable generic anchor) if the id can't be found -- should not happen for a
     * rule [allRules] sourced from a [CompiledCurriculum] freshly compiled from this exact
     * [draft], but this function never force-unwraps on the assumption.
     */
    private fun rulePointer(draft: JsonElement, ruleId: String): JSONPointer {
        val root = draft as? JsonObject ?: return JSONPointer(listOf("rules"))
        (root["rules"] as? JsonArray)?.forEachIndexed { i, r ->
            if (stringField(r, "id") == ruleId) return JSONPointer(listOf("rules")).appending(i)
        }
        (root["triggers"] as? JsonArray)?.forEachIndexed { t, trigger ->
            val effects = (trigger as? JsonObject)?.get("effects") as? JsonArray ?: return@forEachIndexed
            effects.forEachIndexed { e, effect ->
                val dayRules = ((effect as? JsonObject)?.get("insert_week") as? JsonObject)
                    ?.get("day_rules") as? JsonArray ?: return@forEachIndexed
                dayRules.forEachIndexed { r2, rule ->
                    if (stringField(rule, "id") == ruleId) {
                        return JSONPointer(listOf("triggers")).appending(t)
                            .appending("effects").appending(e)
                            .appending("insert_week").appending("day_rules").appending(r2)
                    }
                }
            }
        }
        return JSONPointer(listOf("rules"))
    }

    /** Finds [triggerId]'s location in the raw draft (`triggers[i]`). */
    private fun triggerPointer(draft: JsonElement, triggerId: String): JSONPointer {
        val root = draft as? JsonObject ?: return JSONPointer(listOf("triggers"))
        (root["triggers"] as? JsonArray)?.forEachIndexed { t, trigger ->
            if (stringField(trigger, "id") == triggerId) return JSONPointer(listOf("triggers")).appending(t)
        }
        return JSONPointer(listOf("triggers"))
    }
}
