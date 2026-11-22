package masoon.curriculum

import kotlinx.serialization.json.JsonElement

/**
 * B7-WaveC (curriculumbuilder UI, CB-11): a small, ADDITIVE public wrapper around
 * [CurriculumDraftCoding]'s existing module-internal single-selector JSON coding — mirrors iOS's
 * own `SelectorSpec.fromJSON`/`.toJSONValue()` ("CB-11's own small additive public wrapper around
 * CB-9's existing private JSON coding", `CurriculumSelectorsEditorView.swift`'s header comment).
 *
 * Exists purely so the curriculum-builder's raw-JSON fallback field (the 8 selector kinds with no
 * bespoke UI — `next_new`/`pool_rotation`/`ledger_offset` are the only 3 that get one) can parse
 * and re-serialize a SINGLE [SelectorSpecDraft] without a second, hand-rolled JSON parser: both
 * functions below delegate straight to the SAME [CurriculumDraftCoding.parseSelectorSpec] /
 * [CurriculumDraftCoding.selectorSpecToJson] the full-document round trip
 * ([CurriculumDraft.fromDocument]/[CurriculumDraft.toDocument]) already uses, so a selector edited
 * as raw text round-trips under EXACTLY the same rules as one edited through a bespoke field.
 *
 * [CompiledCurriculum]/[CurriculumLoader]/[Engine] are untouched — this is a new top-level
 * function operating on the existing (already-committed) [CurriculumDraftCoding] namespace, the
 * same purely-additive shape every other file in this port uses.
 */
fun CurriculumDraft.Companion.parseSelectorSpec(json: JsonElement): SelectorSpecDraft =
    CurriculumDraftCoding.parseSelectorSpec(json, "selector")

/** Inverse of [parseSelectorSpec] — see this file's header. */
fun SelectorSpecDraft.toJsonElement(): JsonElement = CurriculumDraftCoding.selectorSpecToJson(this)
