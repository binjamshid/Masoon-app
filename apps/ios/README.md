# iOS Swift packages

This directory contains the Swift implementation of Masoon’s event model, curriculum planning engine and shared watch models. Use Swift 5.10 or later on macOS 14 or later. The libraries target iOS 17, macOS 14 and watchOS 10, and have no third-party package dependencies.

- `MasoonDomain` defines plan events, event folding, evidence, calendar arithmetic and caller-supplied content indexes.
- `MasoonCurriculum` loads and validates curriculum definitions, generates tasks and forecasts workload.
- `MasoonWatchShared` provides snapshot and evidence models, notification identifiers and local queue storage shared by the phone and watch.
- `FixtureRunner` reads a local fixture directory and prints the deterministic task stream and final plan state.

Run the focused planning check and the example from the repository root.

```sh
swift test --package-path apps/ios/Packages --filter SyntheticPlanTests
swift run --package-path apps/ios/Packages FixtureRunner apps/ios/Packages/Tests/MasoonCurriculumTests/Fixtures/synthetic-plan
```

The synthetic fixture uses an invented work with five numbered units. One task covers units 1–2 and the stream ends with a `#STATE` line. The zero corpus checksum marks invented metadata with no upstream source. The sample requires no account, network access or bundled content.

The production iOS and watchOS app targets are outside this distribution. The Xcode project depends on app-specific signing and service configuration. The production app also composes the data, account, billing, audio and Mushaf modules and expects resource bundles containing reference work databases, recitation metadata and page fonts. This package omits those modules and bundles, the app icons and artwork, and the production curriculum catalogs. The source supports callers supplying their own appropriately licensed content indexes and curriculum definitions.
