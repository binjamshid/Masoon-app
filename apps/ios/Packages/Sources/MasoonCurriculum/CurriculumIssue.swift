import MasoonDomain

/// CB-5 (MasoonAuthoring): the shared finding type every one of the 4
/// validation gates (schema / references / lints / simulation) reports
/// through. A future on-device curriculum builder UI groups/sorts/localizes
/// purely off this type — it never needs to know which gate-internal type
/// (`SchemaViolation`, `CurriculumError`, a lint, or CB-6's simulator)
/// produced a given finding.

/// Whether a finding blocks the draft from being usable (`error`) or is a
/// non-blocking signal the author should look at but may accept (`warning`).
/// `Comparable` so callers can sort worst-first (`error > warning`).
public enum IssueSeverity: String, Sendable, Equatable, Comparable, CustomStringConvertible {
    case warning
    case error

    public var description: String { rawValue }

    private var rank: Int {
        switch self {
        case .warning: return 0
        case .error: return 1
        }
    }

    public static func < (lhs: IssueSeverity, rhs: IssueSeverity) -> Bool { lhs.rank < rhs.rank }
}

/// Which of the 4 gates produced a finding.
public enum ValidationGate: String, Sendable, Equatable, CustomStringConvertible {
    case schema
    case references
    case lints
    case simulation

    public var description: String { rawValue }
}

/// A single validation finding from any gate.
public struct CurriculumIssue: Sendable, Equatable, CustomStringConvertible {
    public let severity: IssueSeverity

    /// Stable identifier a caller can key UI copy, docs, or `--only L-12`
    /// style filtering off: `"SCHEMA"` (gate 1, any schema keyword
    /// violation), `"REF-MALFORMED"` / `"REF-INVALID"` / `"REF-UNKNOWN"`
    /// (gate 2, wrapping `CurriculumError`), `"L-07"`..`"L-15"` (gate 3, see
    /// `CurriculumLints`), or whatever id CB-6's simulator defines (gate 4).
    /// Never blank.
    public let id: String

    public let gate: ValidationGate

    /// Best-effort RFC 6901 pointer into the DRAFT document this finding is
    /// about. `JSONPointer()` (root) when no more specific location applies
    /// (e.g. a gate-2 `CurriculumError`, which carries only a message, no
    /// structured location — the loader throws on the FIRST problem it
    /// finds rather than collecting every reference error, a known
    /// limitation of reusing it as-is rather than reimplementing it).
    public let path: JSONPointer

    public let messageEn: String

    /// Arabic diagnostic when the issue provides a localized message.
    public let messageAr: String?

    public init(
        severity: IssueSeverity, id: String, gate: ValidationGate, path: JSONPointer,
        messageEn: String, messageAr: String? = nil
    ) {
        self.severity = severity
        self.id = id
        self.gate = gate
        self.path = path
        self.messageEn = messageEn
        self.messageAr = messageAr
    }

    /// Localized message: Arabic when authored and requested, else English.
    /// Mirrors `CompiledCurriculum.sessionTitle`'s ar-preferred/en-fallback
    /// convention used elsewhere in this package.
    public func message(arabic: Bool) -> String {
        if arabic, let ar = messageAr { return ar }
        return messageEn
    }

    public var description: String {
        let where_ = path.description.isEmpty ? "(root)" : path.description
        return "[\(severity)] \(id) (\(gate)) \(where_): \(messageEn)"
    }
}

// MARK: - Gate 1 / gate 2 wrapping

extension CurriculumIssue {
    /// Gate 1: wraps a `JSONSchemaValidator` (CB-3, `MasoonSchema`) finding.
    static func fromSchemaViolation(_ v: SchemaViolation) -> CurriculumIssue {
        CurriculumIssue(
            severity: .error, id: "SCHEMA", gate: .schema, path: v.path,
            messageEn: "\(v.message) [\(v.keyword)]")
    }

    /// Gate 2: wraps whatever `CurriculumLoader.load` threw — the existing
    /// `validateReferences` (and the loader's own shape guards) reused
    /// as-is, not reimplemented.
    static func fromCurriculumError(_ error: CurriculumError) -> CurriculumIssue {
        switch error {
        case .malformed(let m):
            return CurriculumIssue(
                severity: .error, id: "REF-MALFORMED", gate: .references, path: JSONPointer(), messageEn: m)
        case .invalidReference(let m):
            return CurriculumIssue(
                severity: .error, id: "REF-INVALID", gate: .references, path: JSONPointer(), messageEn: m)
        }
    }
}
