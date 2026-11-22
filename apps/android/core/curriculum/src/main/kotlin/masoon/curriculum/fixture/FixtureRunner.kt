package masoon.curriculum.fixture

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import masoon.curriculum.CompiledCurriculum
import masoon.curriculum.CurriculumLoader
import masoon.curriculum.CurriculumValidationException
import masoon.curriculum.DateRange
import masoon.curriculum.Engine
import masoon.curriculum.OrgException
import masoon.curriculum.PlanCalendar
import masoon.curriculum.PlanGenerationContext
import masoon.curriculum.StreamSerializer
import masoon.domain.ContentIndex
import masoon.domain.LocalDate
import masoon.domain.PoemIndex
import masoon.domain.PolicyJson
import masoon.domain.QuranIndex
import java.nio.file.Files
import java.nio.file.Path
import kotlin.system.exitProcess

/**
 * Fixture runner CLI (ENGINE_PARITY §4/§5):
 * `gradle :core:curriculum:fixtureRun --args="<fixture-dir>"` reads `<fixture-dir>/input.json`,
 * resolves `curriculum_definition` / `quran_ref` / `corpus_ref` relative to the fixture directory,
 * and prints the normalized task stream to stdout ONLY.
 */
fun main(args: Array<String>) {
    if (args.size != 1) {
        System.err.println("usage: fixtureRun <fixture-dir>")
        exitProcess(2)
    }
    try {
        print(runFixture(Path.of(args[0])))
    } catch (e: Exception) {
        System.err.println("fixtureRun failed: ${e.message}")
        exitProcess(1)
    }
}

/**
 * ENGINE_PARITY §4.3: the corpus-KIND discriminator, drawn from the same closed vocabulary as
 * `corpus-ref-v1.schema.json`'s `corpus_kind` and `curriculum-v1.schema.json`'s `meta.corpora`
 * (D-198). The three are kept in lockstep, so widening one without the others is exactly the drift
 * this type is here to make visible.
 */
private enum class CorpusKind(val token: String) {
    QURAN("quran"),
    POEM("poem"),
    ;

    companion object {
        fun of(token: String): CorpusKind = entries.firstOrNull { it.token == token }
            ?: throw CurriculumValidationException(
                "fixture input: corpus_ref.kind \"$token\" is not a kind this engine implements " +
                    "(known kinds: ${entries.joinToString(", ") { it.token }})"
            )
    }
}

private data class CorpusRef(val kind: CorpusKind, val path: String)

/**
 * ENGINE_PARITY §4.3 — resolve the fixture's single content-index slot.
 *
 * Both spellings normalize to `{kind, path}` FIRST, so the mutual-exclusion rule lives in one place
 * and `quran_ref` is provably just the `quran` kind rather than a parallel code path that could
 * drift from it. A kind this runner cannot build an index for fails LOUDLY and by name: falling
 * back to [QuranIndex] would read a foreign corpus through Qurʾānic page-density weights and
 * produce a plausible-looking stream that is wrong in every µp — far worse than not running.
 */
private fun loadContentIndex(fixtureDir: Path, input: JsonObject): ContentIndex {
    val quranRef = input["quran_ref"]
    val corpusRef = input["corpus_ref"]
    if ((quranRef == null) == (corpusRef == null)) {
        throw CurriculumValidationException(
            "fixture input: exactly one of `quran_ref` / `corpus_ref` is required " +
                "(got ${if (quranRef != null) "both" else "neither"})"
        )
    }
    val ref = if (quranRef != null) {
        CorpusRef(CorpusKind.QURAN, quranRef.jsonPrimitive.content)
    } else {
        val o = corpusRef!!.jsonObject
        CorpusRef(
            kind = CorpusKind.of(o.getValue("kind").jsonPrimitive.content),
            path = o.getValue("path").jsonPrimitive.content,
        )
    }
    val text = Files.readString(fixtureDir.resolve(ref.path).normalize())
    if (ref.kind == CorpusKind.QURAN) return QuranIndex.fromJson(text)

    // Every non-Qurʾān kind reads a corpus-ref-v1 document, which carries its own `corpus_kind`.
    // Disagreement is a hard error rather than a preference for either side: one of the two is
    // wrong and the fixture must say which.
    val doc = Json.parseToJsonElement(text).jsonObject
    val declared = doc["corpus_kind"]?.jsonPrimitive?.content
    if (declared != ref.kind.token) {
        throw CurriculumValidationException(
            "fixture input: corpus_ref.kind \"${ref.kind.token}\" disagrees with the document's " +
                "own corpus_kind ${declared?.let { "\"$it\"" } ?: "(absent)"}"
        )
    }
    return when (ref.kind) {
        CorpusKind.POEM -> PoemIndex.fromJson(doc)
        CorpusKind.QURAN -> error("unreachable: handled above")
    }
}

