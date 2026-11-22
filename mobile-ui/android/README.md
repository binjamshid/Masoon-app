# Masoon-app Weekly Planner for Android

This Compose example contains the Weekly Board from Masoon-app's Android planner. It displays a week of study tasks grouped into morning and evening sessions, with a status on each day. The example uses a synthetic schedule anchored on April 15, 2026 so week navigation is reproducible. The language control switches between Arabic with a right-to-left layout and English with a left-to-right layout. The schedule runs offline and resets when the app is started fresh.

## Run locally

Use JDK 21, Gradle 9.5.1, and the Android SDK Platform 37 (37.0). Install an SDK emulator image for API 29 or newer, or connect a device at that API level. Set `ANDROID_HOME` to your SDK directory or let Android Studio generate `local.properties`. Install Gradle separately.

From the repository root, build and install a debug APK.

```sh
gradle -p mobile-ui/android :app:assembleDebug
adb install -r mobile-ui/android/app/build/outputs/apk/debug/app-debug.apk
```

Open **Masoon-app Weekly Planner** on the device. You can also open `mobile-ui/android` in Android Studio and run its `app` configuration.

On the opening week, check that April 15 shows **Today**, **Consolidation**, and **Partial**. Verify that both navigation arrows move the date range by seven days and **Back to current week** restores the opening week. Switch the language and check that the labels, digits, and arrow directions update together. Scroll to a rest day and check legibility in dark mode and at a larger system font size.

## Work on the UI

`app/src/main/kotlin/masoon/publicui/planner` holds the board and its presentation models. `designsystem` provides its theme, locale provider, and shared card and chip styles. The `demo` package hosts the board and supplies the example schedule. To use it in another Compose host, provide a `PlannerWeeklyState` and `PlannerWeeklyCallbacks` to `WeeklyBoardScreen` under `ProvideMasoonLocale`. Supply a week-start date, ordered days and session IDs, and optional localized task detail. The host owns the schedule, week selection, and task data.

The export retains the original board, day status vocabulary, task presentation, and visual tokens. It replaces storage-backed presentation models and canonical range formatting with plain UI state and host-supplied details. The reader, content and layout data, production service configuration, and app art are outside this module.

## Dependencies

The build files pin Android Gradle Plugin 9.3.1, Kotlin and the Compose compiler 2.4.10, AndroidX Activity Compose 1.13.0, and Compose BOM 2026.06.01. Gradle fetches AndroidX Compose and Material icons from their publishers. See the repository's third-party notices for applicable licenses.
