package masoon.curriculum

import kotlinx.serialization.json.JsonElement
import masoon.domain.AmountUnit
import masoon.domain.CanonicalRange
import masoon.domain.QuranAmount
import masoon.domain.Weekday

/**
 * B7-WaveC (MasoonAuthoring port): a typed, EDITABLE model of a `curriculum-v1` document
 * (`contracts/json-schema/curriculum-v1.schema.json`), for the (Batch 9+) on-device curriculum
 * builder UI. Kotlin port of `apps/ios/Packages/Sources/MasoonCurriculum/CurriculumDraft.swift`.
 *
 * [CompiledCurriculum] (`CompiledCurriculum.kt`) is the engine's READ-ONLY, execution-shaped view
 * of a curriculum: its loader ([CurriculumLoader]) drops every field the engine itself never
 * consumes (`meta.title`/`description`/`pedagogy_notes`/`origin`/`license_note`/`version`/
 * `corpora`, `Session.anchor`, `Recovery.allowedPolicies`, `Advancement`, and more) and collapses
 * a few JSON *shapes* the engine doesn't need to distinguish (`RuleWhen.day_class` as a bare
 * string vs. a single-element array both become `List<String>`; a `TriggerEffect.Schedule`'s
 * optional `starting` field is filled with its D-028(5) default and the "was it authored
 * explicitly" bit is lost; `SelectorSpec.PoolRotation.weakBoost` is default-filled to `1` when
 * absent). None of that is a bug in [CompiledCurriculum] — it is exactly the reduction the ENGINE
 * wants — but it makes [CompiledCurriculum] unusable as the backing model for an editor that must
 * reproduce a curriculum's JSON losslessly (round-tripping an authored document through a builder
 * UI must not silently rewrite `"day_class": "weekday"` into `"day_class": ["weekday"]`, drop an
 * author's `meta.description`, or turn an omitted `starting`/`weak_boost` key into an explicit
 * one).
 *
 * `CurriculumDraft` is therefore a SEPARATE model, not a mutable wrapper of [CompiledCurriculum].
 * Design approach (mirrors the Swift source's own header):
 *   - Every leaf DSL vocabulary type that [CompiledCurriculum] already got right for
 *     round-tripping — [VarOr] (Swift's `IntOrVar`/`AmountOrVar`, used here as `VarOr<Int>` /
 *     `VarOr<QuranAmount>` respectively; also reused as `VarOr<Set<Weekday>>` for Swift's
 *     `WeekdaySetOrVar` — Kotlin never declared that leaf as its own type, so the generic
 *     `VarOr<T>` already used for the other two stands in directly), [SelectorSpec.PoolWindow],
 *     [SelectorSpec.PerDay], [SelectorRef] (used by wrapping, see [SelectorRefDraft] below),
 *     [TriggerOn], plus `masoon.domain`'s [Weekday]/[AmountUnit]/[QuranAmount]/[CanonicalRange] —
 *     is REUSED directly, not reinvented, via their existing public constructors/cases.
 *   - Every container the loader collapses or default-fills gets its own `...Draft` type here,
 *     field-compatible in spirit but nullable wherever the schema allows the key to be absent, so
 *     "absent" and "present with the default value" stay distinguishable through a parse -> edit
 *     -> serialize round trip: [RuleWhenDraft] (`day_class` shape via [DayClassSpec]),
 *     [RuleEmitDraft] (`info_only`'s absent-vs-`false`), [ScheduleEffectDraft]
 *     (`starting`'s absent-vs-default).
 *   - **One deliberate, documented departure from "reuse [SelectorSpec] directly" for the whole
 *     selector algebra**: [CompiledCurriculum]'s `SelectorSpec.PoolRotation.weakBoost` is typed
 *     as a plain non-null `Int`, default-filled to `1` by [CurriculumLoader] when `weak_boost` is
 *     absent (`CurriculumLoader.kt`: `body["weak_boost"]?.jsonPrimitive?.intOrNull ?: 1`) — unlike
 *     Swift's own `CompiledCurriculum.SelectorSpec.poolRotation(weakBoost: IntOrVar?)`, which
 *     stays optional. Reusing Kotlin's `SelectorSpec` verbatim here would silently reintroduce an
 *     explicit `"weak_boost": 1` into `toDocument()`'s output for every curriculum that omits the
 *     key — 12 of the 15 built-ins that author `pool_rotation` do exactly that (verified against
 *     the compiled JSON under `contracts/curricula`), which would fail this port's own
 *     round-trip-fidelity bar for the majority of the corpus, not an edge case. [SelectorSpecDraft] is therefore a
 *     fresh sealed type mirroring [SelectorSpec] case-for-case, reusing [SelectorSpec.PoolWindow]
 *     and [SelectorSpec.PerDay] directly (those two nested leaves have no such collapse) and
 *     fixing only `PoolRotation.weakBoost` to `VarOr<Int>?`. Every other case matches
 *     [CompiledCurriculum]'s [SelectorSpec] field-for-field.
 *   - `NotCondition` has no Kotlin equivalent to reuse either: [CompiledCurriculum]'s
 *     `RuleWhen.not` is a plain `List<String>` that assumes every item is a bare string and would
 *     throw a `ClassCastException` on the schema-legal `{"has_flag": "..."}` object shape. This
 *     port introduces [NotConditionDraft] (a real 3-case sealed type, including `HasFlag`) fresh,
 *     matching Swift's `NotCondition`, without touching [CompiledCurriculum]'s own `RuleWhen`.
 *   - Every field the loader has no reason to touch at all (`meta.title`, `Session.anchor`,
 *     `Recovery`, `Advancement`, ...) is modeled fresh, straight off the schema.
 *
 * See `CurriculumDraftDocument.kt` for `CurriculumDraft.fromDocument(json)` / `.toDocument()` (the
 * JSON round trip) and `CurriculumDraftTest.kt` for the round-trip proof against real built-ins.
 */

