import MasoonDomain

/// MasoonSchema -- a fail-closed JSON Schema SUBSET validator, implemented
/// natively in Swift so the (future, Stage 6) on-device curriculum builder can
/// validate a draft curriculum without bundling a full JSON Schema engine or a
/// large ajv-style test corpus.
///
/// SCOPE: this validator implements EXACTLY the keywords
/// the curriculum-v1 schema uses -- nothing
/// more. Two disjoint sets, both derived by walking that file:
///
///   VALIDATING (constrain what a document must look like -- implemented below):
///     type, required, properties, additionalProperties, propertyNames,
///     minProperties, enum, const, oneOf, anyOf, not, if, then, pattern,
///     minLength, minItems, uniqueItems, minimum, maximum, exclusiveMinimum,
///     items, $ref, $defs
///
///   ANNOTATION-ONLY (recognized so the schema itself compiles, but never
///   affect a pass/fail verdict): $schema, $id, title, description, default.
///   ("title" is the one exception with observable behavior: this schema's
///   `not` clauses use it to carry the reserved-keyword message, e.g.
///   "Selector key is reserved for a future version"; see `not` handling below.)
///
/// Any OTHER keyword encountered while compiling a schema document -- anywhere,
/// including inside `$defs` -- makes `JSONSchemaValidator.init` THROW
/// `JSONSchemaError.unsupportedKeyword` rather than silently ignore it. This is
/// the fail-closed property: a curriculum that would
/// pass this validator but fail the real ajv-compiled schema (or vice versa) is
/// a real bug, so MasoonSchema must never claim to support more than it
/// actually implements. `maxLength`, `maxItems`, `maxProperties`,
/// `exclusiveMaximum`, `allOf`, `patternProperties`, tuple-form `items`, and
/// array-form `type` are all NOT used by curriculum-v1 today and are therefore
/// all correctly unsupported -- adding any of them to the schema must fail
/// this validator's construction until this file is updated too.
///
/// EQUIVALENCE BAR: MasoonSchema does not aim for byte-equal ajv error text
/// (that would pin it to ajv's internal wording and break on any ajv version
/// bump). It aims for:
///   - VERDICT-EXACT: same pass/fail as ajv for the same instance.
///   - INSTANCE-PATH CONTAINMENT: `SchemaViolation.path` points at the same
///     location in the instance document ajv's `instancePath` would, even
///     when the message wording differs.
///
/// Validation details:
///
/// 1. `"type": "integer"` vs `"type": "number"` is judged off the RAW JSON
///    TOKEN's lexical form (`isIntegerToken`, below), not off a parsed
///    `Double`. `MasoonDomain.JSONValue.number(String)` already keeps the
///    original token text (ENGINE_PARITY: "numbers are kept as their raw
///    decimal text so no binary floating point can influence emitted
///    values") -- that same property is reused here, so no separate
///    tokenizer was needed. `25` is an integer token; `25.0` and `25e0` are
///    not, even though all three carry the same numeric value. This
///    deliberately protects the (Stage 6) on-device builder's own JSON
///    output: a Double-typed form field can serialize `"25.0"` for a field
///    the schema declares `type: integer`, and MasoonSchema is meant to
///    catch that mismatch, not silently accept it because `25.0 == 25` as a
///    `Double`. (`enum`/`const` equality, by contrast, compares by numeric
///    VALUE via `jsonEqual` below -- that distinction is `type`-specific,
///    not a general "numbers never compare equal across tokens" rule. No
///    `enum`/`const` in curriculum-v1 is numeric today, so this path is
///    untested by the schema itself, but `jsonEqual` is exercised directly
///    by `JSONSchemaValidatorTests`.)
///
/// 2. When `oneOf` (or `anyOf`) has no matching branch, MasoonSchema reports
///    the CLOSEST-MATCHING branch's own sub-violations instead of a generic
///    "no branch matched". Heuristic (`topLevelMatchScore`, `validateOneOf`):
///    for each branch, first score how well the instance matches that
///    branch's OWN top-level `type` and `required` -- one point if `type`
///    matches, plus one point per `required` key the instance actually has --
///    and rank branches by that score, DESCENDING; only break a tie by
///    picking the branch with the FEWEST total violations, and break any
///    remaining tie by EARLIEST branch index.
///
///    Plain "fewest violations" alone was tried and rejected: curriculum-v1's
///    `EvidenceSpec` mixes a trivial single-check branch (`{"const":
///    "self_check"}`, always exactly 1 violation for any non-string instance,
///    no matter how well-shaped) with structural branches like
///    `timer`/`counter`/`teacher_verification`. Pure violation-counting lets
///    that trivial branch win almost every tie against a deeper, more
///    relevant structural branch -- the opposite of "closest". Scoring the
///    top-level shape match FIRST (i.e. "first branch whose top-level
///    type/required partially matches", generalized into a rank rather than a
///    literal first-hit) fixes this: an instance shaped like `{"timer": {}}`
///    scores 2 on the `timer` branch (type:object matches, plus `timer` is
///    present) and only 1 on every other branch (type:object matches, but
///    their own required key is absent), so `timer` wins outright regardless
///    of how many violations its nested `min_seconds` check produces. This is
///    what turns "no branch of oneOf matched" into e.g. "closest oneOf branch
///    (#1) failed: must have required property 'min_seconds' [required]"
///    instead of a report anchored on the unrelated `self_check` branch.
public final class JSONSchemaValidator {
    private let root: CompiledSchema
    private let defs: [String: CompiledSchema]

