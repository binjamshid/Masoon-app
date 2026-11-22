package masoon.domain

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Data-boundary JSON parsing for policy / starting state / events (ENGINE_PARITY §4.1 shapes).
 * JSON values are converted to typed domain values here; nothing downstream touches JSON.
 */
object PolicyJson {

    fun parseAmount(el: JsonElement): QuranAmount {
        val o = el.jsonObject
        val unit = AmountUnit.fromCode(o.getValue("unit").jsonPrimitive.content)
        val value = o.getValue("value").jsonPrimitive.content // decimal string OR number literal
        return QuranAmount(unit, value)
    }

    fun parseRange(el: JsonElement): CanonicalRange {
        val o = el.jsonObject
        return CanonicalRange(
            surah = o.getValue("surah").jsonPrimitive.int,
            ayahStart = o.getValue("ayah_start").jsonPrimitive.int,
            ayahEnd = o.getValue("ayah_end").jsonPrimitive.int,
        )
    }

    fun parsePosition(el: JsonElement): CanonicalPosition {
        val o = el.jsonObject
        return CanonicalPosition(o.getValue("surah").jsonPrimitive.int, o.getValue("ayah").jsonPrimitive.int)
    }

    fun parseTargetRange(el: JsonElement): TargetRange = when {
        el is JsonPrimitive && el.content == "full_quran" -> TargetRange.FullQuran
        el is JsonArray -> TargetRange.Ranges(el.map { parseRange(it) })
        else -> throw IllegalArgumentException("invalid target_range: $el")
    }

    fun parseOrder(el: JsonElement): OrderSpec {
        val o = el.jsonObject
        return when (val kind = o.getValue("kind").jsonPrimitive.content) {
            "mushaf_forward" -> OrderSpec.MushafForward
            "juz_amma_backward" -> OrderSpec.JuzAmmaBackward
            "custom_list" -> OrderSpec.CustomList(o.getValue("list").jsonArray.map { parseRange(it) })
            else -> throw IllegalArgumentException("unknown memorization_order kind: $kind")
        }
    }

    fun parseSession(el: JsonElement): SessionSpec {
        val s = el.jsonObject
        return SessionSpec(s.getValue("id").jsonPrimitive.content, s.getValue("start").jsonPrimitive.content)
    }

    fun parseWeekdaySet(el: JsonElement): Set<Weekday> =
        el.jsonArray.map { Weekday.fromCode(it.jsonPrimitive.content) }.toSet()

    fun parseRecovery(el: JsonElement): RecoveryPolicy {
        val o = el.jsonObject
        return when (val kind = o.getValue("kind").jsonPrimitive.content) {
            "strict_backlog" -> RecoveryPolicy.StrictBacklog
            "redistribute" -> RecoveryPolicy.Redistribute(
                days = o.getValue("days").jsonPrimitive.int,
                maxExtra = o["max_extra"]?.let { parseAmount(it) },
            )
            "pause_and_resume" -> RecoveryPolicy.PauseAndResume
            else -> throw IllegalArgumentException("unknown recovery_policy kind: $kind")
        }
    }

    fun parseEvidenceSpec(el: JsonElement): EvidenceSpec = when (el) {
        is JsonPrimitive -> when (el.content) {
            "self_check" -> EvidenceSpec.SelfCheck
            else -> throw IllegalArgumentException("unknown evidence spec: ${el.content}")
        }
        is JsonArray -> EvidenceSpec.Composite(el.map { parseEvidenceSpec(it) })
        is JsonObject -> {
            require(el.size == 1) { "evidence spec must have exactly one kind: $el" }
            val (kind, body) = el.entries.first()
            when (kind) {
                "self_check" -> EvidenceSpec.SelfCheck
                "timer" -> EvidenceSpec.Timer(body.jsonObject.getValue("min_seconds").jsonPrimitive.int)
                "counter" -> EvidenceSpec.Counter(body.jsonObject.getValue("target").jsonPrimitive.int)
                "teacher_verification" -> EvidenceSpec.TeacherVerification(
                    body.jsonObject["form_version_id"]?.jsonPrimitive?.content
                )
                "form" -> EvidenceSpec.Form(body.jsonObject.getValue("form_version_id").jsonPrimitive.content)
                "composite" -> EvidenceSpec.Composite(body.jsonArray.map { parseEvidenceSpec(it) })
                else -> throw IllegalArgumentException("unknown evidence spec kind: $kind")
            }
        }
    }

