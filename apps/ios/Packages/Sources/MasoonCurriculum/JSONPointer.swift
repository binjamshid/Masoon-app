/// Minimal RFC 6901 JSON Pointer, used by `MasoonSchema` (`JSONSchemaValidator.swift`)
/// to report WHERE in a JSON document a schema violation was found.
///
/// This exists so `SchemaViolation.path` can point at the same location in the
/// instance document that ajv's `instancePath` would — the "INSTANCE-PATH
/// CONTAINMENT" half of MasoonSchema's equivalence bar (see the header comment
/// in `JSONSchemaValidator.swift`). It is not a general-purpose JSON Pointer
/// implementation (no `~` decoding into arbitrary document lookups, no
/// relative pointers) — just enough to build and print one.
public struct JSONPointer: Sendable, Hashable, CustomStringConvertible {
    public private(set) var tokens: [String]

    public init(_ tokens: [String] = []) {
        self.tokens = tokens
    }

    /// A pointer with one more reference token appended (an object member name).
    public func appending(_ token: String) -> JSONPointer {
        JSONPointer(tokens + [token])
    }

    /// A pointer with one more reference token appended (an array index).
    public func appending(index: Int) -> JSONPointer {
        appending(String(index))
    }

    /// The RFC 6901 string form: `""` for the root, else `"/a/b/0"` with each
    /// token's `~` and `/` escaped (`~0`, `~1`) per the spec.
    public var description: String {
        tokens.isEmpty ? "" : "/" + tokens.map(Self.escape).joined(separator: "/")
    }

    private static func escape(_ token: String) -> String {
        // No Foundation in this target (ENGINE_PARITY discipline) — hand-rolled,
        // and trivial: two characters, in a fixed order (`~` before `/`, matching
        // RFC 6901 so a literal `~1` in a token isn't double-escaped).
        var out = ""
        out.reserveCapacity(token.count)
        for ch in token {
            switch ch {
            case "~": out += "~0"
            case "/": out += "~1"
            default: out.append(ch)
            }
        }
        return out
    }
}
