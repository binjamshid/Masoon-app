package masoon.curriculum

/**
 * A single JSON Schema validation failure produced by [JSONSchemaValidator].
 *
 * EQUIVALENCE BAR (see the header comment in `JSONSchemaValidator.kt`): callers must not depend
 * on [message] matching ajv's wording verbatim — only on [path] pointing at the same location in
 * the instance document ajv would flag, and on `List<SchemaViolation>` being empty exactly when
 * ajv would report valid. [keyword] is this validator's own name for the failing JSON Schema
 * keyword (e.g. `"required"`, `"pattern"`, `"oneOf"`), not necessarily ajv's internal `schemaPath`.
 */
data class SchemaViolation(
    /**
     * Where in the INSTANCE document the violation occurred (mirrors ajv's `instancePath`).
     * Points at the object/array/value that failed — for a `required` failure this is the
     * containing object, not the missing key.
     */
    val path: JSONPointer,
    /** The JSON Schema keyword that produced this violation. */
    val keyword: String,
    /** Human-readable, non-normative explanation. Not wire-compatible with ajv's `message`. */
    val message: String,
) {
    override fun toString(): String {
        val where = path.toString().ifEmpty { "(root)" }
        return "$where: $message [$keyword]"
    }
}
