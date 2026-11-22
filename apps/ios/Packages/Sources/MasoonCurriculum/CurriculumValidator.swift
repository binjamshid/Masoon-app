import MasoonDomain

/// Validates curriculum drafts in order: schema, references, lints and
/// simulation. Schema or reference errors stop the pipeline. All applicable
/// lints run before simulation. A lint error blocks simulation and a warning
/// allows it to proceed.
public enum CurriculumValidator {
    /// Runs the full 4-gate pipeline against `draft`.
    ///
    /// - Parameters:
    ///   - draft: the raw curriculum-v1 JSON document under authoring.
    ///   - schema: a pre-compiled `JSONSchemaValidator` for
    ///     `curriculum-v1.schema.json` (compiling it is moderately
    ///     expensive and has no single correct default location from
    ///     within this package, so callers construct and cache it).
    ///   - simulationGate: the simulation implementation. Defaults to a no-op.
    public static func validate(
        draft: JSONValue,
        schema: JSONSchemaValidator,
        simulationGate: CurriculumSimulationGate = NoOpSimulationGate()
    ) -> CurriculumValidationResult {
        var issues: [CurriculumIssue] = []

        // --- Gate 1: schema.
        let schemaViolations = schema.validate(draft)
        issues += schemaViolations.map(CurriculumIssue.fromSchemaViolation)
        guard !issues.contains(where: { $0.severity == .error }) else {
            return CurriculumValidationResult(issues: issues, compiledCurriculum: nil)
        }

        // --- Gate 2: references (via the real loader — see header).
        let compiled: CompiledCurriculum
        do {
            compiled = try CurriculumLoader.load(json: draft)
        } catch let error as CurriculumError {
            issues.append(CurriculumIssue.fromCurriculumError(error))
            return CurriculumValidationResult(issues: issues, compiledCurriculum: nil)
        } catch {
            // CurriculumLoader.load only ever throws CurriculumError today;
            // this branch exists so a future change to that contract fails
            // as a reported issue, not an uncaught pipeline crash.
            issues.append(CurriculumIssue(
                severity: .error, id: "REF-UNKNOWN", gate: .references, path: JSONPointer(),
                messageEn: "unexpected error compiling curriculum: \(error)"))
            return CurriculumValidationResult(issues: issues, compiledCurriculum: nil)
        }

        // --- Gate 3: lints.
        let lintIssues = CurriculumLints.run(draft: draft, compiled: compiled)
        issues += lintIssues
        guard !lintIssues.contains(where: { $0.severity == .error }) else {
            return CurriculumValidationResult(issues: issues, compiledCurriculum: compiled)
        }

        // --- Gate 4: simulation (seam; see `CurriculumSimulationGate` below).
        do {
            issues += try simulationGate.simulate(compiled)
        } catch {
            issues.append(CurriculumIssue(
                severity: .error, id: "SIM-ERROR", gate: .simulation, path: JSONPointer(),
                messageEn: "simulation gate threw: \(error)"))
        }

        return CurriculumValidationResult(issues: issues, compiledCurriculum: compiled)
    }
}

/// Simulates a validated curriculum. The validator reports a thrown error
/// as a simulation issue.
public protocol CurriculumSimulationGate: Sendable {
    func simulate(_ curriculum: CompiledCurriculum) throws -> [CurriculumIssue]
}

/// Default gate-4 implementation until CB-6 lands: reports nothing, so
/// `CurriculumValidator.validate`'s gate 4 is a no-op by default rather than
/// a compile error or a placeholder UI surface (this is an internal pipeline
/// seam with no user-facing presence yet — P12's "no stubs" rule governs
/// user-visible surfaces, not an unshipped internal call site CB-6 fills in
/// next round).
public struct NoOpSimulationGate: CurriculumSimulationGate {
    public init() {}
    public func simulate(_ curriculum: CompiledCurriculum) throws -> [CurriculumIssue] { [] }
}

/// The pipeline's overall result: every finding across whichever gates ran,
/// plus gate 2's compiled output when available.
public struct CurriculumValidationResult: Sendable {
    public let issues: [CurriculumIssue]

    /// Gate 2's output, present iff gates 1-2 both succeeded — so a caller
    /// wanting SOMETHING to preview still can even when gate 3 found a hard
    /// error (e.g. to render the draft's tasks while also showing the lint
    /// error that blocks publishing it).
    public let compiledCurriculum: CompiledCurriculum?

    public init(issues: [CurriculumIssue], compiledCurriculum: CompiledCurriculum?) {
        self.issues = issues
        self.compiledCurriculum = compiledCurriculum
    }

    public var passed: Bool { !issues.contains { $0.severity == .error } }
    public var errors: [CurriculumIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [CurriculumIssue] { issues.filter { $0.severity == .warning } }
}
