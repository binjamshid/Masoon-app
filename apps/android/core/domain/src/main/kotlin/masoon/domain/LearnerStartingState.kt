package masoon.domain

/**
 * Declared-strength factors, scaled integers (ENGINE_SEMANTICS §1):
 * weak 1500, moderate 1200, strong 1000. No floating point.
 */
enum class Strength(val code: String, val factorScaled: Long) {
    WEAK("weak", 1500L),
    MODERATE("moderate", 1200L),
    STRONG("strong", 1000L);

    companion object {
        fun fromCode(code: String): Strength =
            entries.firstOrNull { it.code == code }
                ?: throw IllegalArgumentException("unknown strength: $code")
    }
}

data class DeclaredRange(
    val range: CanonicalRange,
    val strength: Strength,
    val declaredBy: String, // self | teacher
)

data class LearnerStartingState(
    val memorizedRanges: List<DeclaredRange>,
    val placementCursor: CanonicalPosition,
)
