package masoon.curriculum

/**
 * Normalized task stream serializer (ENGINE_PARITY §3, byte-exact):
 *
 * ```
 * date|day_class|session|ordering|type|origin_rule_id|content|reps|spacing_min|listen_count|window|est_min|evidence|flags|task_uid
 * ```
 *
 * followed by one `#STATE` checkpoint line; lines joined with `\n`, exactly one trailing `\n`.
 */
object StreamSerializer {

    fun serialize(result: GenerationResult): String {
        val sb = StringBuilder()
        for (t in result.tasks) {
            sb.append(line(t)).append('\n')
        }
        sb.append(stateLine(result.state)).append('\n')
        return sb.toString()
    }

    fun line(t: TaskInstance): String {
        val content = t.content.joinToString("+") { it.toString() }
        val window = if (t.windowOpensOn != null && t.windowClosesOn != null) {
            "${t.windowOpensOn}..${t.windowClosesOn}"
        } else {
            ""
        }
        // flags: comma-joined, sorted ASCII
        val flags = t.flags.sorted().joinToString(",")
        return listOf(
            t.date.toString(),
            t.dayClass,
            t.session,
            t.ordering.toString(),
            t.type,
            t.originRuleId,
            content,
            t.targetRepetitions?.toString() ?: "",
            t.spacingMinutes?.toString() ?: "",
            t.listenCount?.toString() ?: "",
            window,
            t.estimatedMinutes.toString(),
            t.evidenceCompact,
            flags,
            t.taskUid,
        ).joinToString("|")
    }

    fun stateLine(s: EngineState): String {
        val cursor = s.cursor?.toString() ?: "-"
        return "#STATE|cursor=$cursor|juz_done=${s.juzDone}|cycle_weeks=${s.cycleWeeks}|" +
            "debt_new=${s.debtNewRangeCount}|status=${s.status}"
    }
}
