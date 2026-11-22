package masoon.curriculum

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import masoon.domain.AmountUnit
import masoon.domain.QuranAmount
import masoon.domain.Weekday

/**
 * Loader + D-028 reference validation for compiled curriculum JSON
 * (compiled JSON under `contracts/curricula`).
 */
object CurriculumLoader {

    /** D-028 (1): `$pace` is reserved and bound by the engine from PlanPolicy.new_amount. */
    const val RESERVED_PACE_VAR = "pace"

    /**
     * B:CB-0 finding 3 — the fallback for a schema-legal curriculum that omits `recovery`.
     * Mirrors Swift (`CompiledCurriculum.swift`: `default` ⇒ `"strict_backlog"`, `escalation_days`
     * ⇒ `3`). Descriptive only: the engine schedules from `PlanPolicy.recoveryPolicy`, never from
     * this block, so the value can never reach an emitted stream.
     */
    private val DEFAULT_RECOVERY = RecoverySpec(
        allowedPolicies = listOf("strict_backlog", "redistribute", "pause_and_resume"),
        default = "strict_backlog",
        escalationDays = 3,
    )

    fun load(text: String): CompiledCurriculum {
        val root = Json.parseToJsonElement(text).jsonObject
        val curriculum = parse(root)
        validate(curriculum)
        return curriculum
    }

    // ---------- parsing ----------

    private fun fail(msg: String): Nothing = throw CurriculumValidationException(msg)

    private fun varName(s: String): String = s.removePrefix("$")

    private fun <T> varOr(el: JsonElement, lit: (JsonElement) -> T): VarOr<T> =
        if (el is JsonPrimitive && el.isString && el.content.startsWith("$")) {
            VarOr.Ref(varName(el.content))
        } else {
            VarOr.Lit(lit(el))
        }

    private fun amountOf(el: JsonElement): QuranAmount {
        val o = el.jsonObject
        return QuranAmount(
            AmountUnit.fromCode(o.getValue("unit").jsonPrimitive.content),
            o.getValue("value").jsonPrimitive.content,
        )
    }

    private fun intOf(el: JsonElement): Int = el.jsonPrimitive.int

    /** B:CB-1 `LocalizedText` (`{ar, en}`), both members optional. Presentation-only. */
    private fun localizedText(el: JsonElement?): LocalizedText? {
        val o = el?.jsonObject ?: return null
        return LocalizedText(
            ar = o["ar"]?.jsonPrimitive?.content,
            en = o["en"]?.jsonPrimitive?.content,
        )
    }

