package masoon.publicui.designsystem

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

@Composable
internal fun Chip(
    text: String,
    tint: Color,
    icon: ImageVector? = null,
) {
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(MasoonColors.surfaceSecondary)
            .padding(horizontal = MasoonSpacing.sm + 2.dp, vertical = MasoonSpacing.xs + 1.dp)
            .semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(MasoonSpacing.xs),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
        }
        Text(text, style = MasoonTypeStyle.Caption.toTextStyle(color = tint))
    }
}

@Composable
internal fun Modifier.masoonCard(): Modifier {
    val shape = RoundedCornerShape(MasoonRadius.lg)
    return this
        .clip(shape)
        .background(MasoonColors.surface, shape)
        .border(1.dp, MasoonColors.outline, shape)
}
