package masoon.curriculum

import kotlinx.serialization.json.JsonElement

/**
 * B7-C: MasoonAuthoring's top-level 4-gate curriculum-draft validation pipeline (schema /
 * references / lints / simulation) — Kotlin port of
 * `apps/ios/Packages/Sources/MasoonCurriculum/CurriculumValidator.swift`. Depended on by the
 * curriculum-builder UI.
 *
 * Gate order and short-circuiting:
 *   1. SCHEMA -- [JSONSchemaValidator] against the raw draft. ANY violation is a hard error;
 *      gates 2-4 do not run.
 *   2. REFERENCES -- `CurriculumLoader.load(text)`. This call itself IS gate 2 (D-028 reference
 *      validation, plus the loader's own shape guards, both funneled through the same
 *      [CurriculumValidationException] — see [CurriculumIssue.fromCurriculumError] for the
 *      documented one-id-instead-of-two deviation from iOS). A thrown [CurriculumValidationException]
 *      (or any other exception the loader was not documented to throw) is a hard error; gates 3-4
 *      do not run.
 *   3. LINTS -- [CurriculumLints.run], a fixed enumerable set (L-07..L-15). Every lint runs and
 *      every finding is collected (lints do not short-circuit each other) — authoring feedback is
 *      more useful shown in full. Only an ERROR-severity lint blocks gate 4; a WARNING (e.g. L-08)
 *      does not.
 *   4. SIMULATION -- a pluggable seam ([CurriculumSimulationGate]). Defaults to [NoOpSimulationGate],
 *      so gates 1-3 are fully real and gate 4 is inert (reports nothing) unless a caller supplies
 *      a real [CurriculumSimulator].
 */
object CurriculumValidator {
    /**
     * Runs the full 4-gate pipeline against [draft].
     *
     * @param draft the raw curriculum-v1 JSON document under authoring.
     * @param schema a pre-compiled [JSONSchemaValidator] for `curriculum-v1.schema.json`
     *   (compiling it is moderately expensive, so callers construct/cache one and pass it in).
     * @param simulationGate gate 4's pluggable implementation. Defaults to a no-op.
     */
    fun validate(
        draft: JsonElement,
        schema: JSONSchemaValidator,
        simulationGate: CurriculumSimulationGate = NoOpSimulationGate(),
    ): CurriculumValidationResult {
        val issues = mutableListOf<CurriculumIssue>()

        // --- Gate 1: schema.
        val schemaViolations = schema.validate(draft)
        issues += schemaViolations.map { CurriculumIssue.fromSchemaViolation(it) }
        if (issues.any { it.severity == IssueSeverity.ERROR }) {
            return CurriculumValidationResult(issues, null)
        }

        // --- Gate 2: references (via the real loader — see the class doc).
        val compiled: CompiledCurriculum
        try {
            compiled = CurriculumLoader.load(draft.toString())
        } catch (e: CurriculumValidationException) {
            issues += CurriculumIssue.fromCurriculumError(e)
            return CurriculumValidationResult(issues, null)
        } catch (e: Exception) {
            // CurriculumLoader.load is documented to throw only CurriculumValidationException;
            // this branch exists so an unexpected failure (e.g. a malformed shape gate 1's schema
            // check did not catch) fails as a reported issue, not an uncaught pipeline crash.
            issues += CurriculumIssue(
                severity = IssueSeverity.ERROR, id = "REF-UNKNOWN", gate = ValidationGate.REFERENCES,
                path = JSONPointer(), messageEn = "unexpected error compiling curriculum: ${e.message}",
            )
            return CurriculumValidationResult(issues, null)
        }

        // --- Gate 3: lints.
        val lintIssues = CurriculumLints.run(draft, compiled)
        issues += lintIssues
        if (lintIssues.any { it.severity == IssueSeverity.ERROR }) {
            return CurriculumValidationResult(issues, compiled)
        }

        // --- Gate 4: simulation (seam; see [CurriculumSimulationGate] below).
        try {
            issues += simulationGate.simulate(compiled)
        } catch (e: Exception) {
            issues += CurriculumIssue(
                severity = IssueSeverity.ERROR, id = "SIM-ERROR", gate = ValidationGate.SIMULATION,
                path = JSONPointer(), messageEn = "simulation gate threw: ${e.message}",
            )
        }

        return CurriculumValidationResult(issues, compiled)
    }
}

/**
 * Gate 4's seam. [CurriculumSimulator] implements this for real: a 60-day preview / 400-day
 * publish depth simulation via the real engine across canonical [SimulationProfile]s, asserting
 * e.g. no day exceeds 1440 minutes and that a double-run is byte-identical (determinism). Declared
 * as an interface rather than a bare lambda so a real implementation can add context (profile
 * selection, depth) via its own constructor without changing this file's call sites, and so
 * conforming types can hold state (e.g. a cached `ContentIndex`) instead of capturing it in a
 * closure.
 *
 * Exceptions propagate normally (no `throws` keyword in Kotlin); [CurriculumValidator.validate]
 * converts anything thrown into ONE `.simulation`-gate error issue rather than letting the whole
 * pipeline throw, so a buggy simulator degrades gate 4 to "one error issue", never crashes gates
 * 1-3's already-computed results.
 */
interface CurriculumSimulationGate {
    fun simulate(curriculum: CompiledCurriculum): List<CurriculumIssue>
}

/**
 * Default gate-4 implementation until a real [CurriculumSimulator] is supplied: reports nothing,
 * so [CurriculumValidator.validate]'s gate 4 is a no-op by default rather than a compile error or
 * a placeholder UI surface.
 */
class NoOpSimulationGate : CurriculumSimulationGate {
    override fun simulate(curriculum: CompiledCurriculum): List<CurriculumIssue> = emptyList()
}

/** The pipeline's overall result: every finding across whichever gates ran, plus gate 2's compiled output when available. */
data class CurriculumValidationResult(
    val issues: List<CurriculumIssue>,
    /**
     * Gate 2's output, present iff gates 1-2 both succeeded — so a caller wanting SOMETHING to
     * preview still can even when gate 3 found a hard error (e.g. to render the draft's tasks
     * while also showing the lint error that blocks publishing it).
     */
    val compiledCurriculum: CompiledCurriculum?,
) {
    val passed: Boolean get() = issues.none { it.severity == IssueSeverity.ERROR }
    val errors: List<CurriculumIssue> get() = issues.filter { it.severity == IssueSeverity.ERROR }
    val warnings: List<CurriculumIssue> get() = issues.filter { it.severity == IssueSeverity.WARNING }
}