    private fun parse(root: JsonObject): CompiledCurriculum {
        val metaO = root.getValue("meta").jsonObject
        val meta = Meta(
            slug = metaO.getValue("slug").jsonPrimitive.content,
            titleAr = metaO["title"]?.jsonObject?.get("ar")?.jsonPrimitive?.content,
            titleEn = metaO["title"]?.jsonObject?.get("en")?.jsonPrimitive?.content,
            nonNegotiables = metaO["non_negotiables"]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList(),
            corpora = metaO["corpora"]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList(),
        )

        val unitsO = root.getValue("units").jsonObject
        val units = UnitsSpec(
            allowed = unitsO.getValue("allowed").jsonArray.map { it.jsonPrimitive.content },
            defaultPace = amountOf(unitsO.getValue("default_pace")),
        )

        val calO = root.getValue("calendar").jsonObject
        val calendar = CalendarSpec(
            weekStart = Weekday.fromCode(calO.getValue("week_start").jsonPrimitive.content),
            dayClasses = calO.getValue("day_classes").jsonObject.mapValues { (_, v) ->
                v.jsonArray.map { Weekday.fromCode(it.jsonPrimitive.content) }
            },
            exceptionClasses = calO["exception_classes"]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList(),
        )

        val sessions = root.getValue("sessions").jsonArray.map {
            val s = it.jsonObject
            SessionDef(s.getValue("id").jsonPrimitive.content, s["default_time"]?.jsonPrimitive?.content)
        }

        val variables = root.getValue("variables").jsonObject.mapValues { (name, v) ->
            val o = v.jsonObject
            val type = o.getValue("type").jsonPrimitive.content
            val defaultEl = o.getValue("default")
            val default: VarDefault = when (type) {
                "int" -> VarDefault.IntD(defaultEl.jsonPrimitive.int)
                "bool" -> VarDefault.BoolD(defaultEl.jsonPrimitive.booleanOrNull ?: fail("variable $name: bad bool default"))
                "enum" -> VarDefault.StrD(defaultEl.jsonPrimitive.content)
                "amount" -> VarDefault.AmountD(amountOf(defaultEl))
                "weekday_set" -> VarDefault.WeekdaySetD(defaultEl.jsonArray.map { Weekday.fromCode(it.jsonPrimitive.content) }.toSet())
                else -> fail("variable $name: unknown type $type")
            }
            VariableDef(
                type = type,
                default = default,
                min = o["min"]?.jsonPrimitive?.intOrNull,
                max = o["max"]?.jsonPrimitive?.intOrNull,
                values = o["values"]?.jsonArray?.map { it.jsonPrimitive.content },
                nonNegotiable = o["non_negotiable"]?.jsonPrimitive?.booleanOrNull ?: false,
            )
        }

        val selectors = root.getValue("selectors").jsonObject.mapValues { (name, v) ->
            parseSelector(name, v.jsonObject)
        }

        val rules = root.getValue("rules").jsonArray.map { parseRule(it.jsonObject) }

        val triggers = root.getValue("triggers").jsonArray.map { t ->
            val o = t.jsonObject
            val id = o.getValue("id").jsonPrimitive.content
            val onO = o.getValue("on").jsonObject
            val on = TriggerOn(
                boundary = onO["boundary"]?.jsonPrimitive?.content,
                cursorReaches = onO["cursor_reaches"]?.let { parseFixedRange(it.jsonObject) },
                every = onO["every"]?.let { varOr(it, ::intOf) },
                taskFailed = onO["task_failed"]?.jsonObject?.get("rule")?.jsonPrimitive?.content,
            )
            if (on.boundary == null && on.cursorReaches == null && on.taskFailed == null) {
                fail("trigger $id: on must declare boundary, cursor_reaches or task_failed")
            }
            val effects = o.getValue("effects").jsonArray.map { eff -> parseEffect(eff.jsonObject) }
            TriggerSpec(id, on, effects)
        }

        val taskDeduplication = root["task_deduplication"]?.jsonObject?.get("mode")
            ?.jsonPrimitive?.content?.let { raw ->
                TaskDeduplicationMode.entries.firstOrNull { it.code == raw }
                    ?: fail("task_deduplication.mode malformed")
            }

        // B:CB-0 finding 3 — `recovery` is schema-OPTIONAL (not in the root `required` array).
        // `getValue` threw `NoSuchElementException` on a legal curriculum that omitted it, so a
        // definition Swift (`root["recovery"] ?? …`) and TS (`cur.recovery ?? …`) load fine crashed
        // only on Android. Absent ⇒ the same permissive default the other two engines use.
        val recovery = root["recovery"]?.jsonObject?.let { recO ->
            RecoverySpec(
                allowedPolicies = recO["allowed_policies"]?.jsonArray?.map { it.jsonPrimitive.content }
                    ?: DEFAULT_RECOVERY.allowedPolicies,
                default = recO["default"]?.jsonPrimitive?.content ?: DEFAULT_RECOVERY.default,
                escalationDays = recO["escalation_days"]?.jsonPrimitive?.int ?: DEFAULT_RECOVERY.escalationDays,
            )
        } ?: DEFAULT_RECOVERY

        // advancement (E-4b, D-046); absent ⇒ any completion advances
        val requireVerified =
            root["advancement"]?.jsonObject?.get("require_verified")?.jsonPrimitive?.booleanOrNull ?: false

        // B:CB-0 finding 3 — `evidence_defaults` is schema-OPTIONAL too; absent ⇒ empty map, which
        // `Engine.evidenceFor` already resolves to `self_check` (matching Swift/TS exactly).
        val evidenceDefaults = root["evidence_defaults"]?.jsonObject?.mapValues { (_, v) ->
            parseEvidenceDefault(v)
        } ?: emptyMap()

        val fcO = root.getValue("forecast").jsonObject
        val forecast = ForecastSpec(
            workloadRates = fcO.getValue("workload_rates").jsonObject.mapValues { (_, v) ->
                v.jsonPrimitive.content.toLong()
            },
            strengthFactorsScaled = fcO.getValue("strength_factors").jsonObject.mapValues { (_, v) ->
                // decimal string -> ×1000 scaled integer, no floating point
                val (num, scale) = QuranAmount.parseDecimal(v.jsonPrimitive.content)
                masoon.domain.roundHalfUpDiv(num * 1000L, scale)
            },
        )

        return CompiledCurriculum(
            meta, units, calendar, sessions, variables, selectors, rules, triggers,
            taskDeduplication, recovery, requireVerified, evidenceDefaults, forecast,
        )
    }