// ---------- Meta ----------

/** `curriculum-v1.schema.json` `$defs/Meta`. */
data class MetaDraft(
    val slug: String,
    /** Required by schema (`LocalizedText.ar` is required); `en` optional. */
    val title: Map<String, String>,
    val description: Map<String, String>? = null,
    val pedagogyNotes: Map<String, String>? = null,
    /** Required key; may be an empty list (e.g. `deobandi`'s draft has none). */
    val nonNegotiables: List<String> = emptyList(),
    val origin: String? = null,
    val licenseNote: String? = null,
    /**
     * `null` means the key is ABSENT from the document — the schema's own stated default is
     * "1.0.0" (PC-2), but applying that default is a CONSUMER concern, not this model's: filling
     * it in here would turn an unauthored field into an authored one and break the round trip.
     */
    val version: String? = null,
    val corpora: List<String>? = null,
)

// ---------- Units ----------

/** `curriculum-v1.schema.json` `$defs/Units`. */
data class UnitsDraft(
    val allowed: List<AmountUnit>,
    val defaultPace: QuranAmount,
)

// ---------- Calendar ----------

/** `curriculum-v1.schema.json` `$defs/Calendar`. */
data class CalendarDraft(
    val weekStart: Weekday,
    /**
     * day-class name -> weekdays, in AUTHORED ORDER. [CompiledCurriculum.CalendarSpec] uses
     * `Map<String, List<Weekday>>` too (not a `Set`) so this already matches — kept as its own
     * field here rather than reused wholesale because [CalendarDraft] additionally needs
     * [exceptionClasses], which [CompiledCurriculum.CalendarSpec] also already carries; the two
     * types just happen to be structurally identical today.
     */
    val dayClasses: Map<String, List<Weekday>>,
    /** Required key; may be an empty list. */
    val exceptionClasses: List<String> = emptyList(),
)

// ---------- Sessions ----------

/**
 * `Session.anchor` (`curriculum-v1.schema.json` `$defs/SessionAnchor`). [CompiledCurriculum]
 * doesn't parse this at all today (no engine rule consumes it yet); a draft must still round-trip
 * it.
 */
sealed interface SessionAnchorDraft {
    data object Fixed : SessionAnchorDraft

    data class PrayerRelative(val prayer: String, val offsetMinutes: Int) : SessionAnchorDraft
}

