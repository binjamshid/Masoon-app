import MasoonDomain

/// Parses the golden-fixture `input.json` (ENGINE_PARITY §4.1/§4.3) into a
/// `PlanGenerationContext` + window. File I/O stays in the caller (the engine
/// itself never touches the filesystem); this type only consumes bytes.

public struct FixtureInput: Sendable {
    public let fixtureId: String
    public let context: PlanGenerationContext
    public let window: GenerationWindow
    /// Relative paths exactly as written in the fixture (resolved by the caller).
    public let curriculumDefinitionPath: String
    /// The fixture's single content-index reference (ENGINE_PARITY §4.3):
    /// `quran_ref` normalizes to kind `"quran"`; `corpus_ref` carries its own
    /// `{kind, path}`.
    public let contentRefKind: String
    public let contentRefPath: String

    public enum FixtureError: Error, CustomStringConvertible {
        case malformed(String)
        public var description: String {
            if case .malformed(let m) = self { return "fixture input error: \(m)" }
            return "fixture input error"
        }
    }

    /// ENGINE_PARITY §4.3 rule 3 — the corpus-KIND discriminator, drawn from
    /// the same closed vocabulary as `corpus-ref-v1.schema.json`'s
    /// `corpus_kind` and `curriculum-v1.schema.json`'s `meta.corpora`
    /// (D-198). Kept in lockstep with those by hand; widening this set
    /// without widening them is exactly the drift it exists to make visible.
    public static let knownContentKinds: Set<String> = ["quran", "poem"]

    /// Resolves `quran_ref` / `corpus_ref` to one `(kind, path)` pair.
    /// §4.3 rule 1: exactly one of the two keys may be present — a fixture
    /// declaring both or neither is malformed, never silently preferred.
    /// §4.3 rule 2: `quran_ref: P` and `corpus_ref: {kind:"quran", path:P}`
    /// are two spellings of one input, so `quran_ref` normalizes here to the
    /// same `(kind, path)` shape rather than following a parallel code path
    /// that could drift from it.
    private static func resolveContentRef(_ root: [String: JSONValue]) throws -> (kind: String, path: String) {
        let quranRef = root["quran_ref"]
        let corpusRef = root["corpus_ref"]
        switch (quranRef, corpusRef) {
        case (.some, .some):
            throw FixtureError.malformed("quran_ref and corpus_ref are mutually exclusive; both were present")
        case (.none, .none):
            throw FixtureError.malformed("exactly one of quran_ref / corpus_ref is required; neither was present")
        case (.some(let q), .none):
            guard let path = q.stringValue else { throw FixtureError.malformed("quran_ref must be a string path") }
            return ("quran", path)
        case (.none, .some(let c)):
            guard let obj = c.objectValue,
                  let kind = obj["kind"]?.stringValue,
                  let path = obj["path"]?.stringValue
            else { throw FixtureError.malformed("corpus_ref must be an object with kind and path") }
            return (kind, path)
        }
    }

    /// §4.3 rules 3-5 — builds the `ContentIndex` conformer for `kind`,
    /// rejecting a kind this runner does not implement by name (never
    /// falling back to `QuranIndex` — the spec calls that a firing offense),
    /// and cross-checking a non-Qurʾān document's own declared `corpus_kind`
    /// against what the fixture asked for rather than trusting either side.
    private static func loadContentIndex(kind: String, bytes: [UInt8]) throws -> any ContentIndex {
        switch kind {
        case "quran":
            return try QuranIndex(json: JSONParser.parse(bytes: bytes))
        case "poem":
            let doc = try JSONParser.parse(bytes: bytes)
            guard let declared = doc.objectValue?["corpus_kind"]?.stringValue else {
                throw FixtureError.malformed("corpus_ref document is missing corpus_kind")
            }
            guard declared == kind else {
                throw FixtureError.malformed(
                    "corpus_ref.kind \"\(kind)\" disagrees with the document's own corpus_kind \"\(declared)\"")
            }
            return try PoemIndex(json: doc)
        default:
            throw FixtureError.malformed(
                "corpus_ref.kind \"\(kind)\" is not a kind this engine implements (known kinds: "
                    + knownContentKinds.sorted().joined(separator: ", ") + ")")
        }
    }

    /// Two-phase load: `referencedPaths(inputBytes:)` first, so the caller can
    /// read the referenced files, then `init` with all three byte payloads.
    public static func referencedPaths(inputBytes: [UInt8]) throws -> (curriculum: String, contentKind: String, contentPath: String) {
        let json = try JSONParser.parse(bytes: inputBytes)
        guard let root = json.objectValue else { throw FixtureError.malformed("root is not an object") }
        guard let curriculumPath = root["curriculum_definition"]?.stringValue else {
            throw FixtureError.malformed("curriculum_definition missing")
        }
        let ref = try resolveContentRef(root)
        return (curriculumPath, ref.kind, ref.path)
    }

