import MasoonDomain

/// CB-11 (Batch 3 Stage 6, Track B — the on-device curriculum builder's
/// selectors editor): a public, single-selector JSON round trip. CB-9's
/// `CurriculumDraft+Document.swift` already implements this exact
/// conversion (`CurriculumDraftCoding.selectorSpecToJSON`/
/// `.parseSelectorSpec`) but keeps it `private` to that file, correctly so
/// for a whole-DOCUMENT round trip. The builder's selectors editor needs the
/// identical algorithm at the granularity of ONE selector at a time (its
/// "raw-JSON fallback field" for the selector kinds that don't get bespoke
/// UI — see the builder's own scoping note) — this file is a thin, purely
/// additive public wrapper around that SAME private implementation, never a
/// second, independently-written parser.
extension SelectorSpec {
    /// Parses a single selector's JSON body (e.g. `{"next_new": {...}}`) —
    /// the exact shape `selectors.<name>` or an inline `emit.select` takes
    /// in a `curriculum-v1` document.
    public static func fromJSON(_ json: JSONValue) throws -> SelectorSpec {
        try CurriculumDraftCoding.parseSelectorSpec(json, context: "selector")
    }

    /// The inverse of `fromJSON(_:)`.
    public func toJSONValue() -> JSONValue {
        CurriculumDraftCoding.selectorSpecToJSON(self)
    }
}