    fun parseVarValue(el: JsonElement): VarValue = when (el) {
        is JsonPrimitive -> when {
            el.booleanOrNull != null -> VarValue.BoolV(el.booleanOrNull!!)
            el.isString -> VarValue.StrV(el.content)
            else -> VarValue.IntV(el.int)
        }
        is JsonArray -> VarValue.WeekdaySetV(parseWeekdaySet(el))
        is JsonObject -> VarValue.AmountV(parseAmount(el))
    }

    fun parsePolicy(o: JsonObject): PlanPolicy = PlanPolicy(
        newAmount = parseAmount(o.getValue("new_amount")),
        targetRange = parseTargetRange(o.getValue("target_range")),
        memorizationOrder = parseOrder(o.getValue("memorization_order")),
        activeWeekdays = parseWeekdaySet(o.getValue("active_weekdays")),
        sessions = o.getValue("sessions").jsonArray.map { parseSession(it) },
        separateSessionCompletion = o["separate_session_completion"]?.jsonPrimitive?.booleanOrNull ?: true,
        // Multi-curriculum robustness (2026-07-16): absent variable-bound fields
        // stay NULL so the §11.21 binding falls through to the curriculum's DSL
        // variable default (H-2 originally defaulted them to Maknoon values,
        // which masked non-Maknoon DSL defaults — e.g. line-chunking takrar 10).
        listeningDays = o["listening_days"]?.let { parseWeekdaySet(it) },
        listeningCount = o["listening_count"]?.jsonPrimitive?.int,
        takrarCount = o["takrar_count"]?.jsonPrimitive?.int,
        takrarSpacingMinutes = o["takrar_spacing_minutes"]?.jsonPrimitive?.int,
        murajaahDailyCeiling = o["murajaah_daily_ceiling"]?.let { parseAmount(it) },
        murajaahRamp = o["murajaah_ramp"]?.let {
            val r = it.jsonObject
            RampSpec(parseAmount(r.getValue("start")), parseAmount(r.getValue("step")))
        },
        recoveryPolicy = parseRecovery(o.getValue("recovery_policy")),
        variableOverrides = o["variable_overrides"]?.jsonObject
            ?.mapValues { (_, v) -> parseVarValue(v) } ?: emptyMap(),
        cycleWeekMode = o["cycle_week_mode"]?.jsonPrimitive?.content,
        evidencePolicy = o["evidence_policy"]?.jsonObject
            ?.mapValues { (_, v) -> parseEvidenceSpec(v) } ?: emptyMap(),
    )