    public init(inputBytes: [UInt8], curriculumBytes: [UInt8], contentBytes: [UInt8]) throws {
        let json = try JSONParser.parse(bytes: inputBytes)
        guard let root = json.objectValue else { throw FixtureError.malformed("root is not an object") }

        self.fixtureId = root["fixture_id"]?.stringValue ?? ""
        guard let planId = root["plan_id"]?.stringValue else { throw FixtureError.malformed("plan_id missing") }
        guard let todayStr = root["today"]?.stringValue, let today = LocalDate(iso: todayStr) else {
            throw FixtureError.malformed("today missing or malformed")
        }
        guard let windowObj = root["window"]?.objectValue,
              let fromStr = windowObj["from"]?.stringValue, let from = LocalDate(iso: fromStr),
              let toStr = windowObj["to"]?.stringValue, let to = LocalDate(iso: toStr)
        else { throw FixtureError.malformed("window missing or malformed") }
        self.window = GenerationWindow(from: from, to: to)

        self.curriculumDefinitionPath = root["curriculum_definition"]?.stringValue ?? ""
        let ref = try FixtureInput.resolveContentRef(root)
        self.contentRefKind = ref.kind
        self.contentRefPath = ref.path

        let curriculum = try CurriculumLoader.load(json: JSONParser.parse(bytes: curriculumBytes))
        let quranIndex = try FixtureInput.loadContentIndex(kind: ref.kind, bytes: contentBytes)

        // PC-7 (D-054 plumbing): OPTIONAL `extra_curricula` — an array of
        // `{slug, version, definition}` inline compiled-curriculum
        // definitions beyond the base one, feeding PC-3's
        // `PlanGenerationContext.curriculumByKey` (keyed `"slug@version"`,
        // matching `FoldedEvents.CurriculumChange`/`CurriculumSet.resolve`).
        // Every existing fixture omits this key, so `curriculumByKey` stays
        // `[:]` and behavior is byte-identical to before this field existed.
        // This is plumbing only — a LATER stage (Stage 7) authors fixtures
        // that actually populate it to exercise a real upgrade timeline.
        var curriculumByKey: [String: CompiledCurriculum] = [:]
        for item in root["extra_curricula"]?.arrayValue ?? [] {
            guard let slug = item["slug"]?.stringValue,
                  let version = item["version"]?.stringValue,
                  let definitionJSON = item["definition"]
            else { throw FixtureError.malformed("extra_curricula item missing slug/version/definition") }
            curriculumByKey["\(slug)@\(version)"] = try CurriculumLoader.load(json: definitionJSON)
        }

        guard let policyJSON = root["policy"] else { throw FixtureError.malformed("policy missing") }
        let policy = try PlanPolicy(json: policyJSON)

        guard let startingJSON = root["starting_state"],
              let startingState = LearnerStartingState(json: startingJSON)
        else { throw FixtureError.malformed("starting_state missing or malformed") }

        guard let calendarObj = root["calendar"]?.objectValue,
              let anchorStr = calendarObj["anchor_date"]?.stringValue,
              let anchorDate = LocalDate(iso: anchorStr)
        else { throw FixtureError.malformed("calendar missing or malformed") }
        var exceptions: [OrgException] = []
        for item in calendarObj["org_exceptions"]?.arrayValue ?? [] {
            guard let dateStr = item["date"]?.stringValue, let date = LocalDate(iso: dateStr),
                  let className = item["class"]?.stringValue
            else { throw FixtureError.malformed("bad org exception") }
            exceptions.append(OrgException(date: date, className: className))
        }
        let calendar = PlanCalendar(
            timezone: calendarObj["timezone"]?.stringValue ?? "UTC",
            anchorDate: anchorDate,
            orgExceptions: exceptions)

        var events: [PlanEvent] = []
        for item in root["event_log"]?.arrayValue ?? [] {
            guard let event = PlanEvent(json: item) else { throw FixtureError.malformed("bad event in event_log") }
            events.append(event)
        }

        // L12 (App Store compliance remediation): OPTIONAL `has_assigned_teacher`
        // — every existing fixture omits this key, so it defaults to `true`
        // (a teacher assumed present), byte-identical to before this key
        // existed. Only a fixture that explicitly models a teacherless solo
        // learner sets `false`.
        let hasAssignedTeacher = root["has_assigned_teacher"]?.boolValue ?? true

        self.context = try PlanGenerationContext(
            planId: planId,
            curriculum: curriculum,
            curriculumByKey: curriculumByKey,
            quranIndex: quranIndex,
            policy: policy,
            startingState: startingState,
            calendar: calendar,
            events: events,
            today: today,
            hasAssignedTeacher: hasAssignedTeacher)
    }

    public func run() throws -> String {
        let result = try Engine.generate(context: context, window: window)
        return StreamSerializer.serialize(result)
    }
}
