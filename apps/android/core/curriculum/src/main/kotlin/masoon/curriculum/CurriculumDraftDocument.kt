package masoon.curriculum

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonUnquotedLiteral
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import masoon.domain.AmountUnit
import masoon.domain.CanonicalRange
import masoon.domain.QuranAmount
import masoon.domain.Weekday

/**
 * B7-WaveC: [CurriculumDraft]'s JSON round trip — [CurriculumDraft.fromDocument] (parse) and
 * [CurriculumDraft.toDocument] (serialize) — plus [CurriculumDraft.canonicalJsonText], this
 * module's own deterministic serializer. Kotlin port of
 * `apps/ios/Packages/Sources/MasoonCurriculum/CurriculumDraft+Document.swift`.
 * [CompiledCurriculum]/[CurriculumLoader] are never modified — every addition here is either a
 * new type (`CurriculumDraft.kt`) or a new top-level function operating on it, both purely
 * additive.
 *
 * ## Why numbers are handled the way they are
 *
 * [QuranAmount.value] is already a decimal STRING ("1", "0.5", "0.50") preserved verbatim from
 * whatever [kotlinx.serialization.json.JsonPrimitive.content] handed it — unlike Swift's
 * `DecimalValue` (exact-arithmetic, `description` prints a `"units/denominator"` FRACTION for a
 * non-integer, e.g. `0.5` -> `"5/10"`, not even valid JSON, which is why the Swift source needs
 * its own `jsonNumberToken` reconstruction helper). Kotlin's [QuranAmount] never had that problem
 * to begin with, so there is no equivalent helper here — [quranAmountToJson] just re-emits
 * [QuranAmount.value]'s stored string as a raw (unquoted) JSON number token via
 * [JsonUnquotedLiteral], the one place this file needs kotlinx.serialization's raw-numeric-token
 * escape hatch (`@ExperimentalSerializationApi`, stable since 1.6.0): every other numeric value
 * this port touches is either a genuine machine `Int` (safe to re-derive) or copied verbatim from
 * the original parsed [JsonElement] tree without ever being decoded (`forecast.workload_rates`/
 * `strength_factors`, `evidence_defaults`, a [VariableDraft.defaultValue]).
 *
 * ## Byte-equality vs. `masoon.data.JsonText`
 *
 * `:core:data`'s `JsonText.kt` is the exact deterministic-serializer counterpart this file would
 * otherwise want to reuse (sorted object keys, raw numeric tokens preserved verbatim, identical
 * string-escaping table) — it is NOT usable here, for the same two reasons the Swift source gives
 * for not using `MasoonData.JSONText`: (1) layering — `:core:curriculum`'s own `build.gradle.kts`
 * depends on `:core:domain` only ("Pure-JVM; depends only on :core:domain (+ kotlinx-serialization
 * -json at the data boundary)"), never `:core:data`, and `:core:data` depends the other way
 * (`JsonText` is the DB-column codec for entities that themselves reference curricula) — adding
 * the reverse edge would be a real dependency cycle, not a style choice; (2) `:core:data`'s
 * `JsonText` has no reason to ever become part of a pure-engine module's public surface even if
 * the cycle were broken. [CurriculumDraftJsonText] below is therefore an independent
 * implementation, NOT a divergent format: it deliberately mirrors `JsonText`'s exact algorithm so
 * that `CurriculumDraftTest` gets a genuine byte-equality proof (the stronger of the two
 * properties the port's fidelity bar asks for) alongside plain [JsonElement]`.equals` structural
 * equality (which — being `Map`-backed for [JsonObject] — already ignores key order on its own).
 */
internal object CurriculumDraftJsonText {
    /** Sorted-key, raw-token serialization. */
    fun serialize(value: JsonElement): String = StringBuilder().also { write(value, it) }.toString()

    private fun write(value: JsonElement, out: StringBuilder) {
        when (value) {
            is kotlinx.serialization.json.JsonNull -> out.append("null")
            is JsonPrimitive -> if (value.isString) writeString(value.content, out) else out.append(value.content)
            is JsonArray -> {
                out.append('[')
                value.forEachIndexed { index, item ->
                    if (index > 0) out.append(',')
                    write(item, out)
                }
                out.append(']')
            }
            is JsonObject -> {
                out.append('{')
                value.keys.sorted().forEachIndexed { index, key ->
                    if (index > 0) out.append(',')
                    writeString(key, out)
                    out.append(':')
                    write(value.getValue(key), out)
                }
                out.append('}')
            }
        }
    }

    private fun writeString(text: String, out: StringBuilder) {
        out.append('"')
        for (char in text) {
            when {
                char == '"' -> out.append("\\\"")
                char == '\\' -> out.append("\\\\")
                char == '\n' -> out.append("\\n")
                char == '\r' -> out.append("\\r")
                char == '\t' -> out.append("\\t")
                char.code < CONTROL_CHARACTER_CEILING -> out.append("\\u%04x".format(char.code))
                else -> out.append(char)
            }
        }
        out.append('"')
    }

    private const val CONTROL_CHARACTER_CEILING = 0x20
}

// ---------- Public round trip ----------

/**
 * Parses a `curriculum-v1` JSON document into an editable draft. Structural (shape) checks only —
 * throws [CurriculumValidationException] when a required key/shape is missing, but does NOT
 * re-implement schema value-format validation (regex patterns, enum membership, numeric ranges)
 * or D-028 reference validation: those remain [CurriculumLoader]'s (and a future validator's) job,
 * reachable once a caller has a [CurriculumDraft] and calls [CurriculumDraft.toDocument] on it.
 */
fun CurriculumDraft.Companion.fromDocument(json: JsonElement): CurriculumDraft = CurriculumDraftCoding.parseDocument(json)

/**
 * Serializes back to a `curriculum-v1` JSON document. Never fills in a schema default for an
 * absent optional field — every nullable field in this model omits its JSON key entirely when
 * `null` (see each field's doc comment in `CurriculumDraft.kt`), which is the property the
 * round-trip proof depends on. [JsonObject] key insertion order below is irrelevant: downstream
 * structural/canonical comparisons never see it ([JsonObject] is `Map`-backed, and
 * [CurriculumDraftJsonText] sorts keys anyway).
 */
fun CurriculumDraft.toDocument(): JsonObject = CurriculumDraftCoding.documentToJson(this)

/**
 * Deterministic canonical text for [toDocument]'s output — see this file's header for why this
 * isn't `masoon.data.JsonText` itself. Useful standalone too: a future publish flow needing
 * canonical text to hash/diff/store against a compiled document under `contracts/curricula` can
 * use this directly instead of re-deriving it.
 */