    /// Compiles `schemaDocument` (parsed JSON Schema, e.g. the contents of
    /// `curriculum-v1.schema.json`). Throws `JSONSchemaError` fail-closed if
    /// the document uses a keyword outside the enumerated set above, or is
    /// otherwise malformed (e.g. a `$ref` to a name absent from `$defs`).
    public init(schemaDocument: JSONValue) throws {
        guard let obj = schemaDocument.objectValue else {
            throw JSONSchemaError.malformedSchema("schema document root must be an object", path: JSONPointer())
        }
        let defsJSON = obj["$defs"]?.objectValue ?? [:]
        let knownDefNames = Set(defsJSON.keys)

        var compiledDefs: [String: CompiledSchema] = [:]
        for (name, defJSON) in defsJSON {
            compiledDefs[name] = try Self.compile(
                defJSON, path: JSONPointer(["$defs", name]), knownDefNames: knownDefNames)
        }
        self.defs = compiledDefs
        self.root = try Self.compile(schemaDocument, path: JSONPointer(), knownDefNames: knownDefNames)
    }

    /// Convenience for loading a schema document straight from bytes (mirrors
    /// `JSONParser.parse(bytes:)` / `CurriculumLoader.load(json:)` usage
    /// elsewhere in this target).
    public convenience init(schemaBytes: [UInt8]) throws {
        try self.init(schemaDocument: try JSONParser.parse(bytes: schemaBytes))
    }

    /// Validates `instance` against the compiled schema. Returns an empty
    /// array iff the document is valid -- this is the normal, expected
    /// outcome for most calls, so it returns rather than throws (unlike
    /// `init`, which throws only for the exceptional/programmer-error case of
    /// a schema this validator does not understand).
    public func validate(_ instance: JSONValue) -> [SchemaViolation] {
        Self.validate(root, instance, path: JSONPointer(), defs: defs)
    }

    // MARK: - Compiled schema representation

    /// A compiled schema node. `SchemaNode` fields are all optional/empty by
    /// default; every keyword in a schema OBJECT sets at most one field, and
    /// validation ANDs together whichever fields are non-nil (JSON Schema's
    /// normal "all present keywords apply" semantics -- this is how e.g.
    /// `SessionAnchor`'s sibling `not` + `oneOf` combine).
    indirect enum CompiledSchema {
        /// A JSON Schema boolean schema: `true` (always valid) or `false`
        /// (never valid). Used by curriculum-v1 for reserved-keyword
        /// not-clauses (`"properties": { "srs_pool": true }`) and
        /// `VariableDef`'s `"then": { "properties": { "values": true } }`.
        case literal(Bool)
        case node(SchemaNode)
    }

