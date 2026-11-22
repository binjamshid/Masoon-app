/// A single JSON Schema validation failure produced by `MasoonSchema`
/// (`JSONSchemaValidator.swift`).
///
/// EQUIVALENCE BAR (see the header comment in `JSONSchemaValidator.swift`):
/// callers must not depend on `message` matching ajv's wording verbatim — only
/// on `path` pointing at the same location in the instance document ajv would
/// flag, and on `[SchemaViolation]` being empty exactly when ajv would report
/// valid. `keyword` is MasoonSchema's own name for the failing JSON Schema
/// keyword (e.g. `"required"`, `"pattern"`, `"oneOf"`), not necessarily
/// ajv's internal `schemaPath`.
public struct SchemaViolation: Sendable, Equatable, CustomStringConvertible {
    /// Where in the INSTANCE document the violation occurred (mirrors ajv's
    /// `instancePath`). Points at the object/array/value that failed — for a
    /// `required` failure this is the containing object, not the missing key.
    public let path: JSONPointer

    /// The JSON Schema keyword that produced this violation.
    public let keyword: String

    /// Human-readable, non-normative explanation. Not wire-compatible with
    /// ajv's `message` — see the equivalence bar above.
    public let message: String

    public init(path: JSONPointer, keyword: String, message: String) {
        self.path = path
        self.keyword = keyword
        self.message = message
    }

    public var description: String {
        let where_ = path.description.isEmpty ? "(root)" : path.description
        return "\(where_): \(message) [\(keyword)]"
    }
}
