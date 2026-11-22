package masoon.mushaf

/**
 * Who owns the plan a listening task belongs to.
 *
 * The only distinction D-215 turns on, kept as its own two-case type rather than a raw `Boolean`
 * so a call site cannot silently pass the wrong flag — `autoEvidence(isOrg = false)` reads
 * identically whether it means "individual" or "we forgot to check".
 */
enum class MushafLearnerScope {
    /** A learner working on their own plan. No third party relies on their evidence. */
    INDIVIDUAL,

    /** A student on an organization-scoped plan. A supervisor or parent may rely on this. */
    ORGANIZATION,
}

/** What should happen when a listening pass finishes. */
sealed interface MushafListeningEvidence {
    /**
     * Count the pass automatically. Individual learners only.
     *
     * The payload is deliberately IDENTICAL in shape to a manual tap — D-215 scopes by mode, not
     * by payload, and introduces no new event type. Nothing downstream can tell the two apart,
     * which is the point: an individual learner's auto-counted pass is not a lesser kind of
     * evidence, it is the same evidence with the tap removed.
     */
    data object AutoCount : MushafListeningEvidence

    /**
     * Ask the learner to confirm. Organization students, always.
     *
     * An unattended overnight playback — phone left running, earbuds forgotten in, app
     * backgrounded — must not be able to fabricate that a student actually listened. Org evidence
     * is auditable compliance data a supervisor or parent may act on.
     */
    data object RequireManualConfirmation : MushafListeningEvidence
}

/**
 * D-215, as a pure decision.
 *
 * A function rather than a branch inside the player because the rule is a compliance commitment,
 * not a UI detail: it is exhaustively testable here, and a future change to it is one visible edit
 * rather than a hunt through playback code.
 *
 * **The asymmetry is intentional and is not a UX gap to close later.** An org student takes one
 * more tap than an individual learner for the identical action. That extra tap is the entire
 * compliance mechanism.
 */
object MushafListeningEvidencePolicy {
    fun evidenceFor(scope: MushafLearnerScope): MushafListeningEvidence =
        when (scope) {
            MushafLearnerScope.INDIVIDUAL -> MushafListeningEvidence.AutoCount
            MushafLearnerScope.ORGANIZATION -> MushafListeningEvidence.RequireManualConfirmation
        }

    /**
     * Whether a *completed* pass may count itself.
     *
     * Takes completion explicitly rather than assuming the caller only asks at the right moment:
     * a partial pass never counts, for either scope. An interrupted listen is not a listen.
     */
    fun mayAutoCount(
        scope: MushafLearnerScope,
        passCompleted: Boolean,
    ): Boolean = passCompleted && evidenceFor(scope) == MushafListeningEvidence.AutoCount
}