    struct SchemaNode {
        /// `$ref` target name (already validated to exist in `$defs` at
        /// compile time). 2020-12 allows `$ref` to sit alongside sibling
        /// keywords (curriculum-v1's `RuleWhen.enabled` pairs it with a
        /// `description` annotation) so this is a field on the node, not a
        /// separate `CompiledSchema` case -- resolution ANDs with everything
        /// else on the node.
        var ref: String?
        var title: String?

        var type: String?
        var required: [String] = []
        var properties: [String: CompiledSchema] = [:]
        var additionalProperties: CompiledSchema?
        var propertyNames: CompiledSchema?
        var minProperties: Int?
        var enumValues: [JSONValue]?
        var constValue: JSONValue?
        var oneOf: [CompiledSchema]?
        var anyOf: [CompiledSchema]?
        var not: CompiledSchema?
        var ifSchema: CompiledSchema?
        var thenSchema: CompiledSchema?
        var patternSource: String?
        var pattern: Regex<AnyRegexOutput>?
        var minLength: Int?
        var minItems: Int?
        var uniqueItems: Bool?
        var minimum: Double?
        var maximum: Double?
        var exclusiveMinimum: Double?
        var items: CompiledSchema?
    }

    // MARK: - Compilation

    private static let knownTypes: Set<String> = [
        "object", "array", "string", "number", "integer", "boolean", "null",
    ]