/** `curriculum-v1.schema.json` `$defs/Session`. */
data class SessionDraft(
    val id: String,
    val title: Map<String, String>,
    /**
     * Raw `"HH:mm"` text; format is schema/gate-1's concern, not this model's — a draft mid-edit
     * may transiently hold an invalid time.
     */
    val defaultTime: String,
    val anchor: SessionAnchorDraft,
)

// ---------- Variables ----------

/** `curriculum-v1.schema.json` `$defs/VariableDef`. */
data class VariableDraft(
    /**
     * Raw `type` string (`"int" | "bool" | "amount" | "weekday_set" | "enum"`), exactly like
     * [CompiledCurriculum.VariableDef.type] — Kotlin never declared a closed `Kind` enum for this
     * the way Swift's `VariableDef.Kind` does, so a plain `String` is the actual leaf type to
     * reuse here.
     */
    val kind: String,
    /**
     * Raw, exactly like [CompiledCurriculum.VariableDef.default]'s underlying JSON — the shape
     * varies by [kind] (number/bool/string/weekday array/amount object) and [JsonElement] is
     * already a lossless carrier for all of them, so there is nothing to gain (and real precision
     * to lose — see `CurriculumDraftDocument.kt`'s header) by decomposing further.
     */
    val defaultValue: JsonElement,
    val minimum: Int? = null,
    val maximum: Int? = null,
    /**
     * Only meaningful for `kind == "enum"`; empty when unused (never emits a `values` key on
     * serialization either way — the schema requires `values` to be non-empty when present).
     */
    val enumValues: List<String> = emptyList(),
    val nonNegotiable: Boolean? = null,
    val locked: Boolean? = null,
)

// ---------- Rules ----------

/**
 * `RuleWhen.day_class` (`curriculum-v1.schema.json`) is `oneOf [Identifier, array<Identifier>]` —
 * a real authoring distinction (most `wifaq` rules author a bare `"day_class": "weekday"`; some
 * curricula author `["weekday","saturday"]`, e.g. `masoon_method`'s `listen` rule).
 * [CompiledCurriculum.RuleWhen.dayClasses]: `List<String>` collapses both shapes into a list,
 * which is correct for the engine (it only ever needs `.contains`) but would rewrite every
 * bare-string rule into a single-element array on serialization.
 */
sealed interface DayClassSpec {
    data class Single(val name: String) : DayClassSpec

    data class Multiple(val classNames: List<String>) : DayClassSpec

    val names: List<String>
        get() =
            when (this) {
                is Single -> listOf(name)
                is Multiple -> classNames
            }
}

/**
 * `NotCondition` (`curriculum-v1.schema.json` `$defs/NotCondition`). No Kotlin equivalent exists
 * to reuse: [CompiledCurriculum.RuleWhen.not] is a plain `List<String>` built by
 * `whenO["not"]?.jsonArray?.map { it.jsonPrimitive.content }` (`CurriculumLoader.kt`), which
 * would throw a `ClassCastException` on the schema-legal `{"has_flag": "..."}` object shape
 * rather than silently dropping it — this port fixes that for the Draft model without touching
 * [CompiledCurriculum]'s own `RuleWhen`.
 */
sealed interface NotConditionDraft {
    data object FirstActiveDay : NotConditionDraft

    data object InConsolidationWeek : NotConditionDraft

    data class HasFlag(val name: String) : NotConditionDraft
}

data class RuleWhenDraft(
    val dayClass: DayClassSpec,
    val session: String,
    /**
     * Schema types `RuleWhen.day_in` as `VarRef` ONLY (never a literal weekday array) —
     * `VarOr<Set<Weekday>>` is reused anyway (mirrors Swift's `WeekdaySetOrVar`) because it is
     * already exactly the right leaf shape; its `VarOr.Lit` case is simply unreachable for any
     * schema-valid document.
     */
    val dayIn: VarOr<Set<Weekday>>? = null,
    /**
     * Variable NAME only (no `$`), matching [CompiledCurriculum.RuleWhen.enabled].
     */
    val enabledVar: String? = null,
    /**
     * Empty when the `not` key is absent — schema requires `minItems: 1` when present, so
     * "absent" and "empty" can never both be legal, making this the same safe collapse
     * [CompiledCurriculum] already uses for its own (narrower) `not` field.
     */
    val notConditions: List<NotConditionDraft> = emptyList(),
)

