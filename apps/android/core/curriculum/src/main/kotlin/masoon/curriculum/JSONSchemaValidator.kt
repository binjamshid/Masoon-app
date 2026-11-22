package masoon.curriculum

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * MasoonSchema -- a fail-closed JSON Schema SUBSET validator, implemented natively (Kotlin port of
 * `apps/ios/Packages/Sources/MasoonCurriculum/JSONSchemaValidator.swift`) so a curriculum-builder
 * UI can validate a draft curriculum without bundling a full JSON Schema engine or a large
 * ajv-style test corpus.
 *
 * SCOPE: this validator implements EXACTLY the keywords `contracts/json-schema/curriculum-v1.schema.json`
 * actually uses -- nothing more. Two disjoint sets, both derived by walking that file:
 *
 *   VALIDATING (constrain what a document must look like -- implemented below):
 *     type, required, properties, additionalProperties, propertyNames, minProperties, enum,
 *     const, oneOf, anyOf, not, if, then, pattern, minLength, minItems, uniqueItems, minimum,
 *     maximum, exclusiveMinimum, items, $ref, $defs
 *
 *   ANNOTATION-ONLY (recognized so the schema itself compiles, but never affect a pass/fail
 *   verdict): $schema, $id, title, description, default. ("title" is the one exception with
 *   observable behavior: this schema's `not` clauses use it to carry the reserved-keyword
 *   message, e.g. "Selector key 'srs_pool' is reserved for future version..." -- see `not`
 *   handling below.)
 *
 * Any OTHER keyword encountered while compiling a schema document -- anywhere, including inside
 * `$defs` -- makes [JSONSchemaValidator]'s constructor THROW [JSONSchemaError.UnsupportedKeyword]
 * rather than silently ignore it. This is the fail-closed property the work item asked for: a
 * curriculum that would pass this validator but fail the real ajv-compiled schema (or vice versa)
 * is a real bug, so MasoonSchema must never claim to support more than it actually implements.
 * `maxLength`, `maxItems`, `maxProperties`, `exclusiveMaximum`, `allOf`, `patternProperties`,
 * tuple-form `items`, and array-form `type` are all NOT used by curriculum-v1 today and are
 * therefore all correctly unsupported -- adding any of them to the schema must fail this
 * validator's construction until this file is updated too.
 *
 * EQUIVALENCE BAR: MasoonSchema does not aim for byte-equal ajv error text (that would pin it to
 * ajv's internal wording and break on any ajv version bump). It aims for:
 *   - VERDICT-EXACT: same pass/fail as ajv for the same instance.
 *   - INSTANCE-PATH CONTAINMENT: [SchemaViolation.path] points at the same location in the
 *     instance document ajv's `instancePath` would, even when the message wording differs.
 *
 * TWO CORRECTNESS REQUIREMENTS called out explicitly by the CB-3 work item (ported unchanged):
 *
 * 1. `"type": "integer"` vs `"type": "number"` is judged off the RAW JSON TOKEN's lexical form
 *    ([isIntegerToken], below), not off a parsed `Double`. `kotlinx.serialization.json.JsonPrimitive.content`
 *    already keeps the original token text for a number literal (the parser never re-serializes
 *    it), so no separate tokenizer is needed here either -- the same property Swift's
 *    `JSONValue.number(String)` relies on. `25` is an integer token; `25.0` and `25e0` are not,
 *    even though all three carry the same numeric value. This deliberately protects the (future)
 *    on-device builder's own JSON output: a Double-typed form field can serialize `"25.0"` for a
 *    field the schema declares `type: integer`, and MasoonSchema is meant to catch that mismatch,
 *    not silently accept it because `25.0 == 25` as a `Double`. (`enum`/`const` equality, by
 *    contrast, compares by numeric VALUE via [jsonEqual] below -- that distinction is
 *    `type`-specific, not a general "numbers never compare equal across tokens" rule.)
 *
 * 2. When `oneOf` (or `anyOf`) has no matching branch, MasoonSchema reports the CLOSEST-MATCHING
 *    branch's own sub-violations instead of a generic "no branch matched". Heuristic
 *    ([topLevelMatchScore], [closestBranch]): for each branch, first score how well the instance
 *    matches that branch's OWN top-level `type` and `required` -- one point if `type` matches,
 *    plus one point per `required` key the instance actually has -- and rank branches by that
 *    score, DESCENDING; only break a tie by picking the branch with the FEWEST total violations,
 *    and break any remaining tie by EARLIEST branch index.
 *
 *    Plain "fewest violations" alone was tried (in the Swift port) and rejected: curriculum-v1's
 *    `EvidenceSpec` mixes a trivial single-check branch (`{"const": "self_check"}`, always exactly
 *    1 violation for any non-string instance, no matter how well-shaped) with structural branches
 *    like `timer`/`counter`/`teacher_verification`. Pure violation-counting lets that trivial
 *    branch win almost every tie against a deeper, more relevant structural branch -- the opposite
 *    of "closest". Scoring the top-level shape match FIRST fixes this: an instance shaped like
 *    `{"timer": {}}` scores 2 on the `timer` branch (type:object matches, plus `timer` is present)
 *    and only 1 on every other branch, so `timer` wins outright regardless of how many violations
 *    its nested `min_seconds` check produces.
 */
class JSONSchemaValidator(schemaDocument: JsonElement) {
    private val root: CompiledSchema
    private val defs: Map<String, CompiledSchema>

    init {
        val obj = schemaDocument.asObjectOrNull()
            ?: throw JSONSchemaError.MalformedSchema("schema document root must be an object", JSONPointer())
        val defsJson = obj["\$defs"]?.asObjectOrNull() ?: JsonObject(emptyMap())
        val knownDefNames = defsJson.keys

        val compiledDefs = LinkedHashMap<String, CompiledSchema>()
        for ((name, defJson) in defsJson) {
            compiledDefs[name] = compileSchema(defJson, JSONPointer(listOf("\$defs", name)), knownDefNames)
        }
        defs = compiledDefs
        root = compileSchema(schemaDocument, JSONPointer(), knownDefNames)
    }

    /**
     * Validates [instance] against the compiled schema. Returns an empty list iff the document is
     * valid -- this is the normal, expected outcome for most calls, so it returns rather than
     * throws (unlike the constructor, which throws only for the exceptional/programmer-error case
     * of a schema this validator does not understand).
     */
    fun validate(instance: JsonElement): List<SchemaViolation> = validateSchema(root, instance, JSONPointer(), defs)

    companion object {
        /**
         * Convenience for loading a schema document straight from JSON text (mirrors
         * `CurriculumLoader.load(text: String)`'s own text-in convention elsewhere in this
         * module -- the Kotlin analogue of Swift's `init(schemaBytes: [UInt8])`; kotlinx
         * serialization parses from `String`, not a byte array, so this takes text directly).
         */
        fun fromSchemaText(schemaText: String): JSONSchemaValidator =
            JSONSchemaValidator(Json.parseToJsonElement(schemaText))
    }
}

/**
 * Fail-closed compile-time errors: the SCHEMA document itself (not the instance being validated)
 * is something MasoonSchema cannot faithfully represent. Never thrown by `validate(_:)` -- an
 * invalid INSTANCE is a normal, expected outcome reported via `List<SchemaViolation>`, not an
 * exception.
 */
sealed class JSONSchemaError(message: String) : Exception(message) {
    /**
     * The schema uses a JSON Schema keyword this validator does not implement (see the
     * enumerated set in the file header). Fail-closed: silently ignoring the keyword could make
     * an unsafe document pass.
     */
    class UnsupportedKeyword(val keyword: String, val path: JSONPointer) :
        JSONSchemaError(
            "MasoonSchema: unsupported JSON Schema keyword '$keyword' at $path " +
                "-- refusing to compile this schema (fail-closed)",
        )

    class MalformedSchema(val detail: String, val path: JSONPointer) :
        JSONSchemaError("MasoonSchema: malformed schema at $path: $detail")
}

// ---------------------------------------------------------------------------------------------
// Compiled schema representation
// ---------------------------------------------------------------------------------------------

/**
 * A compiled schema node. [SchemaNode] fields are all null/empty by default; every keyword in a
 * schema OBJECT sets at most one field, and validation ANDs together whichever fields are
 * non-null (JSON Schema's normal "all present keywords apply" semantics -- this is how e.g.
 * `SessionAnchor`'s sibling `not` + `oneOf` combine).
 */
private sealed interface CompiledSchema {
    /**
     * A JSON Schema boolean schema: `true` (always valid) or `false` (never valid). Used by
     * curriculum-v1 for reserved-keyword not-clauses (`"properties": { "srs_pool": true }`) and
     * `VariableDef`'s `"then": { "properties": { "values": true } }`.
     */
    data class Literal(val value: Boolean) : CompiledSchema
    data class Node(val node: SchemaNode) : CompiledSchema
}

private class SchemaNode {
    /**
     * `$ref` target name (already validated to exist in `$defs` at compile time). 2020-12 allows
     * `$ref` to sit alongside sibling keywords (curriculum-v1's `RuleWhen.enabled` pairs it with a
     * `description` annotation) so this is a field on the node, not a separate [CompiledSchema]
     * case -- resolution ANDs with everything else on the node.
     */
    var ref: String? = null
    var title: String? = null

    var type: String? = null
    var required: List<String> = emptyList()
    var properties: Map<String, CompiledSchema> = emptyMap()
    var additionalProperties: CompiledSchema? = null
    var propertyNames: CompiledSchema? = null
    var minProperties: Int? = null
    var enumValues: List<JsonElement>? = null
    var constValue: JsonElement? = null
    var oneOf: List<CompiledSchema>? = null
    var anyOf: List<CompiledSchema>? = null
    var not: CompiledSchema? = null
    var ifSchema: CompiledSchema? = null
    var thenSchema: CompiledSchema? = null
    var patternSource: String? = null
    var pattern: Regex? = null
    var minLength: Int? = null
    var minItems: Int? = null
    var uniqueItems: Boolean? = null
    var minimum: Double? = null
    var maximum: Double? = null
    var exclusiveMinimum: Double? = null
    var items: CompiledSchema? = null
}

// ---------------------------------------------------------------------------------------------
// JsonElement helpers (kotlinx.serialization has no first-class object/array/string/bool/number
// discriminated union the way Swift's JSONValue does -- JsonPrimitive covers string/number/bool
// alike, distinguished by `isString` plus, for non-string, the raw token text).
// ---------------------------------------------------------------------------------------------

private fun JsonElement.asObjectOrNull(): JsonObject? = this as? JsonObject
private fun JsonElement.asArrayOrNull(): JsonArray? = this as? JsonArray
private fun JsonElement.asStringOrNull(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

/** The raw token text of a non-string primitive (a JSON number OR boolean literal), else null. */
private fun JsonElement.asNonStringTokenOrNull(): String? = (this as? JsonPrimitive)?.takeIf { !it.isString }?.content

private fun isBooleanToken(token: String): Boolean = token == "true" || token == "false"

private fun JsonElement.asBoolLiteralOrNull(): Boolean? =
    asNonStringTokenOrNull()?.takeIf { isBooleanToken(it) }?.let { it == "true" }

private fun JsonElement.asIntOrNull(): Int? = asNonStringTokenOrNull()?.takeIf { !isBooleanToken(it) }?.toIntOrNull()

private fun JsonElement.asNumberTokenOrNull(): String? = asNonStringTokenOrNull()?.takeIf { !isBooleanToken(it) }

/**
 * Requirement #1 (CB-3) -- see the file header. [token] is the RAW decimal text kotlinx
 * serialization preserved from parsing (never a re-serialized `Double`).
 */
internal fun isIntegerToken(token: String): Boolean = !(token.contains(".") || token.contains("e") || token.contains("E"))

private val knownTypes: Set<String> = setOf("object", "array", "string", "number", "integer", "boolean", "null")

// ---------------------------------------------------------------------------------------------
// Compilation
// ---------------------------------------------------------------------------------------------

private fun defName(ref: String): String? {
    val prefix = "#/\$defs/"
    if (!ref.startsWith(prefix)) return null
    val name = ref.removePrefix(prefix)
    return if (name.isEmpty() || "/" in name) null else name
}

private fun compileSchema(json: JsonElement, path: JSONPointer, knownDefNames: Set<String>): CompiledSchema {
    json.asBoolLiteralOrNull()?.let { return CompiledSchema.Literal(it) }
    val obj = json.asObjectOrNull()
        ?: throw JSONSchemaError.MalformedSchema("schema must be an object or a boolean", path)

    val node = SchemaNode()
    for (key in obj.keys.sorted()) {
        val value = obj.getValue(key)
        when (key) {
            // Annotation-only: recognized, never affect the verdict.
            "\$schema", "\$id", "description", "default", "\$defs" -> Unit

            "title" -> node.title = value.asStringOrNull()

            "\$ref" -> {
                val refStr = value.asStringOrNull()
                val name = refStr?.let(::defName)
                    ?: throw JSONSchemaError.MalformedSchema(
                        "\$ref must be a string of the form '#/\$defs/<Name>', got $value",
                        path.appending("\$ref"),
                    )
                if (name !in knownDefNames) {
                    throw JSONSchemaError.MalformedSchema(
                        "\$ref target '$name' not found in \$defs",
                        path.appending("\$ref"),
                    )
                }
                node.ref = name
            }

            "type" -> {
                val t = value.asStringOrNull()
                if (t == null || t !in knownTypes) {
                    throw JSONSchemaError.MalformedSchema(
                        "type must be one of ${knownTypes.sorted()}, got $value",
                        path.appending("type"),
                    )
                }
                node.type = t
            }

            "required" -> {
                val arr = value.asArrayOrNull()
                    ?: throw JSONSchemaError.MalformedSchema("required must be an array", path.appending("required"))
                node.required = arr.map {
                    it.asStringOrNull()
                        ?: throw JSONSchemaError.MalformedSchema(
                            "required items must be strings",
                            path.appending("required"),
                        )
                }
            }

            "properties" -> {
                val propsObj = value.asObjectOrNull()
                    ?: throw JSONSchemaError.MalformedSchema("properties must be an object", path.appending("properties"))
                node.properties = propsObj.mapValues { (name, sub) ->
                    compileSchema(sub, path.appending("properties").appending(name), knownDefNames)
                }
            }

            "additionalProperties" ->
                node.additionalProperties = compileSchema(value, path.appending("additionalProperties"), knownDefNames)

            "propertyNames" ->
                node.propertyNames = compileSchema(value, path.appending("propertyNames"), knownDefNames)

            "minProperties" -> node.minProperties = value.asIntOrNull()
                ?: throw JSONSchemaError.MalformedSchema("minProperties must be an integer", path.appending("minProperties"))

            "enum" -> node.enumValues = value.asArrayOrNull()?.toList()
                ?: throw JSONSchemaError.MalformedSchema("enum must be an array", path.appending("enum"))

            "const" -> node.constValue = value

            "oneOf" -> {
                val arr = value.asArrayOrNull()
                    ?: throw JSONSchemaError.MalformedSchema("oneOf must be an array", path.appending("oneOf"))
                node.oneOf = arr.mapIndexed { i, sub ->
                    compileSchema(sub, path.appending("oneOf").appending(i), knownDefNames)
                }
            }

            "anyOf" -> {
                val arr = value.asArrayOrNull()
                    ?: throw JSONSchemaError.MalformedSchema("anyOf must be an array", path.appending("anyOf"))
                node.anyOf = arr.mapIndexed { i, sub ->
                    compileSchema(sub, path.appending("anyOf").appending(i), knownDefNames)
                }
            }

            "not" -> node.not = compileSchema(value, path.appending("not"), knownDefNames)
            "if" -> node.ifSchema = compileSchema(value, path.appending("if"), knownDefNames)
            "then" -> node.thenSchema = compileSchema(value, path.appending("then"), knownDefNames)

            "pattern" -> {
                val p = value.asStringOrNull()
                    ?: throw JSONSchemaError.MalformedSchema("pattern must be a string", path.appending("pattern"))
                node.patternSource = p
                node.pattern = try {
                    Regex(p)
                } catch (e: Exception) {
                    throw JSONSchemaError.MalformedSchema(
                        "invalid regex in pattern '$p': ${e.message}",
                        path.appending("pattern"),
                    )
                }
            }

            "minLength" -> node.minLength = value.asIntOrNull()
                ?: throw JSONSchemaError.MalformedSchema("minLength must be an integer", path.appending("minLength"))

            "minItems" -> node.minItems = value.asIntOrNull()
                ?: throw JSONSchemaError.MalformedSchema("minItems must be an integer", path.appending("minItems"))

            "uniqueItems" -> node.uniqueItems = value.asBoolLiteralOrNull()
                ?: throw JSONSchemaError.MalformedSchema("uniqueItems must be a boolean", path.appending("uniqueItems"))

            "minimum" -> node.minimum = value.asNumberTokenOrNull()?.toDoubleOrNull()
                ?: throw JSONSchemaError.MalformedSchema("minimum must be a number", path.appending("minimum"))

            "maximum" -> node.maximum = value.asNumberTokenOrNull()?.toDoubleOrNull()
                ?: throw JSONSchemaError.MalformedSchema("maximum must be a number", path.appending("maximum"))

            "exclusiveMinimum" -> node.exclusiveMinimum = value.asNumberTokenOrNull()?.toDoubleOrNull()
                ?: throw JSONSchemaError.MalformedSchema(
                    "exclusiveMinimum must be a number",
                    path.appending("exclusiveMinimum"),
                )

            "items" -> node.items = compileSchema(value, path.appending("items"), knownDefNames)

            else ->
                // Fail-closed: this is the whole point of MasoonSchema. A keyword the schema uses
                // that we have not implemented must never be silently ignored.
                throw JSONSchemaError.UnsupportedKeyword(key, path.appending(key))
        }
    }
    return CompiledSchema.Node(node)
}

// ---------------------------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------------------------

private fun validateSchema(
    schema: CompiledSchema,
    instance: JsonElement,
    path: JSONPointer,
    defs: Map<String, CompiledSchema>,
): List<SchemaViolation> = when (schema) {
    is CompiledSchema.Literal -> if (schema.value) {
        emptyList()
    } else {
        listOf(SchemaViolation(path, "false", "no instance is valid against schema `false`"))
    }

    is CompiledSchema.Node -> {
        val node = schema.node
        val violations = mutableListOf<SchemaViolation>()

        node.ref?.let { refName -> defs[refName]?.let { target -> violations += validateSchema(target, instance, path, defs) } }

        node.type?.let { t ->
            if (!typeMatches(t, instance)) violations += SchemaViolation(path, "type", "must be $t")
        }

        if (node.required.isNotEmpty() && instance is JsonObject) {
            for (key in node.required) {
                if (key !in instance) {
                    violations += SchemaViolation(path, "required", "must have required property '$key'")
                }
            }
        }

        if (instance is JsonObject) {
            for ((name, subschema) in node.properties) {
                instance[name]?.let { v -> violations += validateSchema(subschema, v, path.appending(name), defs) }
            }
            node.additionalProperties?.let { ap ->
                val known = node.properties.keys
                for (name in instance.keys.sorted()) {
                    if (name in known) continue
                    when (ap) {
                        is CompiledSchema.Literal -> if (!ap.value) {
                            violations += SchemaViolation(
                                path.appending(name), "additionalProperties",
                                "must NOT have additional property '$name'",
                            )
                        }
                        is CompiledSchema.Node ->
                            violations += validateSchema(ap, instance.getValue(name), path.appending(name), defs)
                    }
                }
            }
            node.propertyNames?.let { pn ->
                for (name in instance.keys.sorted()) {
                    val sub = validateSchema(pn, JsonPrimitive(name), path.appending(name), defs)
                    violations += sub.map {
                        SchemaViolation(it.path, "propertyNames", "property name '$name' ${it.message}")
                    }
                }
            }
            node.minProperties?.let { mp ->
                if (instance.size < mp) {
                    violations += SchemaViolation(path, "minProperties", "must have at least $mp properties")
                }
            }
        }

        node.enumValues?.let { vals ->
            if (vals.none { jsonEqual(it, instance) }) {
                violations += SchemaViolation(path, "enum", "must be one of the enumerated values")
            }
        }
        node.constValue?.let { cv ->
            if (!jsonEqual(cv, instance)) violations += SchemaViolation(path, "const", "must equal the constant value")
        }

        node.oneOf?.let { branches -> violations += validateOneOf(branches, instance, path, defs) }
        node.anyOf?.let { branches -> violations += validateAnyOf(branches, instance, path, defs) }
        node.not?.let { notSchema ->
            if (validateSchema(notSchema, instance, path, defs).isEmpty()) {
                val message = (notSchema as? CompiledSchema.Node)?.node?.title ?: "must NOT match the schema"
                violations += SchemaViolation(path, "not", message)
            }
        }
        val ifSchema = node.ifSchema
        val thenSchema = node.thenSchema
        if (ifSchema != null && thenSchema != null) {
            if (validateSchema(ifSchema, instance, path, defs).isEmpty()) {
                violations += validateSchema(thenSchema, instance, path, defs)
            }
        }

        if (instance is JsonPrimitive && instance.isString) {
            val s = instance.content
            val re = node.pattern
            if (node.patternSource != null && re != null && !re.containsMatchIn(s)) {
                violations += SchemaViolation(path, "pattern", "must match pattern \"${node.patternSource}\"")
            }
            node.minLength?.let { minLen ->
                if (s.codePointCount(0, s.length) < minLen) {
                    violations += SchemaViolation(path, "minLength", "must be at least $minLen character(s)")
                }
            }
        }

        if (instance is JsonArray) {
            node.minItems?.let { minItemsN ->
                if (instance.size < minItemsN) {
                    violations += SchemaViolation(path, "minItems", "must have at least $minItemsN item(s)")
                }
            }
            if (node.uniqueItems == true) {
                val seen = mutableListOf<JsonElement>()
                instance.forEachIndexed { i, el ->
                    if (seen.any { jsonEqual(it, el) }) {
                        violations += SchemaViolation(path.appending(i), "uniqueItems", "must NOT have duplicate items")
                    } else {
                        seen += el
                    }
                }
            }
            node.items?.let { itemsSchema ->
                instance.forEachIndexed { i, el -> violations += validateSchema(itemsSchema, el, path.appending(i), defs) }
            }
        }

        if (instance is JsonPrimitive && !instance.isString && !isBooleanToken(instance.content)) {
            val d = instance.content.toDoubleOrNull()
            if (d != null) {
                node.minimum?.let { minV -> if (d < minV) violations += SchemaViolation(path, "minimum", "must be >= $minV") }
                node.maximum?.let { maxV -> if (d > maxV) violations += SchemaViolation(path, "maximum", "must be <= $maxV") }
                node.exclusiveMinimum?.let { exMin ->
                    if (d <= exMin) violations += SchemaViolation(path, "exclusiveMinimum", "must be > $exMin")
                }
            }
        }

        violations
    }
}

/**
 * Requirement #2 (CB-3): when `oneOf` has no matching branch, report the CLOSEST-MATCHING
 * branch's own violations rather than a generic "no branch matched". See the file header for the
 * ranking heuristic.
 */
private fun validateOneOf(
    branches: List<CompiledSchema>,
    instance: JsonElement,
    path: JSONPointer,
    defs: Map<String, CompiledSchema>,
): List<SchemaViolation> {
    val results = branches.map { validateSchema(it, instance, path, defs) }
    val passing = results.indices.filter { results[it].isEmpty() }
    if (passing.size == 1) return emptyList()
    if (passing.size > 1) {
        return listOf(
            SchemaViolation(
                path, "oneOf",
                "must match exactly one schema in oneOf, but matched ${passing.size} (branches $passing)",
            ),
        )
    }
    val bestIndex = closestBranch(branches, results, instance)
        ?: return listOf(SchemaViolation(path, "oneOf", "oneOf has no branches"))
    return results[bestIndex].map { v ->
        SchemaViolation(v.path, "oneOf", "closest oneOf branch (#$bestIndex) failed: ${v.message} [${v.keyword}]")
    }
}

/**
 * Same closest-branch reporting as `oneOf`, applied to `anyOf` (used only by `VariableDef.default`
 * today, but the same "no branch matched" gap would apply there too).
 */
private fun validateAnyOf(
    branches: List<CompiledSchema>,
    instance: JsonElement,
    path: JSONPointer,
    defs: Map<String, CompiledSchema>,
): List<SchemaViolation> {
    val results = branches.map { validateSchema(it, instance, path, defs) }
    if (results.any { it.isEmpty() }) return emptyList()
    val bestIndex = closestBranch(branches, results, instance)
        ?: return listOf(SchemaViolation(path, "anyOf", "anyOf has no branches"))
    return results[bestIndex].map { v ->
        SchemaViolation(v.path, "anyOf", "closest anyOf branch (#$bestIndex) failed: ${v.message} [${v.keyword}]")
    }
}

/**
 * Ranks failing branches by [topLevelMatchScore] (descending), then by violation count
 * (ascending), then by index (ascending -- the loop only replaces `best` on a STRICT improvement,
 * so the first branch keeps a full tie).
 */
private fun closestBranch(branches: List<CompiledSchema>, results: List<List<SchemaViolation>>, instance: JsonElement): Int? {
    if (branches.isEmpty()) return null
    var best = 0
    var bestScore = topLevelMatchScore(branches[0], instance)
    for (i in 1 until branches.size) {
        val score = topLevelMatchScore(branches[i], instance)
        if (score > bestScore || (score == bestScore && results[i].size < results[best].size)) {
            best = i
            bestScore = score
        }
    }
    return best
}

/**
 * How well [instance]'s shape matches [schema]'s OWN top-level `type` and `required` -- see the
 * file header for the rationale. Only looks at the immediate node (curriculum-v1's oneOf/anyOf
 * branches are always inline object schemas, never a bare `$ref`, so one level is enough).
 */
private fun topLevelMatchScore(schema: CompiledSchema, instance: JsonElement): Int {
    val node = (schema as? CompiledSchema.Node)?.node ?: return 0
    var score = 0
    node.type?.let { t -> if (typeMatches(t, instance)) score += 1 }
    if (node.required.isNotEmpty() && instance is JsonObject) {
        score += node.required.count { it in instance }
    }
    node.constValue?.let { cv -> if (jsonEqual(cv, instance)) score += 1 }
    return score
}

private fun typeMatches(type: String, instance: JsonElement): Boolean = when (type) {
    "object" -> instance is JsonObject
    "array" -> instance is JsonArray
    "string" -> instance is JsonPrimitive && instance.isString
    "boolean" -> instance is JsonPrimitive && !instance.isString && isBooleanToken(instance.content)
    "null" -> instance is JsonNull
    "number" -> instance is JsonPrimitive && !instance.isString && !isBooleanToken(instance.content)
    "integer" ->
        instance is JsonPrimitive && !instance.isString && !isBooleanToken(instance.content) &&
            isIntegerToken(instance.content)
    else -> false
}

/**
 * JSON Schema `enum`/`const` equality: by VALUE, not by raw token -- the opposite of
 * [isIntegerToken] above, which is specifically about the `type` keyword. `"25"` and `"25.0"` are
 * different tokens (so `25.0` fails `type: integer`) but the same NUMBER (so they satisfy the
 * same `const: 25`), matching ajv's deep-equal-on-parsed-JSON semantics.
 */
private fun jsonEqual(a: JsonElement, b: JsonElement): Boolean = when {
    a is JsonNull && b is JsonNull -> true
    a is JsonPrimitive && b is JsonPrimitive -> when {
        a.isString != b.isString -> false
        a.isString -> a.content == b.content
        a.content == b.content -> true
        else -> {
            val da = a.content.toDoubleOrNull()
            val db = b.content.toDoubleOrNull()
            da != null && db != null && da == db
        }
    }
    a is JsonArray && b is JsonArray ->
        a.size == b.size && a.indices.all { jsonEqual(a[it], b[it]) }
    a is JsonObject && b is JsonObject ->
        a.size == b.size && a.all { (k, v) -> b[k]?.let { jsonEqual(v, it) } == true }
    else -> false
}
