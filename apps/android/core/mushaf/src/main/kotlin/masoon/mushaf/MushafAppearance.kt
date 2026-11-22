package masoon.mushaf

/**
 * How the page itself is tinted. This is the PAGE's appearance, not the app's theme — a muṣḥaf
 * is a printed object, and its paper does not follow a Material colour scheme.
 *
 * D-235 supersedes D-220's earlier dim-paper rule: `NIGHT` uses an exact OLED-black page and
 * surround with semantic neutral-pixel remapping. Chromatic Tajweed pixels remain unchanged.
 */
enum class MushafAppearance(
    val raw: String,
) {
    /** The default: warm white paper, near-black ink. */
    PAPER("paper"),

    /** Aged paper — lower contrast, easier under warm light. */
    SEPIA("sepia"),

    /** Exact OLED black with D-235's glyph-local artwork treatment. */
    NIGHT("night"),
    ;

    val isDark: Boolean get() = this == NIGHT

    companion object {
        fun fromRaw(raw: String?): MushafAppearance? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * The two appearances that are legitimately "light".
 *
 * A separate, smaller enum rather than a validated subset of [MushafAppearance]: it makes the
 * invalid state — "follow the system, and when the system is light use NIGHT" — unrepresentable
 * instead of merely rejected at runtime.
 */
enum class MushafLightAppearance(
    val appearance: MushafAppearance,
) {
    PAPER(MushafAppearance.PAPER),
    SEPIA(MushafAppearance.SEPIA),
    ;

    companion object {
        fun fromAppearance(appearance: MushafAppearance): MushafLightAppearance? =
            entries.firstOrNull { it.appearance == appearance }
    }
}

/** What the reader has chosen, which is not the same thing as what is currently shown. */
sealed interface MushafAppearancePreference {
    /** Track the system's light/dark setting, using [lightVariant] when the system is light. */
    data class FollowSystem(
        val lightVariant: MushafLightAppearance = MushafLightAppearance.PAPER,
    ) : MushafAppearancePreference

    /** Always this appearance, whatever the system says. */
    data class Pinned(
        val appearance: MushafAppearance,
    ) : MushafAppearancePreference

    companion object {
        /**
         * Resolves preference × system scheme to the appearance actually rendered.
         *
         * A pure function on purpose: every combination is exhaustively testable without a
         * composition, which is the same discipline [MushafPaging] follows for page order.
         */
        fun resolve(
            preference: MushafAppearancePreference,
            systemIsDark: Boolean,
        ): MushafAppearance =
            when (preference) {
                is Pinned -> preference.appearance
                is FollowSystem ->
                    if (systemIsDark) MushafAppearance.NIGHT else preference.lightVariant.appearance
            }
    }
}
