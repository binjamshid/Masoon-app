package masoon.domain

/**
 * Canonical task-type vocabulary, mirroring the closed `$defs.TaskType` enum in
 * `contracts/json-schema/curriculum-v1.schema.json` (12 values). The schema enum is closed —
 * `additionalProperties: false` everywhere in the curriculum DSL, and org-authored custom
 * curricula still validate against that same schema — so a Kotlin `enum class` (a closed set) is
 * the accurate mirror, not an open string set.
 *
 * Design note (Track J / PT-3): `TaskInstance.type` and its call sites deliberately keep `type` as
 * a raw `String`, since the engine and its DTOs are JSON-schema-driven and treat task type as data
 * flowing through a generic pipeline, not a compiled Kotlin type. This enum does not replace that;
 * it is a narrower, additive mirror for call sites (starting with [PointsWeights]) that want
 * compile-time exhaustiveness over the closed set. Bridge to/from the existing `String`-typed task
 * data at the boundary via [fromCodeOrNull] / [TaskType.code].
 */
enum class TaskType(val code: String) {
    PREP_DHIKR("prep_dhikr"),
    WARMUP("warmup"),
    TILAWAH("tilawah"),
    NEW_HIFZ("new_hifz"),
    TAKRAR("takrar"),
    MURAJAAH("murajaah"),
    LISTENING("listening"),
    WEEKEND_CONSOLIDATION("weekend_consolidation"),
    TASMEE("tasmee"),
    JUZ_REVIEW("juz_review"),
    JUZ_REVIEW_DISTRIBUTED("juz_review_distributed"),
    CYCLE_CONSOLIDATION("cycle_consolidation"),
    ;

    companion object {
        /**
         * Null (not an exception) for an unrecognized code — unlike [Weekday.fromCode] and
         * friends, which parse trusted contract-shaped input. This one bridges the engine's
         * stringly-typed `TaskInstance.type`, where an unknown value from a future schema version
         * must degrade (I-4: preserved opaquely), never crash a learner's Today screen.
         */
        fun fromCodeOrNull(code: String): TaskType? = entries.firstOrNull { it.code == code }
    }
}