    private static func compile(
        _ json: JSONValue, path: JSONPointer, knownDefNames: Set<String>
    ) throws -> CompiledSchema {
        if let b = json.boolValue { return .literal(b) }
        guard let obj = json.objectValue else {
            throw JSONSchemaError.malformedSchema("schema must be an object or a boolean", path: path)
        }

        var node = SchemaNode()

        for key in obj.keys.sorted() {
            let value = obj[key]!
            switch key {
            // Annotation-only: recognized, never affect the verdict.
            case "$schema", "$id", "description", "default", "$defs":
                continue
            case "title":
                node.title = value.stringValue

            case "$ref":
                guard let refStr = value.stringValue, let name = Self.defName(fromRef: refStr) else {
                    throw JSONSchemaError.malformedSchema(
                        "$ref must be a string of the form '#/$defs/<Name>', got \(value)",
                        path: path.appending("$ref"))
                }
                guard knownDefNames.contains(name) else {
                    throw JSONSchemaError.malformedSchema(
                        "$ref target '\(name)' not found in $defs", path: path.appending("$ref"))
                }
                node.ref = name

            case "type":
                guard let t = value.stringValue, Self.knownTypes.contains(t) else {
                    throw JSONSchemaError.malformedSchema(
                        "type must be one of \(Self.knownTypes.sorted()), got \(value)", path: path.appending("type"))
                }
                node.type = t

            case "required":
                guard let arr = value.arrayValue else {
                    throw JSONSchemaError.malformedSchema("required must be an array", path: path.appending("required"))
                }
                var names: [String] = []
                for item in arr {
                    guard let s = item.stringValue else {
                        throw JSONSchemaError.malformedSchema(
                            "required items must be strings", path: path.appending("required"))
                    }
                    names.append(s)
                }
                node.required = names

            case "properties":
                guard let propsObj = value.objectValue else {
                    throw JSONSchemaError.malformedSchema("properties must be an object", path: path.appending("properties"))
                }
                var compiled: [String: CompiledSchema] = [:]
                for (name, sub) in propsObj {
                    compiled[name] = try compile(
                        sub, path: path.appending("properties").appending(name), knownDefNames: knownDefNames)
                }
                node.properties = compiled

            case "additionalProperties":
                node.additionalProperties = try compile(
                    value, path: path.appending("additionalProperties"), knownDefNames: knownDefNames)

            case "propertyNames":
                node.propertyNames = try compile(
                    value, path: path.appending("propertyNames"), knownDefNames: knownDefNames)

            case "minProperties":
                guard let n = value.intValue else {
                    throw JSONSchemaError.malformedSchema("minProperties must be an integer", path: path.appending("minProperties"))
                }
                node.minProperties = n

            case "enum":
                guard let arr = value.arrayValue else {
                    throw JSONSchemaError.malformedSchema("enum must be an array", path: path.appending("enum"))
                }
                node.enumValues = arr

            case "const":
                node.constValue = value

            case "oneOf":
                guard let arr = value.arrayValue else {
                    throw JSONSchemaError.malformedSchema("oneOf must be an array", path: path.appending("oneOf"))
                }
                node.oneOf = try arr.enumerated().map { i, sub in
                    try compile(sub, path: path.appending("oneOf").appending(index: i), knownDefNames: knownDefNames)
                }

            case "anyOf":
                guard let arr = value.arrayValue else {
                    throw JSONSchemaError.malformedSchema("anyOf must be an array", path: path.appending("anyOf"))
                }
                node.anyOf = try arr.enumerated().map { i, sub in
                    try compile(sub, path: path.appending("anyOf").appending(index: i), knownDefNames: knownDefNames)
                }

            case "not":
                node.not = try compile(value, path: path.appending("not"), knownDefNames: knownDefNames)

            case "if":
                node.ifSchema = try compile(value, path: path.appending("if"), knownDefNames: knownDefNames)

            case "then":
                node.thenSchema = try compile(value, path: path.appending("then"), knownDefNames: knownDefNames)

            case "pattern":
                guard let p = value.stringValue else {
                    throw JSONSchemaError.malformedSchema("pattern must be a string", path: path.appending("pattern"))
                }
                node.patternSource = p
                do {
                    node.pattern = try Regex(p)
                } catch {
                    throw JSONSchemaError.malformedSchema(
                        "invalid regex in pattern '\(p)': \(error)", path: path.appending("pattern"))
                }

            case "minLength":
                guard let n = value.intValue else {
                    throw JSONSchemaError.malformedSchema("minLength must be an integer", path: path.appending("minLength"))
                }
                node.minLength = n

            case "minItems":
                guard let n = value.intValue else {
                    throw JSONSchemaError.malformedSchema("minItems must be an integer", path: path.appending("minItems"))
                }
                node.minItems = n

            case "uniqueItems":
                guard let b = value.boolValue else {
                    throw JSONSchemaError.malformedSchema("uniqueItems must be a boolean", path: path.appending("uniqueItems"))
                }
                node.uniqueItems = b

            case "minimum":
                guard let d = Self.numericLiteral(value) else {
                    throw JSONSchemaError.malformedSchema("minimum must be a number", path: path.appending("minimum"))
                }
                node.minimum = d

            case "maximum":
                guard let d = Self.numericLiteral(value) else {
                    throw JSONSchemaError.malformedSchema("maximum must be a number", path: path.appending("maximum"))
                }
                node.maximum = d

            case "exclusiveMinimum":
                guard let d = Self.numericLiteral(value) else {
                    throw JSONSchemaError.malformedSchema("exclusiveMinimum must be a number", path: path.appending("exclusiveMinimum"))
                }
                node.exclusiveMinimum = d

            case "items":
                node.items = try compile(value, path: path.appending("items"), knownDefNames: knownDefNames)

            default:
                // Fail-closed: this is the whole point of MasoonSchema. A
                // keyword the schema uses that we have not implemented must
                // never be silently ignored.
                throw JSONSchemaError.unsupportedKeyword(key, path: path.appending(key))
            }
        }

        return .node(node)
    }

    private static func defName(fromRef ref: String) -> String? {
        let prefix = "#/$defs/"
        guard ref.hasPrefix(prefix) else { return nil }
        let name = String(ref.dropFirst(prefix.count))
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return name
    }

    private static func numericLiteral(_ json: JSONValue) -> Double? {
        guard case .number(let token) = json else { return nil }
        return Double(token)
    }

    // MARK: - Validation