    private fun parseSelector(name: String, o: JsonObject): SelectorSpec {
        if (o.size != 1) fail("selector $name must have exactly one kind")
        val (kind, bodyEl) = o.entries.first()
        val body = bodyEl.jsonObject
        return when (kind) {
            "next_content" -> SelectorSpec.NextContent(varOr(body.getValue("amount"), ::amountOf))
            "next_new" -> SelectorSpec.NextNew(varOr(body.getValue("amount"), ::amountOf))
            "ledger_window" -> SelectorSpec.LedgerWindow(
                days = varOr(body.getValue("days"), ::intOf),
                sundayDays = body["sunday_days"]?.let { varOr(it, ::intOf) },
            )
            "ledger_offset" -> SelectorSpec.LedgerOffset(varOr(body.getValue("days_ago"), ::intOf))
            "week_to_date" -> SelectorSpec.WeekToDate
            "pool_rotation" -> {
                val perDayO = body.getValue("per_day").jsonObject
                val perDay = when {
                    "ramp" in perDayO -> {
                        val ramp = perDayO.getValue("ramp").jsonObject
                        SelectorSpec.PerDay.Ramp(
                            start = varOr(ramp.getValue("start"), ::amountOf),
                            step = varOr(ramp.getValue("step"), ::amountOf),
                            ceiling = varOr(ramp.getValue("ceiling"), ::amountOf),
                        )
                    }
                    "cycle_days" in perDayO ->
                        SelectorSpec.PerDay.CycleDays(varOr(perDayO.getValue("cycle_days"), ::intOf))
                    else -> fail("pool_rotation.per_day malformed")
                }
                val poolEl = body.getValue("pool")
                val pool = when {
                    poolEl is JsonPrimitive && poolEl.content == "prior_hifz" -> SelectorSpec.PoolWindow.PriorHifz
                    poolEl is JsonObject && "recent_pages" in poolEl ->
                        SelectorSpec.PoolWindow.RecentPages(varOr(poolEl.getValue("recent_pages"), ::intOf))
                    poolEl is JsonObject && "recent_juz" in poolEl ->
                        SelectorSpec.PoolWindow.RecentJuz(varOr(poolEl.getValue("recent_juz"), ::intOf))
                    poolEl is JsonObject && "all_except_recent_pages" in poolEl ->
                        SelectorSpec.PoolWindow.AllExceptRecentPages(
                            varOr(poolEl.getValue("all_except_recent_pages"), ::intOf)
                        )
                    poolEl is JsonObject && "all_except_recent_juz" in poolEl ->
                        SelectorSpec.PoolWindow.AllExceptRecentJuz(
                            varOr(poolEl.getValue("all_except_recent_juz"), ::intOf)
                        )
                    else -> fail("pool_rotation.pool malformed")
                }
                SelectorSpec.PoolRotation(
                    pool = pool,
                    perDay = perDay,
                    weakBoost = body["weak_boost"]?.jsonPrimitive?.intOrNull ?: 1,
                )
            }
            "completed_juz" -> SelectorSpec.CompletedJuz(body.getValue("which").jsonPrimitive.content)
            "prior_hifz_split" -> SelectorSpec.PriorHifzSplit(varOr(body.getValue("parts"), ::intOf))
            "block" -> SelectorSpec.Block(
                juzCount = varOr(body.getValue("juz_count"), ::intOf),
                which = body.getValue("which").jsonPrimitive.content,
            )
            "tomorrow_new" -> SelectorSpec.TomorrowNew
            "fixed" -> {
                val rangeEl = body.getValue("range")
                val ranges = if (rangeEl is JsonArray) rangeEl.map { parseFixedRange(it.jsonObject) }
                else listOf(parseFixedRange(rangeEl.jsonObject))
                SelectorSpec.Fixed(ranges)
            }
            "block_slice" -> SelectorSpec.BlockSlice(
                of = body.getValue("of").jsonPrimitive.content,
                parts = body.getValue("parts").jsonPrimitive.int,
            )
            "intersect_prior_hifz" -> SelectorSpec.IntersectPriorHifz(
                parseSelectorRef(body.getValue("of"))
            )
            else -> fail("selector $name: unknown kind $kind")
        }
    }