/**
 * `RuleEmit.window` (`curriculum-v1.schema.json` `$defs/TaskWindow`). A small named type rather
 * than [CompiledCurriculum.TaskWindowSpec]'s bare two fields inline — friendlier for a future
 * builder-UI form binding two `Weekday` pickers, matching the Swift source's own reasoning for
 * introducing `RuleWindowDraft` instead of reusing `TaskWindowSpec` (which this port structurally
 * matches field-for-field anyway; either name would do).
 */
data class RuleWindowDraft(val opens: Weekday, val closes: Weekday)

data class RuleEmitDraft(
    /**
     * Raw `TaskType` string, exactly like [CompiledCurriculum.RuleEmit.type] (not decomposed into
     * a closed Kotlin enum there either).
     */
    val type: String,
    val select: SelectorRefDraft? = null,
    val repetitions: VarOr<Int>? = null,
    val spacingMinutes: VarOr<Int>? = null,
    val listenCount: VarOr<Int>? = null,
    val window: RuleWindowDraft? = null,
    /**
     * `null` = key absent. [CompiledCurriculum.RuleEmit.infoOnly]: `Boolean` default-fills absent
     * to `false`; none of the 15 built-ins ever author an explicit `"info_only": false` (only
     * `true`, twice), so that collapse happens to be safe for them, but this model keeps the bit
     * anyway rather than relying on that never happening.
     */
    val infoOnly: Boolean? = null,
    val ordering: Int,
    val label: Map<String, String>? = null,
    val estMinutes: Int? = null,
)

data class RuleSpecDraft(
    val id: String,
    /** Named `whenSpec`, not `when` (Kotlin keyword) — mirrors [CompiledCurriculum.RuleSpec]'s own field name. */
    val whenSpec: RuleWhenDraft,
    val emit: RuleEmitDraft,
    val explanation: Map<String, String>? = null,
    /** Empty when the `suppressed_by` key is absent (same "empty is never separately legal" argument as [RuleWhenDraft.notConditions]). */
    val suppressedBy: List<String> = emptyList(),
)

// ---------- Selectors ----------

/**
 * `curriculum-v1.schema.json` `$defs/SelectorSpec`, the closed 10-case selector algebra. A fresh
 * sealed type rather than a direct reuse of [SelectorSpec] — see this file's header for exactly
 * why (`PoolRotation.weakBoost` is the one field [CompiledCurriculum] default-fills that a
 * lossless draft cannot). Every OTHER case matches [SelectorSpec] field-for-field, and the two
 * nested leaf algebras ([SelectorSpec.PoolWindow], [SelectorSpec.PerDay]) are reused directly,
 * unmodified.
 */
sealed interface SelectorSpecDraft {
    data class NextNew(val amount: VarOr<QuranAmount>) : SelectorSpecDraft

    data class NextContent(val amount: VarOr<QuranAmount>) : SelectorSpecDraft

    data class LedgerWindow(val days: VarOr<Int>, val sundayDays: VarOr<Int>? = null) : SelectorSpecDraft

    /** E-2 (D-039): the new-ḥifẓ ledger of exactly one prior day (D − daysAgo). */
    data class LedgerOffset(val daysAgo: VarOr<Int>) : SelectorSpecDraft

    data object WeekToDate : SelectorSpecDraft

    data class PoolRotation(
        val pool: SelectorSpec.PoolWindow,
        val perDay: SelectorSpec.PerDay,
        /**
         * `null` = key absent. See this file's header — this is the one field this port
         * deliberately does NOT collapse to [CompiledCurriculum.SelectorSpec.PoolRotation]'s
         * always-present `Int` (default-filled to `1` at load time).
         */
        val weakBoost: VarOr<Int>? = null,
    ) : SelectorSpecDraft

    data class CompletedJuz(val which: String) : SelectorSpecDraft

    data class PriorHifzSplit(val parts: VarOr<Int>) : SelectorSpecDraft

