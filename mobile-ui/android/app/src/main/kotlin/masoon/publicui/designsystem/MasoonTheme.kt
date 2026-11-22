package masoon.publicui.designsystem

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

private val LightColors =
    lightColorScheme(
        primary = MasoonColors.Light.primary,
        onPrimary = MasoonColors.Light.onPrimary,
        primaryContainer = MasoonColors.Light.primarySoft,
        onPrimaryContainer = MasoonColors.Light.primaryEmphasis,
        background = MasoonColors.Light.background,
        onBackground = MasoonColors.Light.textPrimary,
        surface = MasoonColors.Light.surface,
        onSurface = MasoonColors.Light.textPrimary,
        surfaceVariant = MasoonColors.Light.surfaceSecondary,
        onSurfaceVariant = MasoonColors.Light.textSecondary,
        outline = MasoonColors.Light.outline,
        error = MasoonColors.Light.attention,
    )

private val DarkColors =
    darkColorScheme(
        primary = MasoonColors.Dark.primary,
        onPrimary = MasoonColors.Dark.onPrimary,
        primaryContainer = MasoonColors.Dark.primarySoft,
        onPrimaryContainer = MasoonColors.Dark.primaryEmphasis,
        background = MasoonColors.Dark.background,
        onBackground = MasoonColors.Dark.textPrimary,
        surface = MasoonColors.Dark.surface,
        onSurface = MasoonColors.Dark.textPrimary,
        surfaceVariant = MasoonColors.Dark.surfaceSecondary,
        onSurfaceVariant = MasoonColors.Dark.textSecondary,
        outline = MasoonColors.Dark.outline,
        error = MasoonColors.Dark.attention,
    )

@Composable
fun MasoonTheme(
    darkTheme: Boolean = androidx.compose.foundation.isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val colorScheme = if (darkTheme) DarkColors else LightColors
    MaterialTheme(colorScheme = colorScheme, content = content)
}
