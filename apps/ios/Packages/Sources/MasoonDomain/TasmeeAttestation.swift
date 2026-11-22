/// The learner's record of a hearing by a named listener. Its evidence
/// kind distinguishes it from verification submitted by a teacher.
public struct TasmeeAttestation: Equatable, Sendable {

    /// Evidence `kind` for a self-attested, named-listener hearing. Never
    /// `"teacher_verification"` (see type doc comment).
    public static let evidenceKind = "named_listener_attestation"

    /// The listener's (مُسمِّع) name, as the learner typed it. Free text: the
    /// app has no roster of registered teachers to validate against.
    public let musammiName: String
    /// "HH:mm" plan-timezone wall clock (same shape as `EvidencePayloads`'
    /// counter increments) — when the hearing happened, not when the form was
    /// submitted.
    public let time: String
    /// Whatever score the musammiʿ gave, as the learner reports it. The app
    /// imposes a UI range (0...100) for a sane numeric keypad, not a
    /// pedagogical scale — see `FeatureToday.TasmeeAttestationForm`.
    public let score: Int
    /// Mistake count reported by the listener.
    public let mistakeCount: Int

    public init(musammiName: String, time: String, score: Int, mistakeCount: Int) {
        self.musammiName = musammiName
        self.time = time
        self.score = score
        self.mistakeCount = mistakeCount
    }

    /// Whether the attestation names the listener.
    public var isFilled: Bool {
        !trimmed(musammiName).isEmpty
    }

    /// Completion evidence payload. The fold reads the nested `verified` flag.
    public func evidenceJSON() -> JSONValue {
        .object([
            "kind": .string(Self.evidenceKind),
            "musammi_name": .string(musammiName),
            "time": .string(time),
            "score": .number(String(score)),
            "mistake_count": .number(String(mistakeCount)),
            "verified": .bool(true),
        ])
    }

    /// Reads a previously-recorded attestation back out of an `evidence`
    /// JSON blob (e.g. for a future supervisor console, or for re-displaying
    /// a completed task). Returns `nil` for anything that isn't this kind —
    /// in particular a real `teacher_verification` event, by construction.
    public static func parse(_ evidence: JSONValue) -> TasmeeAttestation? {
        guard evidence["kind"]?.stringValue == evidenceKind,
              let name = evidence["musammi_name"]?.stringValue,
              let time = evidence["time"]?.stringValue,
              let score = evidence["score"]?.intValue,
              let mistakeCount = evidence["mistake_count"]?.intValue
        else { return nil }
        return TasmeeAttestation(musammiName: name, time: time, score: score, mistakeCount: mistakeCount)
    }
}

/// Foundation-free whitespace trim (ENGINE_PARITY §1 — no `Foundation` import
/// in this module).
private func trimmed(_ s: String) -> String {
    var chars = Substring(s)
    while let first = chars.first, first.isWhitespace { chars.removeFirst() }
    while let last = chars.last, last.isWhitespace { chars.removeLast() }
    return String(chars)
}