    /**
     * Apply a policy patch (plan.policy_changed / override.applied): field-wise replacement of
     * the listed top-level policy keys. Deterministic, typed; unknown keys are rejected.
     *
     * PC-6 null semantics: an ABSENT key still means "don't touch this field" (house style for
     * every key here), while a present JSON `null` explicitly CLEARS the field back to the
     * curriculum's own DSL default. `murajaah_ramp` holds one value, so clearing it means null;
     * `variable_overrides` and `evidence_policy` are per-name dictionaries of overrides, so
     * clearing means emptying the whole dictionary (the pre-existing `{}` behaviour merges
     * nothing and stays ambiguous with "no change" — hence the distinct null signal).
     */
    fun applyPatch(base: PlanPolicy, patch: JsonObject): PlanPolicy {
        var p = base
        for ((key, value) in patch) {
            val isNull = value is JsonNull
            p = when (key) {
                "new_amount" -> p.copy(newAmount = parseAmount(value))
                "target_range" -> p.copy(targetRange = parseTargetRange(value))
                "memorization_order" -> p.copy(memorizationOrder = parseOrder(value))
                "active_weekdays" -> p.copy(activeWeekdays = parseWeekdaySet(value))
                "listening_days" -> p.copy(listeningDays = parseWeekdaySet(value))
                "listening_count" -> p.copy(listeningCount = value.jsonPrimitive.int)
                "takrar_count" -> p.copy(takrarCount = value.jsonPrimitive.int)
                "takrar_spacing_minutes" -> p.copy(takrarSpacingMinutes = value.jsonPrimitive.int)
                "murajaah_daily_ceiling" -> p.copy(murajaahDailyCeiling = parseAmount(value))
                "murajaah_ramp" -> if (isNull) {
                    p.copy(murajaahRamp = null)
                } else {
                    val r = value.jsonObject
                    p.copy(murajaahRamp = RampSpec(parseAmount(r.getValue("start")), parseAmount(r.getValue("step"))))
                }
                "recovery_policy" -> p.copy(recoveryPolicy = parseRecovery(value))
                "cycle_week_mode" -> p.copy(cycleWeekMode = value.jsonPrimitive.content)
                "variable_overrides" -> if (isNull) {
                    p.copy(variableOverrides = emptyMap())
                } else {
                    p.copy(
                        variableOverrides = p.variableOverrides +
                            value.jsonObject.mapValues { (_, v) -> parseVarValue(v) }
                    )
                }
                "evidence_policy" -> if (isNull) {
                    p.copy(evidencePolicy = emptyMap())
                } else {
                    p.copy(
                        evidencePolicy = p.evidencePolicy +
                            value.jsonObject.mapValues { (_, v) -> parseEvidenceSpec(v) }
                    )
                }
                // PC-6(a): both were declared on PlanPolicy but never patchable — a `sessions` or
                // `separate_session_completion` key in a patch was rejected outright. A present,
                // parseable array replaces `sessions` wholesale (no per-session merge).
                "sessions" -> p.copy(sessions = value.jsonArray.map { parseSession(it) })
                "separate_session_completion" -> p.copy(
                    separateSessionCompletion = requireNotNull(value.jsonPrimitive.booleanOrNull) {
                        "separate_session_completion must be a boolean: $value"
                    }
                )
                else -> throw IllegalArgumentException("unsupported policy patch key: $key")
            }
        }
        return p
    }

    fun parseStartingState(o: JsonObject): LearnerStartingState = LearnerStartingState(
        memorizedRanges = o["memorized_ranges"]?.jsonArray?.map {
            val r = it.jsonObject
            DeclaredRange(
                range = parseRange(r.getValue("range")),
                strength = Strength.fromCode(r.getValue("strength").jsonPrimitive.content),
                declaredBy = r["declared_by"]?.jsonPrimitive?.content ?: "self",
            )
        } ?: emptyList(),
        placementCursor = parsePosition(o.getValue("placement_cursor")),
    )