    data class Block(val juzCount: VarOr<Int>, val which: String) : SelectorSpecDraft

    data object TomorrowNew : SelectorSpecDraft

    data class Fixed(val ranges: List<CanonicalRange>) : SelectorSpecDraft

    /** Inline in consolidation-week day rules: one near-equal slice of another selector's block. */
    data class BlockSlice(val of: String, val parts: Int) : SelectorSpecDraft

    data class IntersectPriorHifz(val of: SelectorRefDraft) : SelectorSpecDraft
}

/**
 * A named selector reference or an inline selector (consolidation-week `block_slice`). Wraps
 * [SelectorSpecDraft] rather than [CompiledCurriculum.SelectorSpec] for the same reason
 * [SelectorSpecDraft] exists at all — an inline `pool_rotation` selector would hit the identical
 * `weak_boost` collapse otherwise.
 */
sealed interface SelectorRefDraft {
    data class Named(val name: String) : SelectorRefDraft

    data class Inline(val spec: SelectorSpecDraft) : SelectorRefDraft
}

// ---------- Triggers ----------

data class ScheduleEffectDraft(
    val type: String,
    val select: SelectorRefDraft,
    val distributeOverDays: Int? = null,
    val intoSession: String? = null,
    /**
     * `null` = key absent. The schema types this as `const "next_active_day"` (D-028(5)) — the
     * ONLY legal explicit value — but two of the real built-ins disagree on whether to author it
     * at all (`masoon_method`'s `end_of_juz` trigger writes it explicitly on one `schedule`
     * effect and omits it on the very next one — verified against
     * `contracts/curricula/masoon_method.compiled.json`), so this stays nullable rather than
     * collapsing to [CompiledCurriculum.TriggerEffect.Schedule]'s always-present `starting: String`
     * (default-filled at load time, D-028(5)).
     */
    val starting: String? = null,
    val label: Map<String, String>? = null,
    val estMinutes: Int? = null,
)

data class InsertWeekEffectDraft(
    val name: String,
    val modeVar: String? = null,
    /** May legitimately be empty (schema `minItems: 0`) — a pure pause week (E-5/D-047) adds no rules of its own. */
    val dayRules: List<RuleSpecDraft> = emptyList(),
)

sealed interface TriggerEffectDraft {
    data class Schedule(val effect: ScheduleEffectDraft) : TriggerEffectDraft

    data class InsertWeek(val effect: InsertWeekEffectDraft) : TriggerEffectDraft

    data class SetFlag(val name: String, val until: String? = null) : TriggerEffectDraft

    data class ClearFlag(val name: String) : TriggerEffectDraft

    data object CompletePlan : TriggerEffectDraft
}

data class TriggerSpecDraft(
    val id: String,
    /**
     * Reused directly from [CompiledCurriculum] — [TriggerOn] has no default-fill or
     * shape-collapsing issue (`boundary`'s `every`, `cursorReaches`, `taskFailed` are all either
     * required or cleanly nullable already).
     */
    val on: TriggerOn,
    val effects: List<TriggerEffectDraft>,
)

// ---------- Recovery / Advancement / Forecast ----------

data class RecoveryDraft(
    val allowedPolicies: List<String>,
    /** Named `defaultPolicy` (not `default`, a soft keyword) — maps to the JSON key `"default"` in `CurriculumDraftDocument.kt`. */
    val defaultPolicy: String,
    val escalationDays: Int,
)

data class AdvancementDraft(val requireVerified: Boolean? = null)

data class ForecastDraft(
    /**
     * Raw [JsonElement] per rate/factor name, not a decoded number — `strength_factors` is
     * schema-`number` (not `integer`) and every real built-in authors non-integer values like
     * `1.5`/`1.2`; raw pass-through is the simplest representation that cannot mis-format either
     * this or `workload_rates`. Mirrors [CompiledCurriculum.evidenceDefaults]'s existing
     * raw-pass-through precedent.
     */
    val workloadRates: Map<String, JsonElement>,
    val strengthFactors: Map<String, JsonElement>,
)

// ---------- CurriculumDraft ----------

