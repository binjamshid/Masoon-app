/// Evidence requirements per PRD §7.11 and the compact stream forms of
/// ENGINE_PARITY §3: `self | timer:{s} | counter:{n} | teacher | form:{id} | composite(a+b)`.

public indirect enum EvidenceSpec: Hashable, Sendable {
    case selfCheck
    case timer(minSeconds: Int)
    case counter(target: Int)
    case teacherVerification(formVersionId: String?)
    case form(formVersionId: String)
    case composite([EvidenceSpec])

    public var compact: String {
        switch self {
        case .selfCheck: return "self"
        case .timer(let s): return "timer:\(s)"
        case .counter(let n): return "counter:\(n)"
        case .teacherVerification: return "teacher"
        case .form(let id): return "form:\(id)"
        case .composite(let parts): return "composite(\(parts.map(\.compact).joined(separator: "+")))"
        }
    }

    /// Parses the JSON shape used both by the curriculum DSL and by
    /// `policy.evidence_policy`. `resolveInt` maps `$var` references (D-028
    /// evidence targets may be variable refs) or plain ints to values.
    public static func parse(_ json: JSONValue, resolveInt: (JSONValue) -> Int?) -> EvidenceSpec? {
        if let s = json.stringValue {
            return s == "self_check" ? .selfCheck : nil
        }
        guard let obj = json.objectValue, obj.count == 1, let (key, body) = obj.first else { return nil }
        switch key {
        case "timer":
            guard let secs = body["min_seconds"].flatMap(resolveInt) else { return nil }
            return .timer(minSeconds: secs)
        case "counter":
            guard let target = body["target"].flatMap(resolveInt) else { return nil }
            return .counter(target: target)
        case "teacher_verification":
            return .teacherVerification(formVersionId: body["form_version_id"]?.stringValue)
        case "form":
            guard let id = body["form_version_id"]?.stringValue else { return nil }
            return .form(formVersionId: id)
        case "composite":
            guard let items = body.arrayValue, !items.isEmpty else { return nil }
            var parts: [EvidenceSpec] = []
            for item in items {
                guard let p = parse(item, resolveInt: resolveInt) else { return nil }
                parts.append(p)
            }
            return .composite(parts)
        default:
            return nil
        }
    }
}
