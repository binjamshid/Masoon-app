/// Evidence payload shapes for the `evidence` field of a `task.completed`
/// event (PRD AC-1.2).
///
/// These live in `MasoonDomain`, not in `FeatureToday`, because the wrist
/// (D-199) emits the same events as the phone and its payloads must be
/// byte-identical — a watch completion is re-stamped for `device_id` and
/// `client_seq` on ingestion but its `payload` survives verbatim, so any
/// divergence here would show up as two different evidence shapes for the same
/// user action. `MasoonWatchShared` cannot import `FeatureToday` (SwiftUI, GRDB,
/// the design system); it can import this.
///
/// `FeatureToday.TodayEvidencePayloads` remains as a typealias so existing call
/// sites and their tests are untouched.
public enum EvidencePayloads {

    public static func selfCheck() -> JSONValue {
        .object(["kind": .string("self_check")])
    }

    /// AC-1.2: one `task.completed` with `{kind:"counter", count, increments}`.
    /// `increments` are the real "HH:mm" wall-clock tap times (plan timezone).
    public static func counter(count: Int, increments: [String]) -> JSONValue {
        .object([
            "kind": .string("counter"),
            "count": .number(String(count)),
            "increments": .array(increments.map(JSONValue.string)),
        ])
    }

    public static func timer(seconds: Int) -> JSONValue {
        .object([
            "kind": .string("timer"),
            "elapsed_seconds": .number(String(seconds)),
        ])
    }

    public static func teacherVerification(assessmentId: String) -> JSONValue {
        .object([
            "kind": .string("teacher_verification"),
            "assessment_id": .string(assessmentId),
        ])
    }

    public static func form(formVersionId: String, assessmentId: String) -> JSONValue {
        .object([
            "kind": .string("form"),
            "form_version_id": .string(formVersionId),
            "assessment_id": .string(assessmentId),
        ])
    }

    public static func composite(parts: [JSONValue]) -> JSONValue {
        .object([
            "kind": .string("composite"),
            "parts": .array(parts),
        ])
    }

    /// "HH:mm" from a WallClock local timestamp ("2026-07-12T06:40:00+03:00").
    public static func hhmm(fromLocalTimestamp timestamp: String) -> String {
        guard let tIndex = timestamp.firstIndex(of: "T") else { return timestamp }
        let time = timestamp[timestamp.index(after: tIndex)...]
        return String(time.prefix(5))
    }
}
