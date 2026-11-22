package masoon.publicui.demo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import masoon.publicui.designsystem.L
import masoon.publicui.designsystem.MasoonDsLocale
import masoon.publicui.designsystem.MasoonTheme
import masoon.publicui.designsystem.ProvideMasoonLocale
import masoon.publicui.planner.PlannerWeeklyCallbacks
import masoon.publicui.planner.WeeklyBoardScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { WeeklyBoardDemo() }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WeeklyBoardDemo() {
    var showArabic by rememberSaveable { mutableStateOf(true) }
    var weekOffset by rememberSaveable { mutableIntStateOf(0) }
    val locale = if (showArabic) MasoonDsLocale.ARABIC else MasoonDsLocale.ENGLISH
    ProvideMasoonLocale(locale) {
        MasoonTheme {
            Scaffold(
                topBar = {
                    TopAppBar(
                        title = { Text(L("خطة أسبوعية تجريبية", "Sample weekly plan")) },
                        actions = {
                            TextButton(onClick = { showArabic = !showArabic }) {
                                Text(L("English", "العربية"))
                            }
                        },
                    )
                },
            ) { padding ->
                WeeklyBoardScreen(
                    state = sampleWeek(weekOffset, showArabic),
                    callbacks = PlannerWeeklyCallbacks(
                        onWeekShift = { weekOffset += it },
                        onJumpToCurrentWeek = { weekOffset = 0 },
                    ),
                    modifier = Modifier.padding(padding),
                )
            }
        }
    }
}
