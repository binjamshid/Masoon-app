package masoon.publicui.designsystem

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import java.util.Locale

enum class MasoonDsLocale(val languageTag: String, val layoutDirection: LayoutDirection) {
    ARABIC("ar-u-ca-gregory-nu-arab", LayoutDirection.Rtl),
    ENGLISH("en-u-ca-gregory-nu-latn", LayoutDirection.Ltr),
}

internal val LocalMasoonLocale = staticCompositionLocalOf { MasoonDsLocale.ARABIC }

@Composable
fun ProvideMasoonLocale(locale: MasoonDsLocale, content: @Composable () -> Unit) {
    CompositionLocalProvider(
        LocalMasoonLocale provides locale,
        LocalLayoutDirection provides locale.layoutDirection,
        content = content,
    )
}

@Composable
internal fun L(arabic: String, english: String): String =
    if (LocalMasoonLocale.current == MasoonDsLocale.ARABIC) arabic else english

@Composable
internal fun plannerLocale(): Locale = Locale.forLanguageTag(LocalMasoonLocale.current.languageTag)