fun CurriculumDraft.canonicalJsonText(): String = CurriculumDraftJsonText.serialize(toDocument())

// ---------- Parsing/serialization plumbing ----------

/**
 * Module-internal (not file-private — mirrors the Swift source's own choice, in case a future
 * single-selector-granularity caller inside `:core:curriculum` needs [parseSelectorSpec]/
 * [selectorSpecToJson] directly, the way `SelectorSpec+JSON.swift` needed them from
 * `CurriculumDraftCoding`) coding namespace: every JSON <-> Draft-type conversion that isn't a
 * single-line leaf mapping lives here, so the public [fromDocument]/[toDocument] functions stay a
 * short, readable assembly of these pieces. Deliberately does NOT call [CurriculumLoader]'s own
 * (`private`) parsing helpers — those are permissive (silently default-filling absent optional
 * fields for the engine's benefit) where this needs to fail loud and preserve absence exactly.
 */
@OptIn(ExperimentalSerializationApi::class)
@Suppress("TooManyFunctions") // a namespace of pure parse/serialize pairs, one per schema shape — see doc comment above
internal object CurriculumDraftCoding {

    private fun fail(message: String): Nothing = throw CurriculumValidationException(message)

    // ---- value-or-var requireds (fail loud, unlike a silent collapse-to-null, since an
    // authoring/round-trip tool losing data silently is worse than one that throws) ----

    private fun requireIntOrVar(json: JsonElement, context: String): VarOr<Int> {
        if (json is JsonPrimitive && json.isString) {
            val text = json.content
            if (text.startsWith("$")) return VarOr.Ref(text.removePrefix("$"))
            fail("$context: expected an integer or a \$var reference")
        }
        val value = (json as? JsonPrimitive)?.intOrNull ?: fail("$context: expected an integer or a \$var reference")
        return VarOr.Lit(value)
    }

    private fun intOrVarToJson(value: VarOr<Int>): JsonElement =
        when (value) {
            is VarOr.Lit -> JsonPrimitive(value.value)
            is VarOr.Ref -> JsonPrimitive("$" + value.name)
        }

    private fun requireAmountOrVar(json: JsonElement, context: String): VarOr<QuranAmount> {
        if (json is JsonPrimitive && json.isString) {
            val text = json.content
            if (text.startsWith("$")) return VarOr.Ref(text.removePrefix("$"))
            fail("$context: expected a Quran amount or a \$var reference")
        }
        return VarOr.Lit(parseQuranAmount(json, context))
    }

    private fun amountOrVarToJson(value: VarOr<QuranAmount>): JsonElement =
        when (value) {
            is VarOr.Lit -> quranAmountToJson(value.value)
            is VarOr.Ref -> JsonPrimitive("$" + value.name)
        }

    private fun requireWeekdaySetOrVar(json: JsonElement, context: String): VarOr<Set<Weekday>> {
        if (json is JsonPrimitive && json.isString) {
            val text = json.content
            if (text.startsWith("$")) return VarOr.Ref(text.removePrefix("$"))
        }
        if (json is JsonArray && json.isNotEmpty()) {
            val codes = json.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
            if (codes.size == json.size) {
                return VarOr.Lit(codes.map { Weekday.fromCode(it) }.toSet())
            }
        }
        fail("$context: expected a weekday set or a \$var reference")
    }

    private fun weekdaySetOrVarToJson(value: VarOr<Set<Weekday>>): JsonElement =
        when (value) {
            is VarOr.Lit -> JsonArray(value.value.sortedBy { it.ordinal }.map { JsonPrimitive(it.code) })
            is VarOr.Ref -> JsonPrimitive("$" + value.name)
        }