    fun parseEvent(o: JsonObject): PlanEvent {
        val type = o.getValue("type").jsonPrimitive.content
        val payload = o["payload"]?.jsonObject ?: JsonObject(emptyMap())
        val occurred = o.getValue("occurred_at_local").jsonPrimitive.content
        fun payloadDate(key: String): LocalDate =
            payload[key]?.jsonPrimitive?.content?.let { LocalDate.parse(it) }
                ?: LocalDate.parse(occurred.substring(0, 10))

        val typed: EventPayload = when (type) {
            // D-032: task.* events key on payload.date (task instance's plan-LocalDate),
            // falling back to the local-date part of occurred_at_local
            "task.started" -> EventPayload.TaskStarted(
                payload.getValue("task_uid").jsonPrimitive.content,
                payloadDate("date"),
            )
            "task.completed" -> EventPayload.TaskCompleted(
                payload.getValue("task_uid").jsonPrimitive.content,
                payloadDate("date"),
                // E-4b (D-046): teacher_verification evidence OR an explicit
                // verified:true flag ⇒ a VERIFIED pass (same rule as TS/Swift).
                verified = payload["evidence"]?.jsonObject?.get("kind")?.jsonPrimitive?.content
                    == "teacher_verification" ||
                    payload["verified"]?.jsonPrimitive?.booleanOrNull == true ||
                    // Founder ruling, 2026-07-31: a filled tasmeeʿ ijāza attestation
                    // (TasmeeAttestation, kind "named_listener_attestation") satisfies
                    // `advancement.require_verified` too. It is recorded as a NAMED-LISTENER
                    // attestation, never as `teacher_verification`, so a future supervisor
                    // console can still tell a self-recorded session apart from a
                    // console-verified one — but the human listener did make the maqbūl/mardūd
                    // call, which is what D-041/D-046 actually require. Ported alongside
                    // `TasmeeAttestation` (`:feature:today`, WP-15) — ported from
                    // `Fold.swift:151` ("Aligned with the TS and Kotlin folds; Swift previously
                    // honored only the former" — this nested check was the one Kotlin was still
                    // missing, because nothing on Android built the attestation form yet).
                    payload["evidence"]?.jsonObject?.get("verified")?.jsonPrimitive?.booleanOrNull == true,
            )
            "task.uncompleted" -> EventPayload.TaskUncompleted(
                payload.getValue("task_uid").jsonPrimitive.content,
                payloadDate("date"),
                payload["reason"]?.jsonPrimitive?.content,
            )
            "task.excused" -> EventPayload.TaskExcused(
                payload.getValue("task_uid").jsonPrimitive.content,
                payloadDate("date"),
                payload["by"]?.jsonPrimitive?.content,
                payload["reason"]?.jsonPrimitive?.content,
            )
            // §11.20: plan.policy_changed WITHOUT effective_from is malformed -> deterministic no-op
            "plan.policy_changed" -> payload["effective_from"]?.let {
                EventPayload.PolicyChanged(
                    LocalDate.parse(it.jsonPrimitive.content),
                    payload.getValue("patch").jsonObject,
                )
            } ?: EventPayload.Opaque("plan.policy_changed:malformed")
            // D-054: a missing `slug` or an unparseable `effective_from` is a deterministic no-op
            // (I-4 house style, same as plan.policy_changed above) — the whole event is skipped,
            // including any bundled policy_patch, leaving both timelines exactly as they were.
            "plan.curriculum_upgraded" -> {
                val slug = payload["slug"]?.jsonPrimitive?.contentOrNull
                val from = payload["effective_from"]?.jsonPrimitive?.contentOrNull
                    ?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
                if (slug == null || from == null) {
                    EventPayload.Opaque("plan.curriculum_upgraded:malformed")
                } else {
                    EventPayload.CurriculumUpgraded(
                        effectiveFrom = from,
                        slug = slug,
                        version = payload["version"]?.jsonPrimitive?.contentOrNull ?: "",
                        policyPatch = payload["policy_patch"]?.jsonObject,
                    )
                }
            }
            // D-032.5/§11.20: override.applied without effective_from = beginning of plan
            "override.applied" -> EventPayload.OverrideApplied(
                payload["effective_from"]?.let { LocalDate.parse(it.jsonPrimitive.content) },
                payload.getValue("patch").jsonObject,
                payload["reason"]?.jsonPrimitive?.content,
            )
            // §11.26: recovery reads effective_from (a `date` key is NOT read),
            // else occurred_at_local's date — matches the Swift/TS engines.
            "plan.recovery_applied" -> EventPayload.RecoveryApplied(
                payload["effective_from"]?.jsonPrimitive?.content?.let { LocalDate.parse(it) }
                    ?: LocalDate.parse(occurred.substring(0, 10)),
            )
            "plan.paused" -> EventPayload.Paused(payloadDate("from"))
            "plan.resumed" -> EventPayload.Resumed(payloadDate("anchor"))
            "plan.day_closed" -> EventPayload.DayClosed(payloadDate("date"))
            "starting_state.declared", "starting_state.amended" ->
                EventPayload.StartingStateDeclared(parseStartingState(payload))
            else -> EventPayload.Opaque(type)
        }

        return PlanEvent(
            eventId = o.getValue("event_id").jsonPrimitive.content,
            type = type,
            payload = typed,
            serverSeq = o["server_seq"]?.jsonPrimitive?.content?.toLongOrNull(),
            deviceId = o["device_id"]?.jsonPrimitive?.content ?: "",
            clientSeq = o["client_seq"]?.jsonPrimitive?.content?.toLongOrNull() ?: 0L,
            occurredAtLocal = occurred,
            schemaVersion = o["schema_version"]?.jsonPrimitive?.int ?: 1,
            supersededBy = o["superseded_by"]?.jsonPrimitive?.content,
        )
    }
}