    private fun parseSelectorRef(element: JsonElement): SelectorRef = when (element) {
        is JsonPrimitive -> SelectorRef.Named(element.content)
        is JsonObject -> SelectorRef.Inline(parseSelector("<inline>", element))
        else -> fail("selector reference must be a name or inline selector")
    }

    private fun parseFixedRange(o: JsonObject): masoon.domain.CanonicalRange =
        masoon.domain.CanonicalRange(
            o.getValue("surah").jsonPrimitive.int,
            o.getValue("ayah_start").jsonPrimitive.int,
            o.getValue("ayah_end").jsonPrimitive.int,
        )

    private fun parseRule(o: JsonObject): RuleSpec {
        val whenO = o.getValue("when").jsonObject
        val dayClassEl = whenO.getValue("day_class")
        val dayClasses = if (dayClassEl is JsonArray) dayClassEl.map { it.jsonPrimitive.content }
        else listOf(dayClassEl.jsonPrimitive.content)
        val whenSpec = RuleWhen(
            dayClasses = dayClasses,
            session = whenO.getValue("session").jsonPrimitive.content,
            not = whenO["not"]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList(),
            enabled = whenO["enabled"]?.jsonPrimitive?.content?.let(::varName),
            dayIn = whenO["day_in"]?.jsonPrimitive?.content?.let(::varName),
        )
        val emitO = o.getValue("emit").jsonObject
        val selectEl = emitO["select"]
        val select: SelectorRef? = when (selectEl) {
            null -> null
            is JsonPrimitive -> SelectorRef.Named(selectEl.content)
            is JsonObject -> SelectorRef.Inline(parseSelector("<inline>", selectEl))
            else -> fail("rule ${o["id"]}: invalid select")
        }
        val emit = RuleEmit(
            type = emitO.getValue("type").jsonPrimitive.content,
            select = select,
            repetitions = emitO["repetitions"]?.let { varOr(it, ::intOf) },
            spacingMinutes = emitO["spacing_minutes"]?.let { varOr(it, ::intOf) },
            listenCount = emitO["listen_count"]?.let { varOr(it, ::intOf) },
            window = emitO["window"]?.jsonObject?.let {
                TaskWindowSpec(
                    Weekday.fromCode(it.getValue("opens").jsonPrimitive.content),
                    Weekday.fromCode(it.getValue("closes").jsonPrimitive.content),
                )
            },
            infoOnly = emitO["info_only"]?.jsonPrimitive?.booleanOrNull ?: false,
            ordering = emitO.getValue("ordering").jsonPrimitive.int,
            label = localizedText(emitO["label"]),
            estMinutes = emitO["est_minutes"]?.jsonPrimitive?.intOrNull,
        )
        return RuleSpec(
            id = o.getValue("id").jsonPrimitive.content,
            whenSpec = whenSpec,
            emit = emit,
            suppressedBy = o["suppressed_by"]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList(),
        )
    }

    private fun parseEffect(o: JsonObject): TriggerEffect {
        if (o.size != 1) fail("trigger effect must have exactly one kind")
        val (kind, bodyEl) = o.entries.first()
        return when (kind) {
            "schedule" -> {
                val b = bodyEl.jsonObject
                val selectEl = b.getValue("select")
                val select = if (selectEl is JsonPrimitive) SelectorRef.Named(selectEl.content)
                else SelectorRef.Inline(parseSelector("<inline>", selectEl.jsonObject))
                TriggerEffect.Schedule(
                    type = b.getValue("type").jsonPrimitive.content,
                    select = select,
                    distributeOverDays = b["distribute_over_days"]?.jsonPrimitive?.intOrNull,
                    intoSession = b["into_session"]?.jsonPrimitive?.content,
                    starting = b["starting"]?.jsonPrimitive?.content ?: "next_active_day",
                    label = localizedText(b["label"]),
                    estMinutes = b["est_minutes"]?.jsonPrimitive?.intOrNull,
                )
            }
            "insert_week" -> {
                val b = bodyEl.jsonObject
                TriggerEffect.InsertWeek(
                    name = b.getValue("name").jsonPrimitive.content,
                    modeVar = b["mode_var"]?.jsonPrimitive?.content,
                    dayRules = b.getValue("day_rules").jsonArray.map { parseRule(it.jsonObject) },
                )
            }
            "complete_plan" -> TriggerEffect.CompletePlan
            // §11.24: parsed and validated but inert in v1 engines
            "set_flag" -> {
                val b = bodyEl.jsonObject
                TriggerEffect.SetFlag(
                    b.getValue("name").jsonPrimitive.content,
                    b["until"]?.jsonPrimitive?.content,
                )
            }
            "clear_flag" -> TriggerEffect.ClearFlag(bodyEl.jsonObject.getValue("name").jsonPrimitive.content)
            else -> fail("unknown trigger effect: $kind")
        }
    }