/**
 * The full editable document. All top-level fields mirror `curriculum-v1.schema.json`'s root
 * object: `meta`/`units`/`calendar`/`sessions`/`variables`/`selectors`/`rules`/`triggers`/
 * `forecast` are schema-required (non-nullable here, though [rules] and [sessions] are not
 * separately enforced non-empty by this data class itself — see [rules]'s own doc comment);
 * `recovery`/`advancement`/`evidenceDefaults` are schema-optional (nullable here, `null` meaning
 * the key is absent from the document, never meaning "use the schema's stated default" — see each
 * field's own doc comment).
 */
data class CurriculumDraft(
    val meta: MetaDraft,
    val units: UnitsDraft,
    val calendar: CalendarDraft,
    val sessions: List<SessionDraft>,
    /** variable name -> definition. */
    val variables: Map<String, VariableDraft> = emptyMap(),
    /** selector name -> spec. */
    val selectors: Map<String, SelectorSpecDraft> = emptyMap(),
    /** Optional root-level exact-execution deduplication mode. */
    val taskDeduplicationMode: String? = null,
    /**
     * Schema requires `minItems: 1`; a draft mid-edit may transiently be empty, so this stays a
     * plain (non-enforced) list — enforcing "at least one rule" is gate 1/2's job (a future
     * `CurriculumValidator`), not this model's. [CurriculumDraft.fromDocument] (the parse path)
     * does still reject an empty/absent `rules` array structurally, matching the schema.
     */
    val rules: List<RuleSpecDraft> = emptyList(),
    val triggers: List<TriggerSpecDraft> = emptyList(),
    val recovery: RecoveryDraft? = null,
    val advancement: AdvancementDraft? = null,
    /**
     * Raw pass-through, exactly like [CompiledCurriculum.evidenceDefaults] (an evidence spec is
     * author-composable data resolved against variables at emit time, not something this model
     * needs typed access to). `null` = key absent (schema `minProperties: 1` when present, so
     * "absent" and "empty" can never both be legal — same collapse [CompiledCurriculum] already
     * relies on for this exact field).
     */
    val evidenceDefaults: Map<String, JsonElement>? = null,
    val forecast: ForecastDraft,
) {
    companion object {
        /**
         * D-028: `$pace` is bound by the engine from `PlanPolicy.newAmount` (falling back to
         * `units.default_pace`); no curriculum may declare its own variable named `pace`
         * ([CurriculumLoader.load] throws [CurriculumValidationException] on this at gate 2).
         * `$pace` REFERENCES (`VarOr.Ref("pace")`, e.g. a `next_new.amount: "$pace"` selector) are
         * a separate, legitimate, and common case — 13 of the 15 built-ins use one — and are
         * unaffected by this guard, which only concerns DECLARING a variable under this name.
         *
         * Reuses [CurriculumLoader.RESERVED_PACE_VAR] directly rather than declaring a second
         * copy of the literal — single source of truth for the one reserved string.
         */
        const val RESERVED_VARIABLE_NAME: String = CurriculumLoader.RESERVED_PACE_VAR
    }
}

/**
 * Safe entry point for a builder UI to add/rename a variable: rejects the reserved name up front
 * instead of silently producing a draft a future validator would reject later with a less
 * actionable error. Kotlin data classes are immutable by convention in this codebase (unlike the
 * Swift `struct`'s in-place `mutating func setVariable`, which returns the previous value), so
 * this returns a NEW [CurriculumDraft] with the variable set; callers thread it the same way as
 * any other `.copy(...)` call: `draft = draft.setVariable("foo", def)`. Direct mutation via
 * `.copy(variables = variables + (name to definition))` remains possible (this is an editable
 * model, not a locked-down one) and is NOT guarded — exactly as hand-authoring the JSON directly
 * would also not be guarded until validation runs; this function exists so the common UI path
 * doesn't have to reimplement the check.
 */
fun CurriculumDraft.setVariable(name: String, definition: VariableDraft): CurriculumDraft {
    if (name == CurriculumDraft.RESERVED_VARIABLE_NAME) {
        throw CurriculumValidationException(
            "variable name 'pace' is reserved (D-028: \$pace binds PlanPolicy.newAmount)",
        )
    }
    return copy(variables = variables + (name to definition))
}