    private fun parseQuranAmount(json: JsonElement, context: String): QuranAmount {
        val obj = json as? JsonObject ?: fail("$context: expected a Quran amount or a \$var reference")
        val unitCode = (obj["unit"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: fail("$context: expected a Quran amount or a \$var reference")
        val unit = runCatching { AmountUnit.fromCode(unitCode) }.getOrElse { fail("$context: unknown unit '$unitCode'") }
        val value = (obj["value"] as? JsonPrimitive)?.takeIf { !it.isString }?.content
            ?: fail("$context: expected a Quran amount or a \$var reference")
        return QuranAmount(unit, value)
    }

    private fun quranAmountToJson(amount: QuranAmount): JsonObject =
        buildJsonObject {
            put("unit", JsonPrimitive(amount.unit.code))
            put("value", JsonUnquotedLiteral(amount.value))
        }

    private fun parseCanonicalRange(json: JsonElement, context: String): CanonicalRange {
        val obj = json as? JsonObject ?: fail("$context: malformed range")
        val surah = (obj["surah"] as? JsonPrimitive)?.intOrNull ?: fail("$context: surah missing")
        val ayahStart = (obj["ayah_start"] as? JsonPrimitive)?.intOrNull ?: fail("$context: ayah_start missing")
        val ayahEnd = (obj["ayah_end"] as? JsonPrimitive)?.intOrNull ?: fail("$context: ayah_end missing")
        return CanonicalRange(surah, ayahStart, ayahEnd)
    }

    private fun canonicalRangeToJson(range: CanonicalRange): JsonObject =
        buildJsonObject {
            put("surah", JsonPrimitive(range.surah))
            put("ayah_start", JsonPrimitive(range.ayahStart))
            put("ayah_end", JsonPrimitive(range.ayahEnd))
        }

    private fun stringMap(obj: JsonObject): Map<String, String> =
        obj.entries.mapNotNull { (key, v) -> (v as? JsonPrimitive)?.takeIf { it.isString }?.content?.let { key to it } }.toMap()

    private fun stringMapToJson(map: Map<String, String>): JsonObject =
        JsonObject(map.mapValues { (_, v) -> JsonPrimitive(v) })

    // ---- Meta ----

    private fun parseMeta(json: JsonElement): MetaDraft {
        val obj = json as? JsonObject ?: fail("meta missing")
        val slug = (obj["slug"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: fail("meta.slug missing")
        val titleObj = obj["title"] as? JsonObject ?: fail("meta.title.ar missing")
        if ((titleObj["ar"] as? JsonPrimitive)?.takeIf { it.isString }?.content == null) fail("meta.title.ar missing")
        val nonNegotiablesArr = obj["non_negotiables"] as? JsonArray ?: fail("meta.non_negotiables missing")
        return MetaDraft(
            slug = slug,
            title = stringMap(titleObj),
            description = (obj["description"] as? JsonObject)?.let { stringMap(it) },
            pedagogyNotes = (obj["pedagogy_notes"] as? JsonObject)?.let { stringMap(it) },
            nonNegotiables = nonNegotiablesArr.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content },
            origin = (obj["origin"] as? JsonPrimitive)?.takeIf { it.isString }?.content,
            licenseNote = (obj["license_note"] as? JsonPrimitive)?.takeIf { it.isString }?.content,
            version = (obj["version"] as? JsonPrimitive)?.takeIf { it.isString }?.content,
            corpora = (obj["corpora"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content },
        )
    }

    private fun metaToJson(meta: MetaDraft): JsonObject =
        buildJsonObject {
            put("slug", JsonPrimitive(meta.slug))
            put("title", stringMapToJson(meta.title))
            put("non_negotiables", JsonArray(meta.nonNegotiables.map { JsonPrimitive(it) }))
            meta.description?.let { put("description", stringMapToJson(it)) }
            meta.pedagogyNotes?.let { put("pedagogy_notes", stringMapToJson(it)) }
            meta.origin?.let { put("origin", JsonPrimitive(it)) }
            meta.licenseNote?.let { put("license_note", JsonPrimitive(it)) }
            meta.version?.let { put("version", JsonPrimitive(it)) }
            meta.corpora?.let { put("corpora", JsonArray(it.map { c -> JsonPrimitive(c) })) }
        }

    // ---- Units ----

    private fun parseUnits(json: JsonElement): UnitsDraft {
        val obj = json as? JsonObject ?: fail("units.allowed missing")
        val allowedArr = obj["allowed"] as? JsonArray ?: fail("units.allowed missing")
        val allowed = allowedArr.map { el ->
            val code = (el as? JsonPrimitive)?.takeIf { it.isString }?.content ?: fail("units.allowed: bad unit")
            runCatching { AmountUnit.fromCode(code) }.getOrElse { fail("units.allowed: bad unit '$code'") }
        }
        val paceJson = obj["default_pace"] ?: fail("units.default_pace missing or malformed")
        return UnitsDraft(allowed = allowed, defaultPace = parseQuranAmount(paceJson, "units.default_pace"))
    }

    private fun unitsToJson(units: UnitsDraft): JsonObject =
        buildJsonObject {
            put("allowed", JsonArray(units.allowed.map { JsonPrimitive(it.code) }))
            put("default_pace", quranAmountToJson(units.defaultPace))
        }

    // ---- Calendar ----

    private fun parseCalendar(json: JsonElement): CalendarDraft {
        val obj = json as? JsonObject ?: fail("calendar missing or malformed")
        val weekStartCode = (obj["week_start"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: fail("calendar missing or malformed")
        val weekStart = runCatching { Weekday.fromCode(weekStartCode) }.getOrElse { fail("calendar missing or malformed") }
        val dayClassesObj = obj["day_classes"] as? JsonObject ?: fail("calendar missing or malformed")
        val dayClasses = dayClassesObj.mapValues { (name, value) ->
            val arr = value as? JsonArray ?: fail("calendar.day_classes.$name not an array")
            arr.map { item ->
                val code = (item as? JsonPrimitive)?.takeIf { it.isString }?.content
                    ?: fail("calendar.day_classes.$name: bad weekday")
                runCatching { Weekday.fromCode(code) }.getOrElse { fail("calendar.day_classes.$name: bad weekday") }
            }
        }
        val exceptionClasses = (obj["exception_classes"] as? JsonArray)
            ?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content } ?: emptyList()
        return CalendarDraft(weekStart, dayClasses, exceptionClasses)
    }

    private fun calendarToJson(calendar: CalendarDraft): JsonObject =
        buildJsonObject {
            put("week_start", JsonPrimitive(calendar.weekStart.code))
            put(
                "day_classes",
                JsonObject(calendar.dayClasses.mapValues { (_, days) -> JsonArray(days.map { JsonPrimitive(it.code) }) }),
            )
            put("exception_classes", JsonArray(calendar.exceptionClasses.map { JsonPrimitive(it) }))
        }

    // ---- Sessions ----

    private fun parseSessionAnchor(json: JsonElement, sessionId: String): SessionAnchorDraft {
        if (json is JsonPrimitive && json.isString && json.content == "fixed") return SessionAnchorDraft.Fixed
        val obj = json as? JsonObject
        val pr = obj?.get("prayer_relative") as? JsonObject
        if (pr != null) {
            val prayer = (pr["prayer"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            val offset = (pr["offset_min"] as? JsonPrimitive)?.intOrNull
            if (prayer != null && offset != null) return SessionAnchorDraft.PrayerRelative(prayer, offset)
        }
        fail("session $sessionId: anchor malformed")
    }

    private fun sessionAnchorToJson(anchor: SessionAnchorDraft): JsonElement =
        when (anchor) {
            SessionAnchorDraft.Fixed -> JsonPrimitive("fixed")
            is SessionAnchorDraft.PrayerRelative ->
                buildJsonObject {
                    put(
                        "prayer_relative",
                        buildJsonObject {
                            put("prayer", JsonPrimitive(anchor.prayer))
                            put("offset_min", JsonPrimitive(anchor.offsetMinutes))
                        },
                    )
                }
        }

    private fun parseSession(json: JsonElement): SessionDraft {
        val obj = json as? JsonObject ?: fail("session missing id")
        val id = (obj["id"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: fail("session missing id")
        val titleObj = obj["title"] as? JsonObject ?: fail("session $id: title missing")
        val defaultTime = (obj["default_time"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: fail("session $id: default_time missing")
        val anchorJson = obj["anchor"] ?: fail("session $id: anchor missing")
        return SessionDraft(id, stringMap(titleObj), defaultTime, parseSessionAnchor(anchorJson, id))
    }

    private fun sessionToJson(session: SessionDraft): JsonObject =
        buildJsonObject {
            put("id", JsonPrimitive(session.id))
            put("title", stringMapToJson(session.title))
            put("default_time", JsonPrimitive(session.defaultTime))
            put("anchor", sessionAnchorToJson(session.anchor))
        }

    // ---- Variables ----

    private fun parseVariable(name: String, json: JsonElement): VariableDraft {
        val obj = json as? JsonObject ?: fail("variable $name malformed")
        val kind = (obj["type"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: fail("variable $name malformed")
        val defaultValue = obj["default"] ?: fail("variable $name malformed")
        return VariableDraft(
            kind = kind,
            defaultValue = defaultValue,
            minimum = (obj["min"] as? JsonPrimitive)?.intOrNull,
            maximum = (obj["max"] as? JsonPrimitive)?.intOrNull,
            enumValues = (obj["values"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content } ?: emptyList(),
            nonNegotiable = (obj["non_negotiable"] as? JsonPrimitive)?.booleanOrNull,
            locked = (obj["locked"] as? JsonPrimitive)?.booleanOrNull,
        )
    }

    private fun variableToJson(variable: VariableDraft): JsonObject =
        buildJsonObject {
            put("type", JsonPrimitive(variable.kind))
            put("default", variable.defaultValue)
            variable.minimum?.let { put("min", JsonPrimitive(it)) }
            variable.maximum?.let { put("max", JsonPrimitive(it)) }
            if (variable.enumValues.isNotEmpty()) put("values", JsonArray(variable.enumValues.map { JsonPrimitive(it) }))
            variable.nonNegotiable?.let { put("non_negotiable", JsonPrimitive(it)) }
            variable.locked?.let { put("locked", JsonPrimitive(it)) }
        }

    // ---- Selectors (mirrors CurriculumLoader.parseSelector, which is `private` there and
    // therefore not callable from here — see this object's own doc comment) ----

    internal fun parseSelectorSpec(json: JsonElement, context: String): SelectorSpecDraft {
        val obj = json as? JsonObject ?: fail("$context: selector must have exactly one kind")
        if (obj.size != 1) fail("$context: selector must have exactly one kind")
        val (kind, bodyEl) = obj.entries.first()
        val body = bodyEl as? JsonObject ?: fail("$context: selector body must be an object")
        return when (kind) {
            "next_new" -> {
                val amountJson = body["amount"] ?: fail("$context: next_new.amount missing")
                SelectorSpecDraft.NextNew(requireAmountOrVar(amountJson, "$context.next_new.amount"))
            }
            "next_content" -> {
                val amountJson = body["amount"] ?: fail("$context: next_content.amount missing")
                SelectorSpecDraft.NextContent(requireAmountOrVar(amountJson, "$context.next_content.amount"))
            }
            "ledger_window" -> {
                val daysJson = body["days"] ?: fail("$context: ledger_window.days missing")
                SelectorSpecDraft.LedgerWindow(
                    days = requireIntOrVar(daysJson, "$context.ledger_window.days"),
                    sundayDays = body["sunday_days"]?.let { requireIntOrVar(it, "$context.ledger_window.sunday_days") },
                )
            }
            "ledger_offset" -> {
                val daysAgoJson = body["days_ago"] ?: fail("$context: ledger_offset.days_ago missing")
                SelectorSpecDraft.LedgerOffset(requireIntOrVar(daysAgoJson, "$context.ledger_offset.days_ago"))
            }
            "week_to_date" -> SelectorSpecDraft.WeekToDate
            "pool_rotation" -> parsePoolRotation(body, context)
            "completed_juz" -> {
                val which = (body["which"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                    ?: fail("$context: completed_juz.which missing")
                SelectorSpecDraft.CompletedJuz(which)
            }
            "prior_hifz_split" -> {
                val partsJson = body["parts"] ?: fail("$context: prior_hifz_split.parts missing")
                SelectorSpecDraft.PriorHifzSplit(requireIntOrVar(partsJson, "$context.prior_hifz_split.parts"))
            }
            "block" -> {
                val juzCountJson = body["juz_count"] ?: fail("$context: block.juz_count missing")
                val which = (body["which"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                    ?: fail("$context: block.which missing")
                SelectorSpecDraft.Block(requireIntOrVar(juzCountJson, "$context.block.juz_count"), which)
            }
            "tomorrow_new" -> SelectorSpecDraft.TomorrowNew
            "fixed" -> {
                val rangeArr = body["range"] as? JsonArray
                if (rangeArr == null || rangeArr.isEmpty()) fail("$context: fixed.range malformed")
                SelectorSpecDraft.Fixed(rangeArr.mapIndexed { i, el -> parseCanonicalRange(el, "$context.fixed.range[$i]") })
            }
            "block_slice" -> {
                val of = (body["of"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                    ?: fail("$context: block_slice.of missing")
                val parts = (body["parts"] as? JsonPrimitive)?.intOrNull
                if (parts == null || parts < 1) fail("$context: block_slice.parts malformed")
                SelectorSpecDraft.BlockSlice(of, parts)
            }
            "intersect_prior_hifz" -> {
                val of = body["of"] ?: fail("$context: intersect_prior_hifz.of missing")
                SelectorSpecDraft.IntersectPriorHifz(
                    parseSelectorRef(of, "$context.intersect_prior_hifz.of"),
                )
            }
            else -> fail("$context: unknown selector kind '$kind'")
        }
    }

    private fun parsePoolRotation(body: JsonObject, context: String): SelectorSpecDraft.PoolRotation {
        val perDayObj = body["per_day"] as? JsonObject ?: fail("$context: pool_rotation.per_day missing")
        val poolJson = body["pool"] ?: fail("$context: pool_rotation.pool missing")
        return SelectorSpecDraft.PoolRotation(
            pool = parsePoolWindow(poolJson, context),
            perDay = parsePerDay(perDayObj, context),
            weakBoost = body["weak_boost"]?.let { requireIntOrVar(it, "$context.pool_rotation.weak_boost") },
        )
    }

    private fun parsePoolWindow(json: JsonElement, context: String): SelectorSpec.PoolWindow {
        if (json is JsonPrimitive && json.isString && json.content == "prior_hifz") return SelectorSpec.PoolWindow.PriorHifz
        val obj = json as? JsonObject ?: fail("$context: pool malformed")
        obj["recent_pages"]?.let { return SelectorSpec.PoolWindow.RecentPages(requireIntOrVar(it, "$context.pool.recent_pages")) }
        obj["recent_juz"]?.let { return SelectorSpec.PoolWindow.RecentJuz(requireIntOrVar(it, "$context.pool.recent_juz")) }
        obj["all_except_recent_pages"]?.let {
            return SelectorSpec.PoolWindow.AllExceptRecentPages(requireIntOrVar(it, "$context.pool.all_except_recent_pages"))
        }
        obj["all_except_recent_juz"]?.let {
            return SelectorSpec.PoolWindow.AllExceptRecentJuz(requireIntOrVar(it, "$context.pool.all_except_recent_juz"))
        }
        fail("$context: pool malformed")
    }

    private fun poolRotationBodyToJson(spec: SelectorSpecDraft.PoolRotation): JsonObject =
        buildJsonObject {
            put("pool", poolWindowToJson(spec.pool))
            put("per_day", perDayToJson(spec.perDay))
            spec.weakBoost?.let { put("weak_boost", intOrVarToJson(it)) }
        }

    private fun poolWindowToJson(pool: SelectorSpec.PoolWindow): JsonElement =
        when (pool) {
            SelectorSpec.PoolWindow.PriorHifz -> JsonPrimitive("prior_hifz")
            is SelectorSpec.PoolWindow.RecentPages -> buildJsonObject { put("recent_pages", intOrVarToJson(pool.count)) }
            is SelectorSpec.PoolWindow.RecentJuz -> buildJsonObject { put("recent_juz", intOrVarToJson(pool.count)) }
            is SelectorSpec.PoolWindow.AllExceptRecentPages ->
                buildJsonObject { put("all_except_recent_pages", intOrVarToJson(pool.count)) }
            is SelectorSpec.PoolWindow.AllExceptRecentJuz ->
                buildJsonObject { put("all_except_recent_juz", intOrVarToJson(pool.count)) }
        }

    private fun parsePerDay(obj: JsonObject, context: String): SelectorSpec.PerDay {
        (obj["ramp"] as? JsonObject)?.let { ramp ->
            val startJson = ramp["start"] ?: fail("$context: ramp malformed")
            val stepJson = ramp["step"] ?: fail("$context: ramp malformed")
            val ceilingJson = ramp["ceiling"] ?: fail("$context: ramp malformed")
            return SelectorSpec.PerDay.Ramp(
                start = requireAmountOrVar(startJson, "$context.ramp.start"),
                step = requireAmountOrVar(stepJson, "$context.ramp.step"),
                ceiling = requireAmountOrVar(ceilingJson, "$context.ramp.ceiling"),
            )
        }
        obj["cycle_days"]?.let { return SelectorSpec.PerDay.CycleDays(requireIntOrVar(it, "$context.per_day.cycle_days")) }
        fail("$context: per_day malformed")
    }

    private fun perDayToJson(perDay: SelectorSpec.PerDay): JsonElement =
        when (perDay) {
            is SelectorSpec.PerDay.Ramp ->
                buildJsonObject {
                    put(
                        "ramp",
                        buildJsonObject {
                            put("start", amountOrVarToJson(perDay.start))
                            put("step", amountOrVarToJson(perDay.step))
                            put("ceiling", amountOrVarToJson(perDay.ceiling))
                        },
                    )
                }
            is SelectorSpec.PerDay.CycleDays -> buildJsonObject { put("cycle_days", intOrVarToJson(perDay.days)) }
        }

    internal fun selectorSpecToJson(spec: SelectorSpecDraft): JsonElement =
        when (spec) {
            is SelectorSpecDraft.NextNew ->
                buildJsonObject { put("next_new", buildJsonObject { put("amount", amountOrVarToJson(spec.amount)) }) }
            is SelectorSpecDraft.NextContent ->
                buildJsonObject { put("next_content", buildJsonObject { put("amount", amountOrVarToJson(spec.amount)) }) }
            is SelectorSpecDraft.LedgerWindow ->
                buildJsonObject {
                    put(
                        "ledger_window",
                        buildJsonObject {
                            put("days", intOrVarToJson(spec.days))
                            spec.sundayDays?.let { put("sunday_days", intOrVarToJson(it)) }
                        },
                    )
                }
            is SelectorSpecDraft.LedgerOffset ->
                buildJsonObject { put("ledger_offset", buildJsonObject { put("days_ago", intOrVarToJson(spec.daysAgo)) }) }
            SelectorSpecDraft.WeekToDate -> buildJsonObject { put("week_to_date", buildJsonObject { }) }
            is SelectorSpecDraft.PoolRotation -> buildJsonObject { put("pool_rotation", poolRotationBodyToJson(spec)) }
            is SelectorSpecDraft.CompletedJuz ->
                buildJsonObject { put("completed_juz", buildJsonObject { put("which", JsonPrimitive(spec.which)) }) }
            is SelectorSpecDraft.PriorHifzSplit ->
                buildJsonObject { put("prior_hifz_split", buildJsonObject { put("parts", intOrVarToJson(spec.parts)) }) }
            is SelectorSpecDraft.Block ->
                buildJsonObject {
                    put(
                        "block",
                        buildJsonObject {
                            put("juz_count", intOrVarToJson(spec.juzCount))
                            put("which", JsonPrimitive(spec.which))
                        },
                    )
                }
            SelectorSpecDraft.TomorrowNew -> buildJsonObject { put("tomorrow_new", buildJsonObject { }) }
            is SelectorSpecDraft.Fixed ->
                buildJsonObject {
                    put("fixed", buildJsonObject { put("range", JsonArray(spec.ranges.map { canonicalRangeToJson(it) })) })
                }
            is SelectorSpecDraft.BlockSlice ->
                buildJsonObject {
                    put(
                        "block_slice",
                        buildJsonObject {
                            put("of", JsonPrimitive(spec.of))
                            put("parts", JsonPrimitive(spec.parts))
                        },
                    )
                }
            is SelectorSpecDraft.IntersectPriorHifz ->
                buildJsonObject {
                    put(
                        "intersect_prior_hifz",
                        buildJsonObject { put("of", selectorRefToJson(spec.of)) },
                    )
                }
        }

    private fun parseSelectorRef(json: JsonElement, context: String): SelectorRefDraft =
        if (json is JsonPrimitive && json.isString) {
            SelectorRefDraft.Named(json.content)
        } else {
            SelectorRefDraft.Inline(parseSelectorSpec(json, context))
        }

    private fun selectorRefToJson(ref: SelectorRefDraft): JsonElement =
        when (ref) {
            is SelectorRefDraft.Named -> JsonPrimitive(ref.name)
            is SelectorRefDraft.Inline -> selectorSpecToJson(ref.spec)
        }

    // ---- Rules ----

    private fun parseRuleWhen(whenObj: JsonObject, ruleId: String): RuleWhenDraft {
        val session = (whenObj["session"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: fail("rule $ruleId: when.session missing")
        val dayClassEl = whenObj["day_class"] ?: fail("rule $ruleId: when.day_class missing")
        val dayClass: DayClassSpec = when {
            dayClassEl is JsonPrimitive && dayClassEl.isString -> DayClassSpec.Single(dayClassEl.content)
            dayClassEl is JsonArray -> {
                val names = dayClassEl.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
                if (names.size != dayClassEl.size || names.isEmpty()) {
                    fail("rule $ruleId: when.day_class array malformed")
                }
                DayClassSpec.Multiple(names)
            }
            else -> fail("rule $ruleId: when.day_class missing")
        }
        val enabledRaw = (whenObj["enabled"] as? JsonPrimitive)?.takeIf { it.isString }?.content
        if (enabledRaw != null && !enabledRaw.startsWith("$")) {
            fail("rule $ruleId: when.enabled must be a \$var ref")
        }
        val enabledVar = enabledRaw?.removePrefix("$")
        val dayIn = whenObj["day_in"]?.let { requireWeekdaySetOrVar(it, "rule $ruleId.when.day_in") }
        val notConditions = (whenObj["not"] as? JsonArray)?.map { item -> parseNotCondition(item, ruleId) } ?: emptyList()
        return RuleWhenDraft(dayClass, session, dayIn, enabledVar, notConditions)
    }

    private fun parseNotCondition(json: JsonElement, ruleId: String): NotConditionDraft {
        if (json is JsonPrimitive && json.isString) {
            return when (json.content) {
                "first_active_day" -> NotConditionDraft.FirstActiveDay
                "in_consolidation_week" -> NotConditionDraft.InConsolidationWeek
                else -> fail("rule $ruleId: unknown not-condition '${json.content}'")
            }
        }
        val flag = (json as? JsonObject)?.get("has_flag") as? JsonPrimitive
        if (flag != null && flag.isString) return NotConditionDraft.HasFlag(flag.content)
        fail("rule $ruleId: bad not-condition")
    }

    private fun notConditionToJson(condition: NotConditionDraft): JsonElement =
        when (condition) {
            NotConditionDraft.FirstActiveDay -> JsonPrimitive("first_active_day")
            NotConditionDraft.InConsolidationWeek -> JsonPrimitive("in_consolidation_week")
            is NotConditionDraft.HasFlag -> buildJsonObject { put("has_flag", JsonPrimitive(condition.name)) }
        }

    private fun dayClassSpecToJson(spec: DayClassSpec): JsonElement =
        when (spec) {
            is DayClassSpec.Single -> JsonPrimitive(spec.name)
            is DayClassSpec.Multiple -> JsonArray(spec.classNames.map { JsonPrimitive(it) })
        }

    private fun ruleWhenToJson(whenSpec: RuleWhenDraft): JsonObject =
        buildJsonObject {
            put("day_class", dayClassSpecToJson(whenSpec.dayClass))
            put("session", JsonPrimitive(whenSpec.session))
            whenSpec.dayIn?.let { put("day_in", weekdaySetOrVarToJson(it)) }
            whenSpec.enabledVar?.let { put("enabled", JsonPrimitive("$" + it)) }
            if (whenSpec.notConditions.isNotEmpty()) {
                put("not", JsonArray(whenSpec.notConditions.map { notConditionToJson(it) }))
            }
        }

    private fun parseRuleEmit(emitObj: JsonObject, ruleId: String): RuleEmitDraft {
        val type = (emitObj["type"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?: fail("rule $ruleId: emit.type missing")
        val ordering = (emitObj["ordering"] as? JsonPrimitive)?.intOrNull ?: fail("rule $ruleId: emit.ordering missing")
        val window = (emitObj["window"] as? JsonObject)?.let { w ->
            val opensCode = (w["opens"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                ?: fail("rule $ruleId: emit.window malformed")
            val closesCode = (w["closes"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                ?: fail("rule $ruleId: emit.window malformed")
            val opens = runCatching { Weekday.fromCode(opensCode) }.getOrElse { fail("rule $ruleId: emit.window malformed") }
            val closes = runCatching { Weekday.fromCode(closesCode) }.getOrElse { fail("rule $ruleId: emit.window malformed") }
            RuleWindowDraft(opens, closes)
        }
        return RuleEmitDraft(
            type = type,
            select = emitObj["select"]?.let { parseSelectorRef(it, "rule $ruleId.select") },
            repetitions = emitObj["repetitions"]?.let { requireIntOrVar(it, "rule $ruleId.repetitions") },
            spacingMinutes = emitObj["spacing_minutes"]?.let { requireIntOrVar(it, "rule $ruleId.spacing_minutes") },
            listenCount = emitObj["listen_count"]?.let { requireIntOrVar(it, "rule $ruleId.listen_count") },
            window = window,
            infoOnly = (emitObj["info_only"] as? JsonPrimitive)?.booleanOrNull,
            ordering = ordering,
            label = (emitObj["label"] as? JsonObject)?.let { stringMap(it) },
            estMinutes = (emitObj["est_minutes"] as? JsonPrimitive)?.intOrNull,
        )
    }

    private fun ruleEmitToJson(emit: RuleEmitDraft): JsonObject =
        buildJsonObject {
            put("type", JsonPrimitive(emit.type))
            put("ordering", JsonPrimitive(emit.ordering))
            emit.select?.let { put("select", selectorRefToJson(it)) }
            emit.repetitions?.let { put("repetitions", intOrVarToJson(it)) }
            emit.spacingMinutes?.let { put("spacing_minutes", intOrVarToJson(it)) }
            emit.listenCount?.let { put("listen_count", intOrVarToJson(it)) }
            emit.window?.let { w ->
                put("window", buildJsonObject { put("opens", JsonPrimitive(w.opens.code)); put("closes", JsonPrimitive(w.closes.code)) })
            }
            emit.infoOnly?.let { put("info_only", JsonPrimitive(it)) }
            emit.label?.let { put("label", stringMapToJson(it)) }
            emit.estMinutes?.let { put("est_minutes", JsonPrimitive(it)) }
        }

    internal fun parseRule(json: JsonElement): RuleSpecDraft {
        val obj = json as? JsonObject ?: fail("rule missing id")
        val id = (obj["id"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: fail("rule missing id")
        val whenObj = obj["when"] as? JsonObject ?: fail("rule $id: when missing")
        val emitObj = obj["emit"] as? JsonObject ?: fail("rule $id: emit missing")
        return RuleSpecDraft(
            id = id,
            whenSpec = parseRuleWhen(whenObj, id),
            emit = parseRuleEmit(emitObj, id),
            explanation = (obj["explanation"] as? JsonObject)?.let { stringMap(it) },
            suppressedBy = (obj["suppressed_by"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content } ?: emptyList(),
        )
    }

    internal fun ruleToJson(rule: RuleSpecDraft): JsonObject =
        buildJsonObject {
            put("id", JsonPrimitive(rule.id))
            put("when", ruleWhenToJson(rule.whenSpec))
            put("emit", ruleEmitToJson(rule.emit))
            rule.explanation?.let { put("explanation", stringMapToJson(it)) }
            if (rule.suppressedBy.isNotEmpty()) put("suppressed_by", JsonArray(rule.suppressedBy.map { JsonPrimitive(it) }))
        }

    // ---- Triggers ----

    private fun parseTriggerOn(json: JsonElement, triggerId: String): TriggerOn {
        val onObj = json as? JsonObject ?: fail("trigger $triggerId: on missing")
        (onObj["boundary"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.let { boundary ->
            val every = onObj["every"]?.let { requireIntOrVar(it, "trigger $triggerId.on.every") }
            return TriggerOn(boundary = boundary, every = every)
        }
        onObj["cursor_reaches"]?.let { reach ->
            return TriggerOn(cursorReaches = parseCanonicalRange(reach, "trigger $triggerId.on.cursor_reaches"))
        }
        ((onObj["task_failed"] as? JsonObject)?.get("rule") as? JsonPrimitive)?.takeIf { it.isString }?.content?.let { rule ->
            return TriggerOn(taskFailed = rule)
        }
        fail("trigger $triggerId: on malformed")
    }

    private fun triggerOnToJson(on: TriggerOn): JsonElement =
        when {
            on.boundary != null ->
                buildJsonObject {
                    put("boundary", JsonPrimitive(on.boundary))
                    on.every?.let { put("every", intOrVarToJson(it)) }
                }
            on.cursorReaches != null -> buildJsonObject { put("cursor_reaches", canonicalRangeToJson(on.cursorReaches)) }
            on.taskFailed != null ->
                buildJsonObject { put("task_failed", buildJsonObject { put("rule", JsonPrimitive(on.taskFailed)) }) }
            else -> fail("trigger on: none of boundary/cursor_reaches/task_failed set")
        }

    private fun parseTriggerEffect(json: JsonElement, triggerId: String): TriggerEffectDraft {
        val effectObj = json as? JsonObject ?: fail("trigger $triggerId: effect malformed")
        if (effectObj.size != 1) fail("trigger $triggerId: effect malformed")
        val (kind, bodyEl) = effectObj.entries.first()
        return when (kind) {
            "schedule" -> {
                val bodyObj = bodyEl as? JsonObject ?: fail("trigger $triggerId: schedule malformed")
                val type = (bodyObj["type"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                    ?: fail("trigger $triggerId: schedule malformed")
                val selectJson = bodyObj["select"] ?: fail("trigger $triggerId: schedule malformed")
                TriggerEffectDraft.Schedule(
                    ScheduleEffectDraft(
                        type = type,
                        select = parseSelectorRef(selectJson, "trigger $triggerId.schedule.select"),
                        distributeOverDays = (bodyObj["distribute_over_days"] as? JsonPrimitive)?.intOrNull,
                        intoSession = (bodyObj["into_session"] as? JsonPrimitive)?.takeIf { it.isString }?.content,
                        starting = (bodyObj["starting"] as? JsonPrimitive)?.takeIf { it.isString }?.content,
                        label = (bodyObj["label"] as? JsonObject)?.let { stringMap(it) },
                        estMinutes = (bodyObj["est_minutes"] as? JsonPrimitive)?.intOrNull,
                    ),
                )
            }
            "insert_week" -> {
                val bodyObj = bodyEl as? JsonObject ?: fail("trigger $triggerId: insert_week malformed")
                val name = (bodyObj["name"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                    ?: fail("trigger $triggerId: insert_week malformed")
                val rulesArr = bodyObj["day_rules"] as? JsonArray ?: fail("trigger $triggerId: insert_week malformed")
                TriggerEffectDraft.InsertWeek(
                    InsertWeekEffectDraft(
                        name = name,
                        modeVar = (bodyObj["mode_var"] as? JsonPrimitive)?.takeIf { it.isString }?.content,
                        dayRules = rulesArr.map { parseRule(it) },
                    ),
                )
            }
            "set_flag" -> {
                val bodyObj = bodyEl as? JsonObject ?: fail("trigger $triggerId: set_flag malformed")
                val name = (bodyObj["name"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                    ?: fail("trigger $triggerId: set_flag malformed")
                TriggerEffectDraft.SetFlag(name, (bodyObj["until"] as? JsonPrimitive)?.takeIf { it.isString }?.content)
            }
            "clear_flag" -> {
                val bodyObj = bodyEl as? JsonObject ?: fail("trigger $triggerId: clear_flag malformed")
                val name = (bodyObj["name"] as? JsonPrimitive)?.takeIf { it.isString }?.content
                    ?: fail("trigger $triggerId: clear_flag malformed")
                TriggerEffectDraft.ClearFlag(name)
            }
            "complete_plan" -> TriggerEffectDraft.CompletePlan
            else -> fail("trigger $triggerId: unknown effect '$kind'")
        }
    }

    private fun triggerEffectToJson(effect: TriggerEffectDraft): JsonElement =
        when (effect) {
            is TriggerEffectDraft.Schedule -> {
                val s = effect.effect
                buildJsonObject {
                    put(
                        "schedule",
                        buildJsonObject {
                            put("type", JsonPrimitive(s.type))
                            put("select", selectorRefToJson(s.select))
                            s.distributeOverDays?.let { put("distribute_over_days", JsonPrimitive(it)) }
                            s.intoSession?.let { put("into_session", JsonPrimitive(it)) }
                            s.starting?.let { put("starting", JsonPrimitive(it)) }
                            s.label?.let { put("label", stringMapToJson(it)) }
                            s.estMinutes?.let { put("est_minutes", JsonPrimitive(it)) }
                        },
                    )
                }
            }
            is TriggerEffectDraft.InsertWeek -> {
                val w = effect.effect
                buildJsonObject {
                    put(
                        "insert_week",
                        buildJsonObject {
                            put("name", JsonPrimitive(w.name))
                            put("day_rules", JsonArray(w.dayRules.map { ruleToJson(it) }))
                            w.modeVar?.let { put("mode_var", JsonPrimitive(it)) }
                        },
                    )
                }
            }
            is TriggerEffectDraft.SetFlag ->
                buildJsonObject {
                    put(
                        "set_flag",
                        buildJsonObject {
                            put("name", JsonPrimitive(effect.name))
                            effect.until?.let { put("until", JsonPrimitive(it)) }
                        },
                    )
                }
            is TriggerEffectDraft.ClearFlag ->
                buildJsonObject { put("clear_flag", buildJsonObject { put("name", JsonPrimitive(effect.name)) }) }
            TriggerEffectDraft.CompletePlan -> buildJsonObject { put("complete_plan", buildJsonObject { }) }
        }

    private fun parseTrigger(json: JsonElement): TriggerSpecDraft {
        val obj = json as? JsonObject ?: fail("trigger missing id")
        val id = (obj["id"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: fail("trigger missing id")
        val onJson = obj["on"] ?: fail("trigger $id: on missing")
        val effects = (obj["effects"] as? JsonArray ?: JsonArray(emptyList())).map { parseTriggerEffect(it, id) }
        return TriggerSpecDraft(id, parseTriggerOn(onJson, id), effects)
    }

    private fun triggerToJson(trigger: TriggerSpecDraft): JsonObject =
        buildJsonObject {
            put("id", JsonPrimitive(trigger.id))
            put("on", triggerOnToJson(trigger.on))
            put("effects", JsonArray(trigger.effects.map { triggerEffectToJson(it) }))
        }

    // ---- Recovery / Advancement / Forecast ----

    private fun parseRecovery(json: JsonElement): RecoveryDraft {
        val obj = json as? JsonObject ?: fail("recovery malformed")
        val policiesArr = obj["allowed_policies"] as? JsonArray ?: fail("recovery malformed")
        val defaultPolicy = (obj["default"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: fail("recovery malformed")
        val escalationDays = (obj["escalation_days"] as? JsonPrimitive)?.intOrNull ?: fail("recovery malformed")
        val policies = policiesArr.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
        if (policies.size != policiesArr.size) fail("recovery.allowed_policies malformed")
        return RecoveryDraft(policies, defaultPolicy, escalationDays)
    }

    private fun recoveryToJson(recovery: RecoveryDraft): JsonObject =
        buildJsonObject {
            put("allowed_policies", JsonArray(recovery.allowedPolicies.map { JsonPrimitive(it) }))
            put("default", JsonPrimitive(recovery.defaultPolicy))
            put("escalation_days", JsonPrimitive(recovery.escalationDays))
        }

    private fun parseAdvancement(json: JsonElement): AdvancementDraft {
        val obj = json as? JsonObject ?: fail("advancement malformed")
        return AdvancementDraft((obj["require_verified"] as? JsonPrimitive)?.booleanOrNull)
    }

    private fun advancementToJson(advancement: AdvancementDraft): JsonObject =
        buildJsonObject { advancement.requireVerified?.let { put("require_verified", JsonPrimitive(it)) } }

    private fun parseForecast(json: JsonElement): ForecastDraft {
        val obj = json as? JsonObject ?: fail("forecast missing or malformed")
        val rates = obj["workload_rates"] as? JsonObject ?: fail("forecast missing or malformed")
        val factors = obj["strength_factors"] as? JsonObject ?: fail("forecast missing or malformed")
        return ForecastDraft(rates, factors)
    }

    private fun forecastToJson(forecast: ForecastDraft): JsonObject =
        buildJsonObject {
            put("workload_rates", JsonObject(forecast.workloadRates))
            put("strength_factors", JsonObject(forecast.strengthFactors))
        }

    // ---- Root document ----

    fun parseDocument(json: JsonElement): CurriculumDraft {
        val root = json as? JsonObject ?: fail("root is not an object")

        val meta = parseMeta(root["meta"] ?: fail("meta missing"))
        val units = parseUnits(root["units"] ?: fail("units missing"))
        val calendar = parseCalendar(root["calendar"] ?: fail("calendar missing"))

        val sessionsArr = root["sessions"] as? JsonArray
        if (sessionsArr == null || sessionsArr.isEmpty()) fail("sessions missing")
        val sessions = sessionsArr.map { parseSession(it) }

        val variables = (root["variables"] as? JsonObject ?: JsonObject(emptyMap())).entries
            .associate { (name, defJson) -> name to parseVariable(name, defJson) }

        val selectors = (root["selectors"] as? JsonObject ?: JsonObject(emptyMap())).entries
            .associate { (name, specJson) -> name to parseSelectorSpec(specJson, "selectors.$name") }

        val taskDeduplicationMode = (root["task_deduplication"] as? JsonObject)
            ?.get("mode")?.let {
                (it as? JsonPrimitive)?.takeIf { primitive -> primitive.isString }?.content
                    ?: fail("task_deduplication.mode malformed")
            }

        val rulesArr = root["rules"] as? JsonArray
        if (rulesArr == null || rulesArr.isEmpty()) fail("rules must not be empty")
        val rules = rulesArr.map { parseRule(it) }

        val triggers = (root["triggers"] as? JsonArray ?: JsonArray(emptyList())).map { parseTrigger(it) }

        val recovery = root["recovery"]?.let { parseRecovery(it) }
        val advancement = root["advancement"]?.let { parseAdvancement(it) }
        val evidenceDefaults = root["evidence_defaults"] as? JsonObject

        val forecast = parseForecast(root["forecast"] ?: fail("forecast missing"))

        return CurriculumDraft(
            meta = meta,
            units = units,
            calendar = calendar,
            sessions = sessions,
            variables = variables,
            selectors = selectors,
            taskDeduplicationMode = taskDeduplicationMode,
            rules = rules,
            triggers = triggers,
            recovery = recovery,
            advancement = advancement,
            evidenceDefaults = evidenceDefaults,
            forecast = forecast,
        )
    }

    fun documentToJson(draft: CurriculumDraft): JsonObject {
        val obj = LinkedHashMap<String, JsonElement>()
        obj["meta"] = metaToJson(draft.meta)
        obj["units"] = unitsToJson(draft.units)
        obj["calendar"] = calendarToJson(draft.calendar)
        obj["sessions"] = JsonArray(draft.sessions.map { sessionToJson(it) })
        obj["variables"] = JsonObject(draft.variables.mapValues { (_, v) -> variableToJson(v) })
        obj["selectors"] = JsonObject(draft.selectors.mapValues { (_, v) -> selectorSpecToJson(v) })
        draft.taskDeduplicationMode?.let { mode ->
            obj["task_deduplication"] = buildJsonObject { put("mode", JsonPrimitive(mode)) }
        }
        obj["rules"] = JsonArray(draft.rules.map { ruleToJson(it) })
        obj["triggers"] = JsonArray(draft.triggers.map { triggerToJson(it) })
        obj["forecast"] = forecastToJson(draft.forecast)
        draft.recovery?.let { obj["recovery"] = recoveryToJson(it) }
        draft.advancement?.let { obj["advancement"] = advancementToJson(it) }
        draft.evidenceDefaults?.let { obj["evidence_defaults"] = JsonObject(it) }
        return JsonObject(obj)
    }
}
