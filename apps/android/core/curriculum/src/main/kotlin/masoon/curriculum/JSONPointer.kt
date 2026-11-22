package masoon.curriculum

/**
 * Minimal RFC 6901 JSON Pointer (Kotlin port of `apps/ios/Packages/Sources/MasoonCurriculum/JSONPointer.swift`),
 * used by [JSONSchemaValidator] to report WHERE in a JSON document a schema violation was found.
 *
 * This exists so [SchemaViolation.path] can point at the same location in the instance document
 * ajv's `instancePath` would (the "INSTANCE-PATH CONTAINMENT" half of [JSONSchemaValidator]'s
 * equivalence bar — see that file's header). It is not a general-purpose JSON Pointer
 * implementation (no `~` decoding into arbitrary document lookups, no relative pointers) — just
 * enough to build and print one.
 */
data class JSONPointer(val tokens: List<String> = emptyList()) {

    /** A pointer with one more reference token appended (an object member name). */
    fun appending(token: String): JSONPointer = JSONPointer(tokens + token)

    /** A pointer with one more reference token appended (an array index). */
    fun appending(index: Int): JSONPointer = appending(index.toString())

    /** The RFC 6901 string form: `""` for the root, else `"/a/b/0"` with each token's `~`/`/` escaped. */
    override fun toString(): String =
        if (tokens.isEmpty()) "" else "/" + tokens.joinToString("/") { escape(it) }

    private companion object {
        // `~` before `/`, matching RFC 6901, so a literal `~1` in a token isn't double-escaped.
        fun escape(token: String): String = token.replace("~", "~0").replace("/", "~1")
    }
}
