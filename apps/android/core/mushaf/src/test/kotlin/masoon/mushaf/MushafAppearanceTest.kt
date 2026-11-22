package masoon.mushaf

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class MushafAppearanceTest {
    @Test
    fun `a pinned appearance ignores the system scheme entirely`() {
        val pinned = MushafAppearancePreference.Pinned(MushafAppearance.SEPIA)
        assertEquals(
            MushafAppearance.SEPIA,
            MushafAppearancePreference.resolve(pinned, systemIsDark = false),
        )
        assertEquals(
            MushafAppearance.SEPIA,
            MushafAppearancePreference.resolve(pinned, systemIsDark = true),
        )
    }

    @Test
    fun `pinning NIGHT keeps it under a light system - that is the point of pinning`() {
        assertEquals(
            MushafAppearance.NIGHT,
            MushafAppearancePreference.resolve(
                MushafAppearancePreference.Pinned(MushafAppearance.NIGHT),
                systemIsDark = false,
            ),
        )
    }

    @Test
    fun `follow-system uses the chosen light variant by day and NIGHT after dark`() {
        val followSepia =
            MushafAppearancePreference.FollowSystem(lightVariant = MushafLightAppearance.SEPIA)
        assertEquals(
            MushafAppearance.SEPIA,
            MushafAppearancePreference.resolve(followSepia, systemIsDark = false),
        )
        assertEquals(
            MushafAppearance.NIGHT,
            MushafAppearancePreference.resolve(followSepia, systemIsDark = true),
        )
    }

    @Test
    fun `NIGHT is not a light variant, so follow-system cannot resolve to it by day`() {
        // The invalid state — "follow the system, and when the system is LIGHT use night" — is
        // unrepresentable rather than merely rejected: MushafLightAppearance has no NIGHT case.
        assertNull(MushafLightAppearance.fromAppearance(MushafAppearance.NIGHT))
        MushafLightAppearance.entries.forEach { variant ->
            assertEquals(
                variant.appearance,
                MushafAppearancePreference.resolve(
                    MushafAppearancePreference.FollowSystem(variant),
                    systemIsDark = false,
                ),
                "a light variant must resolve to itself under a light system",
            )
        }
    }

    @Test
    fun `NIGHT is the only appearance that reports itself as dark`() {
        assertEquals(
            listOf(MushafAppearance.NIGHT),
            MushafAppearance.entries.filter { it.isDark },
        )
    }

    @Test
    fun `raw codes round-trip, and an unknown code is null rather than a silent default`() {
        MushafAppearance.entries.forEach { appearance ->
            assertEquals(appearance, MushafAppearance.fromRaw(appearance.raw))
        }
        // A silent fallback here would let a corrupt preference quietly change the page's look
        // with no way to tell it happened; the store decides the fallback, not the parser.
        assertNull(MushafAppearance.fromRaw("dark"))
        assertNull(MushafAppearance.fromRaw(null))
    }
}
