package masoon.domain

/**
 * Evidence model (PRD §7.11). Compact serialization per ENGINE_PARITY §3:
 * `self | timer:{s} | counter:{n} | teacher | form:{id} | composite(a+b)`.
 */
sealed interface EvidenceSpec {
    data object SelfCheck : EvidenceSpec
    data class Timer(val minSeconds: Int) : EvidenceSpec
    data class Counter(val target: Int) : EvidenceSpec
    data class TeacherVerification(val formVersionId: String? = null) : EvidenceSpec
    data class Form(val formVersionId: String) : EvidenceSpec
    data class Composite(val parts: List<EvidenceSpec>) : EvidenceSpec

    fun compact(): String = when (this) {
        SelfCheck -> "self"
        is Timer -> "timer:$minSeconds"
        is Counter -> "counter:$target"
        is TeacherVerification -> "teacher"
        is Form -> "form:$formVersionId"
        is Composite -> "composite(${parts.joinToString("+") { it.compact() }})"
    }

    companion object {
        /**
         * Exact inverse of [compact] (ENGINE_PARITY §3: `self | timer:{s} | counter:{n} | teacher
         * | form:{id} | composite(a+b)`). This is what `TaskInstanceEntity.evidenceJson` actually
         * stores on Android (the compact stream form, NOT the wire JSON `PolicyJson.parseEvidenceSpec`
         * reads) — see `:core:data`'s `Mappers.kt` doc comment on why every `*_json` column gets
         * exactly one decoder.
         *
         * [TeacherVerification.formVersionId] never round-trips: `compact()` discards it (the
         * stream format has no slot for it), so this always returns `TeacherVerification(null)`
         * for `"teacher"`.
         *
         * Throws [IllegalArgumentException] on anything malformed — callers reading a stored
         * value should wrap in `runCatching` (fail-closed, never crash a render on a corrupt row).
         */
        fun parseCompact(raw: String): EvidenceSpec {
            if (raw == "self") return SelfCheck
            if (raw == "teacher") return TeacherVerification(null)
            if (raw.startsWith("timer:")) {
                return Timer(raw.removePrefix("timer:").toIntOrNull() ?: malformed(raw))
            }
            if (raw.startsWith("counter:")) {
                return Counter(raw.removePrefix("counter:").toIntOrNull() ?: malformed(raw))
            }
            if (raw.startsWith("form:")) {
                val id = raw.removePrefix("form:")
                return if (id.isEmpty()) malformed(raw) else Form(id)
            }
            if (raw.startsWith("composite(") && raw.endsWith(")")) {
                val body = raw.substring("composite(".length, raw.length - 1)
                if (body.isEmpty()) malformed(raw)
                return Composite(splitTopLevel(body).map { parseCompact(it) })
            }
            malformed(raw)
        }

        /** Splits on `+` at nesting depth 0 only, so a nested `composite(...)` part survives intact. */
        private fun splitTopLevel(body: String): List<String> {
            val parts = mutableListOf<String>()
            var depth = 0
            var start = 0
            for ((i, c) in body.withIndex()) {
                when (c) {
                    '(' -> depth++
                    ')' -> depth--
                    '+' -> if (depth == 0) {
                        parts.add(body.substring(start, i))
                        start = i + 1
                    }
                }
            }
            parts.add(body.substring(start))
            return parts
        }

        private fun malformed(raw: String): Nothing =
            throw IllegalArgumentException("unparseable compact evidence spec: $raw")
    }
}
