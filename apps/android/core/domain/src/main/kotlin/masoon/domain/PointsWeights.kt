package masoon.domain

/**
 * Points scoring basis for Track J (D-178: opt-in, off-by-default, derived-only points).
 * Swift parity: `MasoonDomain/PointsWeights.swift`.
 *
 * D-178 fixes the shape of the score — "a pure deterministic function of the folded event log" —
 * but not a points formula. This file supplies the formula:
 *
 *     points = estimatedMinutes × typeWeightPerMille × qualityMultPerMille / 1_000_000
 *
 * computed entirely in `Long`, round-half-up, via the shared [roundHalfUpDiv] (reused, not
 * reimplemented). This is deliberately **not** expressed in micropages: µp weighs by content
 * size, which would let a two-juz murājaʿah task dwarf a page of new ḥifẓ in points terms — not
 * the intent of a system meant to reward consistent effort. `estimatedMinutes` (already computed
 * per generated task by the engine) is the size input instead.
 *
 * [typeWeightPerMille] and [qualityMultPerMille] are both expressed per mille (× 1/1000, so 1000
 * == 1.0×) to keep the whole computation integral — no binary floating point anywhere in this
 * engine family (ENGINE_SEMANTICS §1). Multiplying two per-mille factors scales the result by
 * 1000 × 1000, so the formula divides by [PER_MILLE_SQUARED] with round-half-up applied exactly
 * once, at the end.
 *
 * `quality` reuses the existing [Strength] vocabulary rather than inventing a second three-way
 * axis. Note [Strength.factorScaled] (used for *workload* sizing — weak ḥifẓ needs more review
 * volume, so weak scales *up*) points the opposite direction from [qualityMultPerMille] here
 * (weak *evidence quality* should earn *fewer* points): same enum, deliberately different and
 * independent numeric axes. Do not conflate the two.
 *
 * ## Placeholder weights — NOT final, pending founder/product tuning
 *
 * [V1]'s numbers are **initial placeholders**, not a tuned product decision. D-178 authorizes the
 * points *mechanism*; it does not specify per-type or per-quality weights. Every task type is
 * weighted flat at 1000‰ — deliberately not differentiated per type, since deciding which task
 * types "deserve" more points would itself be a pedagogy judgment call with no basis here. The
 * quality multiplier (weak 800‰ / moderate 1000‰ / strong 1200‰) is a mild ±20% spread — enough
 * to make quality visibly matter without being punitive (D-178's "no shaming" guardrail).
 * **Revisit both before any points UI ships.**
 *
 * ## Override seam
 *
 * [PointsWeights] is an ordinary constructible value — not a compile-time-only constant — so a
 * future QA/debug surface can build an alternate table (e.g. from per-plan metadata) and pass it
 * to [points] instead of [V1]. This file only defines the seam; it never reads or writes storage.
 */
data class PointsWeights(
    /** Identifies which weights table produced a score, so a UI or debug surface can show it. */
    val version: String,
    val typeWeightPerMille: Map<TaskType, Long>,
    val qualityMultPerMille: Map<Strength, Long>,
) {

    /**
     * `points = round_half_up(estimatedMinutes × typeWeight‰ × qualityMult‰ / 1_000_000)`.
     * Pure function of its inputs — no I/O, no mutable state (D-178: replay-safe).
     */
    fun points(estimatedMinutes: Int, taskType: TaskType, quality: Strength): Long {
        require(estimatedMinutes >= 0) { "estimatedMinutes must be non-negative: $estimatedMinutes" }
        val typeWeight = typeWeightPerMille[taskType] ?: NEUTRAL_PER_MILLE
        val qualityMult = qualityMultPerMille[quality] ?: NEUTRAL_PER_MILLE
        return roundHalfUpDiv(estimatedMinutes.toLong() * typeWeight * qualityMult, PER_MILLE_SQUARED)
    }

    companion object {
        /** Both per-mille factors are scaled by 1000; their product is scaled by 1000 × 1000. */
        const val PER_MILLE_SQUARED: Long = 1_000_000L

        /**
         * Neutral (1.0×) fallback for a [TaskType]/[Strength] missing from a possibly-sparse,
         * override-supplied table, so an incomplete table degrades to "no adjustment" rather than
         * a crash or a silent zero.
         */
        const val NEUTRAL_PER_MILLE: Long = 1_000L

        /** Initial placeholder weights — see the class doc comment. Not final. */
        val V1 = PointsWeights(
            version = "points_weights_v1",
            typeWeightPerMille = TaskType.entries.associateWith { NEUTRAL_PER_MILLE },
            qualityMultPerMille = mapOf(
                Strength.WEAK to 800L,
                Strength.MODERATE to 1_000L,
                Strength.STRONG to 1_200L,
            ),
        )
    }
}
