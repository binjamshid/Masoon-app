package masoon.publicui.designsystem

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** One resolved (light- or dark-appearance) set of Masoon color tokens. */
data class MasoonColorPalette(
    val primary: Color,
    val primaryEmphasis: Color,
    val onPrimary: Color,
    val primarySoft: Color,
    val background: Color,
    val surface: Color,
    val surfaceSecondary: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val outline: Color,
    val success: Color,
    val warning: Color,
    val attention: Color,
    val progressTrack: Color,
)

object MasoonColors {
    val Light =
        MasoonColorPalette(
            primary = Color(0xFF0E5A52),
            primaryEmphasis = Color(0xFF0A423C),
            onPrimary = Color(0xFFFFFFFF),
            primarySoft = Color(0xFFE1EEEC),
            background = Color(0xFFFAF7F2),
            surface = Color(0xFFFFFFFF),
            surfaceSecondary = Color(0xFFF1EDE5),
            textPrimary = Color(0xFF201D18),
            textSecondary = Color(0xFF6C6559),
            outline = Color(0xFFE4DED3),
            success = Color(0xFF1E7A4C),
            warning = Color(0xFF9A6A00),
            attention = Color(0xFF9C3B22),
            progressTrack = Color(0xFFE7E1D6),
        )

    val Dark =
        MasoonColorPalette(
            primary = Color(0xFF4FB3A5),
            primaryEmphasis = Color(0xFF3B9487),
            onPrimary = Color(0xFF06211E),
            primarySoft = Color(0xFF16332F),
            background = Color(0xFF141210),
            surface = Color(0xFF1E1B18),
            surfaceSecondary = Color(0xFF282420),
            textPrimary = Color(0xFFF2EEE8),
            textSecondary = Color(0xFFABA396),
            outline = Color(0xFF3B362E),
            success = Color(0xFF5BC48D),
            warning = Color(0xFFE8B458),
            attention = Color(0xFFE8926F),
            progressTrack = Color(0xFF322E27),
        )

    /** The full palette for the current appearance. */
    val current: MasoonColorPalette
        @Composable get() = if (isSystemInDarkTheme()) Dark else Light

    val primary: Color @Composable get() = current.primary
    val primaryEmphasis: Color @Composable get() = current.primaryEmphasis
    val onPrimary: Color @Composable get() = current.onPrimary
    val primarySoft: Color @Composable get() = current.primarySoft
    val background: Color @Composable get() = current.background
    val surface: Color @Composable get() = current.surface
    val surfaceSecondary: Color @Composable get() = current.surfaceSecondary
    val textPrimary: Color @Composable get() = current.textPrimary
    val textSecondary: Color @Composable get() = current.textSecondary
    val outline: Color @Composable get() = current.outline
    val success: Color @Composable get() = current.success
    val warning: Color @Composable get() = current.warning
    val attention: Color @Composable get() = current.attention
    val progressTrack: Color @Composable get() = current.progressTrack
}

/** 4-dp spacing scale. Use these instead of magic numbers. */
object MasoonSpacing {
    val xs = 4.dp
    val sm = 8.dp
    val md = 12.dp
    val lg = 16.dp
    val xl = 24.dp
    val xxl = 32.dp
}

object MasoonRadius {
    val sm = 8.dp
    val md = 12.dp
    val lg = 16.dp

    /** Fully-rounded capsule chips. */
    val pill = 999.dp
}

object MasoonMetrics {
    /** Minimum interactive target for touch controls. */
    val minTarget = 48.dp
}

/**
 * Text styles participating in the user's font-size setting — every size below is `.sp`
 * (Compose's scalable text unit; `Text`/`BasicText` scale `.sp` values by
 * `Configuration.fontScale` automatically), never a fixed/unscaled unit. This is the Android
 * counterpart of iOS's `Font.TextStyle`-backed Dynamic Type scaling.
 */
enum class MasoonTypeStyle {
    LargeTitle,
    Title,
    Title2,
    Title3,
    Headline,
    Body,
    Callout,
    Subheadline,
    Footnote,
    Caption,
}

object MasoonType {
    fun style(style: MasoonTypeStyle): TextStyle =
        when (style) {
            MasoonTypeStyle.LargeTitle -> TextStyle(fontSize = 34.sp, lineHeight = 41.sp, fontWeight = FontWeight.Bold)
            MasoonTypeStyle.Title -> TextStyle(fontSize = 28.sp, lineHeight = 34.sp, fontWeight = FontWeight.Bold)
            MasoonTypeStyle.Title2 -> TextStyle(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.SemiBold)
            MasoonTypeStyle.Title3 -> TextStyle(fontSize = 20.sp, lineHeight = 25.sp, fontWeight = FontWeight.SemiBold)
            MasoonTypeStyle.Headline ->
                TextStyle(
                    fontSize = 17.sp,
                    lineHeight = 22.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            MasoonTypeStyle.Body -> TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.Normal)
            MasoonTypeStyle.Callout -> TextStyle(fontSize = 16.sp, lineHeight = 21.sp, fontWeight = FontWeight.Normal)
            MasoonTypeStyle.Subheadline ->
                TextStyle(
                    fontSize = 15.sp,
                    lineHeight = 20.sp,
                    fontWeight = FontWeight.Normal,
                )
            MasoonTypeStyle.Footnote -> TextStyle(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Normal)
            MasoonTypeStyle.Caption -> TextStyle(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Normal)
        }
}

/** `style.toTextStyle()` — the `masoon-type-*` scale, with the default primary text color. */
@Composable
fun MasoonTypeStyle.toTextStyle(color: Color = MasoonColors.textPrimary): TextStyle =
    MasoonType.style(this).copy(color = color)