    private static func validate(
        _ schema: CompiledSchema, _ instance: JSONValue, path: JSONPointer, defs: [String: CompiledSchema]
    ) -> [SchemaViolation] {
        switch schema {
        case .literal(true):
            return []
        case .literal(false):
            return [SchemaViolation(path: path, keyword: "false", message: "no instance is valid against schema `false`")]
        case .node(let node):
            var violations: [SchemaViolation] = []

            if let refName = node.ref, let target = defs[refName] {
                violations += validate(target, instance, path: path, defs: defs)
            }

            if let t = node.type, !Self.typeMatches(t, instance) {
                violations.append(SchemaViolation(path: path, keyword: "type", message: "must be \(t)"))
            }

            if !node.required.isEmpty, case .object(let obj) = instance {
                for key in node.required where obj[key] == nil {
                    violations.append(SchemaViolation(
                        path: path, keyword: "required", message: "must have required property '\(key)'"))
                }
            }

            if case .object(let obj) = instance {
                for (name, subschema) in node.properties {
                    if let v = obj[name] {
                        violations += validate(subschema, v, path: path.appending(name), defs: defs)
                    }
                }
                if let ap = node.additionalProperties {
                    let known = Set(node.properties.keys)
                    for name in obj.keys.sorted() where !known.contains(name) {
                        switch ap {
                        case .literal(false):
                            violations.append(SchemaViolation(
                                path: path.appending(name), keyword: "additionalProperties",
                                message: "must NOT have additional property '\(name)'"))
                        case .literal(true):
                            break
                        case .node:
                            violations += validate(ap, obj[name]!, path: path.appending(name), defs: defs)
                        }
                    }
                }
                if let pn = node.propertyNames {
                    for name in obj.keys.sorted() {
                        let sub = validate(pn, .string(name), path: path.appending(name), defs: defs)
                        violations += sub.map {
                            SchemaViolation(path: $0.path, keyword: "propertyNames",
                                             message: "property name '\(name)' \($0.message)")
                        }
                    }
                }
                if let mp = node.minProperties, obj.count < mp {
                    violations.append(SchemaViolation(
                        path: path, keyword: "minProperties", message: "must have at least \(mp) properties"))
                }
            }

            if let vals = node.enumValues, !vals.contains(where: { Self.jsonEqual($0, instance) }) {
                violations.append(SchemaViolation(path: path, keyword: "enum", message: "must be one of the enumerated values"))
            }
            if let cv = node.constValue, !Self.jsonEqual(cv, instance) {
                violations.append(SchemaViolation(path: path, keyword: "const", message: "must equal the constant value"))
            }

            if let branches = node.oneOf {
                violations += Self.validateOneOf(branches, instance, path: path, defs: defs)
            }
            if let branches = node.anyOf {
                violations += Self.validateAnyOf(branches, instance, path: path, defs: defs)
            }
            if let notSchema = node.not {
                if Self.validate(notSchema, instance, path: path, defs: defs).isEmpty {
                    let message: String
                    if case .node(let n) = notSchema, let title = n.title {
                        message = title
                    } else {
                        message = "must NOT match the schema"
                    }
                    violations.append(SchemaViolation(path: path, keyword: "not", message: message))
                }
            }
            if let ifSchema = node.ifSchema, let thenSchema = node.thenSchema {
                if Self.validate(ifSchema, instance, path: path, defs: defs).isEmpty {
                    violations += Self.validate(thenSchema, instance, path: path, defs: defs)
                }
            }

            if case .string(let s) = instance {
                if let source = node.patternSource, let re = node.pattern, !s.contains(re) {
                    violations.append(SchemaViolation(
                        path: path, keyword: "pattern", message: "must match pattern \"\(source)\""))
                }
                if let minLen = node.minLength, s.unicodeScalars.count < minLen {
                    violations.append(SchemaViolation(
                        path: path, keyword: "minLength", message: "must be at least \(minLen) character(s)"))
                }
            }

            if case .array(let arr) = instance {
                if let minItemsN = node.minItems, arr.count < minItemsN {
                    violations.append(SchemaViolation(
                        path: path, keyword: "minItems", message: "must have at least \(minItemsN) item(s)"))
                }
                if node.uniqueItems == true {
                    var seen: [JSONValue] = []
                    for (i, el) in arr.enumerated() {
                        if seen.contains(where: { Self.jsonEqual($0, el) }) {
                            violations.append(SchemaViolation(
                                path: path.appending(index: i), keyword: "uniqueItems",
                                message: "must NOT have duplicate items"))
                        } else {
                            seen.append(el)
                        }
                    }
                }
                if let itemsSchema = node.items {
                    for (i, el) in arr.enumerated() {
                        violations += validate(itemsSchema, el, path: path.appending(index: i), defs: defs)
                    }
                }
            }

            if case .number(let token) = instance, let d = Double(token) {
                if let minV = node.minimum, d < minV {
                    violations.append(SchemaViolation(path: path, keyword: "minimum", message: "must be >= \(minV)"))
                }
                if let maxV = node.maximum, d > maxV {
                    violations.append(SchemaViolation(path: path, keyword: "maximum", message: "must be <= \(maxV)"))
                }
                if let exMin = node.exclusiveMinimum, d <= exMin {
                    violations.append(SchemaViolation(
                        path: path, keyword: "exclusiveMinimum", message: "must be > \(exMin)"))
                }
            }

            return violations
        }
    }