/**
 * ENGINE_PARITY §4.2 — the optional `extra_curricula` array, each entry `{slug, version,
 * definition}` where `definition` is full INLINE curriculum-v1 JSON (not a path). Omitting it is
 * behaviorally identical to an empty array.
 */
private fun loadExtraCurricula(input: JsonObject): Map<String, CompiledCurriculum> {
    val extras = input["extra_curricula"] ?: return emptyMap()
    val out = LinkedHashMap<String, CompiledCurriculum>()
    for (item in extras.jsonArray) {
        val o = item.jsonObject
        val slug = o["slug"]?.jsonPrimitive?.content
        val version = o["version"]?.jsonPrimitive?.content
        val definition = o["definition"]
        if (slug == null || version == null || definition == null) {
            throw CurriculumValidationException("extra_curricula item missing slug/version/definition")
        }
        out["$slug@$version"] = CurriculumLoader.load(definition.toString())
    }
    return out
}

fun runFixture(fixtureDir: Path): String {
    val inputPath = fixtureDir.resolve("input.json")
    val input = Json.parseToJsonElement(Files.readString(inputPath)).jsonObject

    // ENGINE_PARITY §4.1: reference paths are relative to input.json's own directory
    val curriculumPath = fixtureDir.resolve(input.getValue("curriculum_definition").jsonPrimitive.content).normalize()

    val curriculum: CompiledCurriculum = CurriculumLoader.load(Files.readString(curriculumPath))
    val index = loadContentIndex(fixtureDir, input)

    val calendarO = input.getValue("calendar").jsonObject
    val calendar = PlanCalendar(
        timezone = calendarO.getValue("timezone").jsonPrimitive.content,
        anchorDate = LocalDate.parse(calendarO.getValue("anchor_date").jsonPrimitive.content),
        orgExceptions = calendarO["org_exceptions"]?.jsonArray?.map {
            val o = it.jsonObject
            OrgException(
                LocalDate.parse(o.getValue("date").jsonPrimitive.content),
                o.getValue("class").jsonPrimitive.content,
            )
        } ?: emptyList(),
    )

    val windowO = input.getValue("window").jsonObject
    val window = DateRange(
        from = LocalDate.parse(windowO.getValue("from").jsonPrimitive.content),
        to = LocalDate.parse(windowO.getValue("to").jsonPrimitive.content),
    )

    val context = PlanGenerationContext(
        planId = input.getValue("plan_id").jsonPrimitive.content,
        curriculum = curriculum,
        index = index,
        policy = PolicyJson.parsePolicy(input.getValue("policy").jsonObject),
        startingState = PolicyJson.parseStartingState(input.getValue("starting_state").jsonObject),
        calendar = calendar,
        eventLog = input["event_log"]?.jsonArray?.map { PolicyJson.parseEvent(it.jsonObject) } ?: emptyList(),
        today = LocalDate.parse(input.getValue("today").jsonPrimitive.content),
        curriculaByKey = loadExtraCurricula(input),
    )

    return StreamSerializer.serialize(Engine(curriculum).generateFull(context, window))
}