    private fun parseEvidenceDefault(el: JsonElement): EvidenceDefaultSpec = when (el) {
        is JsonPrimitive -> when (el.content) {
            "self_check" -> EvidenceDefaultSpec.SelfCheck
            else -> fail("unknown evidence default: ${el.content}")
        }
        is JsonArray -> EvidenceDefaultSpec.Composite(el.map { parseEvidenceDefault(it) })
        is JsonObject -> {
            if (el.size != 1) fail("evidence default must have exactly one kind: $el")
            val (kind, body) = el.entries.first()
            when (kind) {
                "self_check" -> EvidenceDefaultSpec.SelfCheck
                "timer" -> EvidenceDefaultSpec.Timer(varOr(body.jsonObject.getValue("min_seconds"), ::intOf))
                "counter" -> EvidenceDefaultSpec.Counter(varOr(body.jsonObject.getValue("target"), ::intOf))
                "teacher_verification" -> EvidenceDefaultSpec.TeacherVerification(
                    body.jsonObject["form_version_id"]?.jsonPrimitive?.content
                )
                "form" -> EvidenceDefaultSpec.Form(body.jsonObject.getValue("form_version_id").jsonPrimitive.content)
                "composite" -> EvidenceDefaultSpec.Composite(body.jsonArray.map { parseEvidenceDefault(it) })
                else -> fail("unknown evidence default kind: $kind")
            }
        }
    }

    // ---------- validation (D-028 reference checks) ----------

    private fun validate(c: CompiledCurriculum) {
        // No curriculum may declare a variable named "pace" (D-028 (1)).
        if (c.variables.containsKey(RESERVED_PACE_VAR)) {
            fail("variable name 'pace' is reserved (\$pace binds to PlanPolicy.new_amount)")
        }

        fun checkVarRef(name: String, where: String) {
            if (name != RESERVED_PACE_VAR && !c.variables.containsKey(name)) {
                fail("$where references undeclared variable \$$name")
            }
        }

        // Duplicate ids
        val ruleIds = HashSet<String>()
        val allRules = c.rules + c.triggers.flatMap { t ->
            t.effects.filterIsInstance<TriggerEffect.InsertWeek>().flatMap { it.dayRules }
        }
        for (r in allRules) if (!ruleIds.add(r.id)) fail("duplicate rule id: ${r.id}")
        val triggerIds = HashSet<String>()
        for (t in c.triggers) if (!triggerIds.add(t.id)) fail("duplicate trigger id: ${t.id}")

        // Sessions & day classes referenced by rules
        val sessionIds = c.sessions.map { it.id }.toSet()
        val dayClassNames = c.calendar.dayClasses.keys
        for (r in allRules) {
            if (r.whenSpec.session !in sessionIds) fail("rule ${r.id}: unknown session ${r.whenSpec.session}")
            for (dc in r.whenSpec.dayClasses) {
                if (dc !in dayClassNames) fail("rule ${r.id}: unknown day_class $dc")
            }
            r.whenSpec.enabled?.let { checkVarRef(it, "rule ${r.id}.when.enabled") }
            r.whenSpec.dayIn?.let { checkVarRef(it, "rule ${r.id}.when.day_in") }
            for (s in r.suppressedBy) if (s !in triggerIds) fail("rule ${r.id}: unknown trigger in suppressed_by: $s")
            r.emit.select?.let { sel -> checkSelectorRef(c, sel, "rule ${r.id}") }
            listOfNotNull(r.emit.repetitions, r.emit.spacingMinutes, r.emit.listenCount).forEach {
                if (it is VarOr.Ref) checkVarRef(it.name, "rule ${r.id}.emit")
            }
        }

        // Selector internals
        for ((name, sel) in c.selectors) checkSelectorVars(c, name, sel, ::checkVarRef)

        // Trigger internals
        for (t in c.triggers) {
            t.on.every?.let { if (it is VarOr.Ref) checkVarRef(it.name, "trigger ${t.id}.on.every") }
            for (eff in t.effects) when (eff) {
                is TriggerEffect.Schedule -> checkSelectorRef(c, eff.select, "trigger ${t.id}")
                is TriggerEffect.InsertWeek -> eff.modeVar?.let { checkVarRef(it, "trigger ${t.id}.mode_var") }
                TriggerEffect.CompletePlan -> Unit
                is TriggerEffect.SetFlag -> Unit // inert (§11.24)
                is TriggerEffect.ClearFlag -> Unit // inert (§11.24)
            }
        }

        // Evidence default var refs
        fun checkEvidence(spec: EvidenceDefaultSpec, where: String) {
            when (spec) {
                is EvidenceDefaultSpec.Counter -> if (spec.target is VarOr.Ref) checkVarRef(spec.target.name, where)
                is EvidenceDefaultSpec.Timer -> if (spec.minSeconds is VarOr.Ref) checkVarRef(spec.minSeconds.name, where)
                is EvidenceDefaultSpec.Composite -> spec.parts.forEach { checkEvidence(it, where) }
                else -> Unit
            }
        }
        for ((type, spec) in c.evidenceDefaults) checkEvidence(spec, "evidence_defaults.$type")

        // Every weekday must map to exactly one day class
        val covered = HashSet<Weekday>()
        for ((name, days) in c.calendar.dayClasses) for (d in days) {
            if (!covered.add(d)) fail("weekday ${d.code} appears in multiple day classes (last: $name)")
        }
        if (covered.size != 7) fail("day_classes do not cover all 7 weekdays")
    }

