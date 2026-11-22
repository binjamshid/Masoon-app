package masoon.domain

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull

/**
 * WP-15 (v1 audit 6.1/7.3/2.16, founder ruling 2026-07-31): a NAMED-LISTENER ATTESTATION — the
 * in-app tasmeeʿ ijāza form the learner fills after a listener (musammiʿ) hears their sabaq, in
 * place of a teacher-console verification that does not exist yet.
 *
 * Ported from `apps/ios/Packages/Sources/MasoonDomain/TasmeeAttestation.swift`. D-041/D-046's
 * non-negotiable gate is that a HUMAN, not the app, makes the maqbūl/mardūd (accepted/rejected)
 * call before `advancement.require_verified` curricula (Deobandi) let the new-hifz cursor move.
 * This type does not weaken that: the human is the named musammiʿ, and the app only records what
 * the learner reports about that person's hearing — it never performs, scores, or infers the
 * assessment itself (no ASR, no recitation grading, D-053).
 *
 * [evidenceKind] is deliberately `named_listener_attestation`, never `teacher_verification` —
 * [PolicyJson.parseEvent]'s verified detection treats `evidence.kind == "teacher_verification"`
 * as "verified by the (future) real supervisor console" (E-4b/D-046). Reusing that literal
 * string here would make a self-attested hearing indistinguishable, in the raw event log, from
 * one a real teacher/console verified — exactly what the founder's ruling says must never
 * happen. A future supervisor console tells the two apart by reading `evidence.kind`; the nested
 * `evidence.verified == true` this type writes is what satisfies `advancement.require_verified`
 * without ever writing `kind: "teacher_verification"` (see [PolicyJson.parseEvent]'s matching
 * comment).
 */
data class TasmeeAttestation(
    /** The listener's (مُسمِّع) name, as the learner typed it. Free text — no teacher roster to validate against. */
    val musammiName: String,
    /** "HH:mm" plan-timezone wall clock — when the hearing happened, not when the form was submitted. */
    val time: String,
    /** Whatever score the musammiʿ gave, as the learner reports it. A UI range (0..100), not a pedagogical scale. */
    val score: Int,
    /** Mistake count the musammiʿ noted — a plain tally the learner is transcribing, never a curated count. */
    val mistakeCount: Int,
) {
    /**
     * A "filled" attestation per the founder's ruling: the one field a picker/stepper can't
     * default past is the listener's name — a blank name means no listener was actually named,
     * so the maqbūl/mardūd human check the record claims to describe would not have happened.
     */
    val isFilled: Boolean get() = musammiName.trim().isNotEmpty()

    /**
     * The `task.completed.evidence` payload (AC-1.2 shape family): `kind`, the four
     * founder-specified fields, and a nested `verified: true` [PolicyJson.parseEvent] reads to
     * satisfy `advancement.require_verified` — see the type doc comment.
     */
    fun evidenceJson(): JsonElement = buildJsonObject {
        put("kind", JsonPrimitive(EVIDENCE_KIND))
        put("musammi_name", JsonPrimitive(musammiName))
        put("time", JsonPrimitive(time))
        put("score", JsonPrimitive(score))
        put("mistake_count", JsonPrimitive(mistakeCount))
        put("verified", JsonPrimitive(true))
    }

    companion object {
        /** Evidence `kind` for a self-attested, named-listener hearing. Never `"teacher_verification"`. */
        const val EVIDENCE_KIND = "named_listener_attestation"

        /**
         * Reads a previously-recorded attestation back out of an `evidence` JSON blob. Returns
         * `null` for anything that isn't this kind — in particular a real `teacher_verification`
         * event, by construction.
         */
        fun parse(evidence: JsonElement): TasmeeAttestation? {
            val obj = evidence as? JsonObject ?: return null
            val kind = (obj["kind"] as? JsonPrimitive)?.contentOrNull
            if (kind != EVIDENCE_KIND) return null
            val name = (obj["musammi_name"] as? JsonPrimitive)?.contentOrNull ?: return null
            val time = (obj["time"] as? JsonPrimitive)?.contentOrNull ?: return null
            val score = (obj["score"] as? JsonPrimitive)?.intOrNull ?: return null
            val mistakeCount = (obj["mistake_count"] as? JsonPrimitive)?.intOrNull ?: return null
            return TasmeeAttestation(name, time, score, mistakeCount)
        }

        /** Whether an `evidence` blob carries the human-accepted signal [PolicyJson.parseEvent] reads. */
        fun isVerifiedEvidence(evidence: JsonElement): Boolean =
            (evidence as? JsonObject)?.get("verified")?.let { (it as? JsonPrimitive)?.booleanOrNull } == true
    }
}
