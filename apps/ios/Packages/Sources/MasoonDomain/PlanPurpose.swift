/// Why a plan exists. This is stored independently from the curriculum so the
/// same curriculum vocabulary can be reused without guessing intent from a slug.
/// Legacy plans decode as `.memorize` at persistence boundaries.
public enum PlanPurpose: String, CaseIterable, Hashable, Sendable, Codable {
    case read
    case memorize
    case revise
}
