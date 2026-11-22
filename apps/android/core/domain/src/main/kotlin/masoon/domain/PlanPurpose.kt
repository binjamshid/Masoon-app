package masoon.domain

/** Why a plan exists, independent of the curriculum implementation it uses. */
enum class PlanPurpose(val code: String) {
    READ("read"),
    MEMORIZE("memorize"),
    REVISE("revise"),
    ;

    companion object {
        fun fromCodeOrNull(code: String): PlanPurpose? = entries.firstOrNull { it.code == code }
    }
}
