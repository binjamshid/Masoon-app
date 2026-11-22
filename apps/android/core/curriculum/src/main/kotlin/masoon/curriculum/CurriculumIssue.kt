package masoon.curriculum

/**
 * B7-C (curriculum-authoring validation pipeline): the shared finding type every one of the 4
 * validation gates (schema / references / lints / simulation) reports through — Kotlin port of
 * `apps/ios/Packages/Sources/MasoonCurriculum/CurriculumIssue.swift`. A future curriculum-builder
 * UI groups/sorts/localizes purely off this type — it never needs to know which gate-internal
 * type ([SchemaViolation], [CurriculumValidationException], a lint, or [CurriculumSimulator])
 * produced a given finding.
 */

/**
 * Whether a finding blocks the draft from being usable ([ERROR]) or is a non-blocking signal the
 * author should look at but may accept ([WARNING]). A plain Kotlin enum is `Comparable` by
 * declaration order, so `WARNING < ERROR` already holds with no extra ranking code needed
 * (mirrors Swift's hand-written `Comparable` conformance).
 */
enum class IssueSeverity(val code: String) {
    WARNING("warning"),
    ERROR("error"),
    ;

    override fun toString(): String = code
}

/** Which of the 4 gates produced a finding. */
enum class ValidationGate(val code: String) {
    SCHEMA("schema"),
    REFERENCES("references"),
    LINTS("lints"),
    SIMULATION("simulation"),
    ;

    override fun toString(): String = code
}

/** A single validation finding from any gate. */
data class CurriculumIssue(
    val severity: IssueSeverity,
    /**
     * Stable identifier a caller can key UI copy, docs, or `--only L-12` style filtering off:
     * `"SCHEMA"` (gate 1, any schema keyword violation), `"REF-INVALID"` (gate 2, wrapping
     * [CurriculumValidationException] — see the note on [fromCurriculumError] below for why this
     * is ONE id here, unlike iOS's `REF-MALFORMED`/`REF-INVALID` pair), `"REF-UNKNOWN"` (gate 2,
     * an exception `CurriculumLoader.load` was not documented to throw), `"L-07"`..`"L-15"` (gate
     * 3, see [CurriculumLints]), or `"SIM-DAY-OVER-1440"` / `"SIM-NONDETERMINISTIC"` / `"SIM-ERROR"`
     * (gate 4, see [CurriculumSimulator] / [CurriculumValidator]). Never blank.
     */
    val id: String,
    val gate: ValidationGate,
    /**
     * Best-effort RFC 6901 pointer into the DRAFT document this finding is about. `JSONPointer()`
     * (root) when no more specific location applies (e.g. a gate-2 finding, which wraps only a
     * message, no structured location — `CurriculumLoader.load` throws on the FIRST problem it
     * finds rather than collecting every reference error, a known limitation of reusing it as-is
     * rather than reimplementing it).
     */
    val path: JSONPointer,
    val messageEn: String,
    /**
     * Arabic translation of an authored diagnostic. Findings from the schema validator or
     * curriculum loader may carry only the original English error.
     */
    val messageAr: String? = null,
) {
    /** Localized message: Arabic when authored and requested, else English. */
    fun message(arabic: Boolean): String = if (arabic && messageAr != null) messageAr else messageEn

    override fun toString(): String {
        val where = path.toString().ifEmpty { "(root)" }
        return "[$severity] $id ($gate) $where: $messageEn"
    }

    companion object {
        /** Gate 1: wraps a [JSONSchemaValidator] finding. */
        fun fromSchemaViolation(v: SchemaViolation): CurriculumIssue = CurriculumIssue(
            severity = IssueSeverity.ERROR,
            id = "SCHEMA",
            gate = ValidationGate.SCHEMA,
            path = v.path,
            messageEn = "${v.message} [${v.keyword}]",
        )

        /**
         * Gate 2: wraps whatever `CurriculumLoader.load` threw — the existing loader (D-028
         * reference validation, plus its own shape guards) reused as-is, not reimplemented.
         *
         * DEVIATION FROM iOS: Swift's `CurriculumError` is a two-case enum (`.malformed` /
         * `.invalidReference`), so `CurriculumIssue.fromCurriculumError` there produces either
         * `"REF-MALFORMED"` or `"REF-INVALID"`. Kotlin's `CurriculumLoader` throws a single flat
         * [CurriculumValidationException] for every guard — both "the JSON doesn't have the shape
         * this loader expects" and "this JSON references something undeclared" flow through the
         * same `fail(msg)` helper — so there is no type-level way to recover which of the two an
         * error was without parsing `message` text (fragile, and not attempted here). Every
         * loader failure therefore reports id `"REF-INVALID"` here — chosen over `"REF-MALFORMED"`
         * because gate 1 (schema) already rejects almost every shape problem before gate 2 ever
         * runs, so a schema-valid draft that still fails the loader is overwhelmingly a D-028
         * reference problem (unknown selector/variable/session/day_class, duplicate id, reserved
         * `pace` name) in practice.
         */
        fun fromCurriculumError(e: CurriculumValidationException): CurriculumIssue = CurriculumIssue(
            severity = IssueSeverity.ERROR,
            id = "REF-INVALID",
            gate = ValidationGate.REFERENCES,
            path = JSONPointer(),
            messageEn = e.message ?: "curriculum failed to load",
        )
    }
}
