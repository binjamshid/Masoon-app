# Masoon-app SwiftUI components

This package contains the study interface used to show sessions, tasks, repetition counts, elapsed time and progress. The library also includes the named-listener attestation form, chart cards with accessible data tables, and shared controls for forms and status.

The demo uses the same components with invented practice labels and numbers. Use **العربية** to switch to Arabic, Arabic-Indic numerals and right-to-left layout. In **Session**, try counting repetitions, starting or pausing the timer, and opening the attestation form with a made-up name. In **Activity**, open the chart’s data table. The card opens the table automatically when VoiceOver is enabled.

## Run the demo

Open the included Xcode project with Xcode 16 or newer. Select the **MasoonUIDemo** scheme and an iOS 17 or newer simulator, then choose **Run**. The app uses a local package and the simulator needs no signing credentials.

```sh
open mobile-ui/ios/Demo/MasoonUIDemo.xcodeproj
```

On macOS 14 or newer, run the same SwiftUI catalog directly from the repository root.

```sh
swift run --package-path mobile-ui/ios MasoonUIDemo
```

For a preview in Xcode, select **MasoonUIDemoApp.swift** under **MasoonUIDemo** and open the Canvas.

## Use the library

Add this directory as a local Swift package and link the **MasoonUI** library product. Pass your own display values and bindings. Set the SwiftUI locale and layout direction on the enclosing view. The attestation form hands a submission to its caller through a closure. In the demo, submitting a form changes a sample task’s status in memory and discards the form fields.

The library uses Apple frameworks and system colors. This source export excludes the production app shell, branding artwork, downloaded content, Qur’an text, fonts and page geometry, networking, accounts, and release configuration.