    private fun checkSelectorRef(c: CompiledCurriculum, ref: SelectorRef, where: String) {
        when (ref) {
            is SelectorRef.Named ->
                if (!c.selectors.containsKey(ref.name)) fail("$where references unknown selector ${ref.name}")
            is SelectorRef.Inline -> {
                if (ref.spec is SelectorSpec.BlockSlice && !c.selectors.containsKey(ref.spec.of)) {
                    fail("$where block_slice references unknown selector ${ref.spec.of}")
                }
            }
        }
    }

    private fun checkSelectorVars(
        c: CompiledCurriculum,
        name: String,
        sel: SelectorSpec,
        checkVarRef: (String, String) -> Unit,
    ) {
        fun chk(v: VarOr<*>?, field: String) {
            if (v is VarOr.Ref) checkVarRef(v.name, "selector $name.$field")
        }
        when (sel) {
            is SelectorSpec.NextContent -> chk(sel.amount, "amount")
            is SelectorSpec.NextNew -> chk(sel.amount, "amount")
            is SelectorSpec.LedgerWindow -> { chk(sel.days, "days"); chk(sel.sundayDays, "sunday_days") }
            is SelectorSpec.LedgerOffset -> chk(sel.daysAgo, "days_ago")
            is SelectorSpec.PoolRotation -> {
                when (val pd = sel.perDay) {
                    is SelectorSpec.PerDay.Ramp -> {
                        chk(pd.start, "ramp.start"); chk(pd.step, "ramp.step"); chk(pd.ceiling, "ramp.ceiling")
                    }
                    is SelectorSpec.PerDay.CycleDays -> chk(pd.days, "per_day.cycle_days")
                }
                when (val p = sel.pool) {
                    is SelectorSpec.PoolWindow.RecentPages -> chk(p.count, "pool.recent_pages")
                    is SelectorSpec.PoolWindow.RecentJuz -> chk(p.count, "pool.recent_juz")
                    is SelectorSpec.PoolWindow.AllExceptRecentPages -> chk(p.count, "pool.all_except_recent_pages")
                    is SelectorSpec.PoolWindow.AllExceptRecentJuz -> chk(p.count, "pool.all_except_recent_juz")
                    SelectorSpec.PoolWindow.PriorHifz -> Unit
                }
            }
            is SelectorSpec.PriorHifzSplit -> chk(sel.parts, "parts")
            is SelectorSpec.Block -> chk(sel.juzCount, "juz_count")
            is SelectorSpec.BlockSlice ->
                if (!c.selectors.containsKey(sel.of)) fail("selector $name: block_slice of unknown selector ${sel.of}")
            is SelectorSpec.IntersectPriorHifz -> checkSelectorRef(c, sel.of, "selector $name.intersect_prior_hifz")
            else -> Unit
        }
    }
}