    /// Requirement #2 (CB-3): when `oneOf` has no matching branch, report the
    /// CLOSEST-MATCHING branch's own violations rather than a generic
    /// "no branch matched". See the file header for the ranking heuristic.
    private static func validateOneOf(
        _ branches: [CompiledSchema], _ instance: JSONValue, path: JSONPointer, defs: [String: CompiledSchema]
    ) -> [SchemaViolation] {
        let results = branches.map { validate($0, instance, path: path, defs: defs) }
        let passing = results.indices.filter { results[$0].isEmpty }
        if passing.count == 1 { return [] }
        if passing.count > 1 {
            return [SchemaViolation(
                path: path, keyword: "oneOf",
                message: "must match exactly one schema in oneOf, but matched \(passing.count) (branches \(passing))")]
        }
        guard let bestIndex = Self.closestBranch(branches, results, instance) else {
            return [SchemaViolation(path: path, keyword: "oneOf", message: "oneOf has no branches")]
        }
        return results[bestIndex].map { v in
            SchemaViolation(
                path: v.path, keyword: "oneOf",
                message: "closest oneOf branch (#\(bestIndex)) failed: \(v.message) [\(v.keyword)]")
        }
    }

    /// Same closest-branch reporting as `oneOf`, applied to `anyOf` (used only
    /// by `VariableDef.default` today, but the same "no branch matched" gap
    /// would apply there too).
    private static func validateAnyOf(
        _ branches: [CompiledSchema], _ instance: JSONValue, path: JSONPointer, defs: [String: CompiledSchema]
    ) -> [SchemaViolation] {
        let results = branches.map { validate($0, instance, path: path, defs: defs) }
        if results.contains(where: { $0.isEmpty }) { return [] }
        guard let bestIndex = Self.closestBranch(branches, results, instance) else {
            return [SchemaViolation(path: path, keyword: "anyOf", message: "anyOf has no branches")]
        }
        return results[bestIndex].map { v in
            SchemaViolation(
                path: v.path, keyword: "anyOf",
                message: "closest anyOf branch (#\(bestIndex)) failed: \(v.message) [\(v.keyword)]")
        }
    }

    /// Ranks failing branches by `topLevelMatchScore` (descending), then by
    /// violation count (ascending), then by index (ascending — the loop only
    /// replaces `best` on a STRICT improvement, so the first branch keeps a
    /// full tie). See the file header for why score comes before count.
    private static func closestBranch(
        _ branches: [CompiledSchema], _ results: [[SchemaViolation]], _ instance: JSONValue
    ) -> Int? {
        guard !branches.isEmpty else { return nil }
        var best = 0
        var bestScore = Self.topLevelMatchScore(branches[0], instance)
        for i in 1..<branches.count {
            let score = Self.topLevelMatchScore(branches[i], instance)
            if score > bestScore || (score == bestScore && results[i].count < results[best].count) {
                best = i
                bestScore = score
            }
        }
        return best
    }

    /// How well `instance`'s shape matches `schema`'s OWN top-level `type`
    /// and `required` — see the file header for the rationale. Only looks at
    /// the immediate node (curriculum-v1's oneOf/anyOf branches are always
    /// inline object schemas, never a bare `$ref`, so one level is enough).
    private static func topLevelMatchScore(_ schema: CompiledSchema, _ instance: JSONValue) -> Int {
        guard case .node(let node) = schema else { return 0 }
        var score = 0
        if let t = node.type, Self.typeMatches(t, instance) { score += 1 }
        if !node.required.isEmpty, case .object(let obj) = instance {
            score += node.required.filter { obj[$0] != nil }.count
        }
        if let cv = node.constValue, Self.jsonEqual(cv, instance) { score += 1 }
        return score
    }

    private static func typeMatches(_ type: String, _ instance: JSONValue) -> Bool {
        switch type {
        case "object": if case .object = instance { return true }; return false
        case "array": if case .array = instance { return true }; return false
        case "string": if case .string = instance { return true }; return false
        case "boolean": if case .bool = instance { return true }; return false
        case "null": if case .null = instance { return true }; return false
        case "number": if case .number = instance { return true }; return false
        case "integer":
            if case .number(let token) = instance { return Self.isIntegerToken(token) }
            return false
        default: return false
        }
    }

    /// Requirement #1 (CB-3) -- see the file header. `token` is the RAW
    /// decimal text `MasoonDomain.JSONValue.number` preserved from parsing
    /// (never a re-serialized `Double`).
    static func isIntegerToken(_ token: String) -> Bool {
        !(token.contains(".") || token.contains("e") || token.contains("E"))
    }

    /// JSON Schema `enum`/`const` equality: by VALUE, not by raw token -- the
    /// opposite of `isIntegerToken` above, which is specifically about the
    /// `type` keyword. `"25"` and `"25.0"` are different tokens (so `25.0`
    /// fails `type: integer`) but the same NUMBER (so they satisfy the same
    /// `const: 25`), matching ajv's deep-equal-on-parsed-JSON semantics.
    private static func jsonEqual(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.number(let x), .number(let y)):
            if x == y { return true }
            guard let dx = Double(x), let dy = Double(y) else { return false }
            return dx == dy
        case (.array(let x), .array(let y)):
            guard x.count == y.count else { return false }
            return zip(x, y).allSatisfy { jsonEqual($0, $1) }
        case (.object(let x), .object(let y)):
            guard x.count == y.count else { return false }
            for (k, v) in x {
                guard let yv = y[k], jsonEqual(v, yv) else { return false }
            }
            return true
        default:
            return false
        }
    }
}

/// Fail-closed compile-time errors: the SCHEMA document itself (not the
/// instance being validated) is something MasoonSchema cannot faithfully
/// represent. Never thrown by `validate(_:)` -- an invalid INSTANCE is a
/// normal, expected outcome reported via `[SchemaViolation]`, not an `Error`.
public enum JSONSchemaError: Error, Equatable, CustomStringConvertible {
    /// The schema uses a JSON Schema keyword this validator does not
    /// implement (see the enumerated set in the file header). Fail-closed:
    /// silently ignoring the keyword could make an unsafe document pass.
    case unsupportedKeyword(String, path: JSONPointer)
    case malformedSchema(String, path: JSONPointer)

    public var description: String {
        switch self {
        case .unsupportedKeyword(let keyword, let path):
            return "MasoonSchema: unsupported JSON Schema keyword '\(keyword)' at \(path) " +
                "-- refusing to compile this schema (fail-closed)"
        case .malformedSchema(let message, let path):
            return "MasoonSchema: malformed schema at \(path): \(message)"
        }
    }
}
