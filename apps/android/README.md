# Kotlin libraries for Android

This project contains the JVM libraries used by Masoon’s Android client. Use it to work on the event model, schedule generation, curriculum authoring, audio planning, and right-to-left reader navigation.

| Module | What it contains |
| --- | --- |
| `:core:domain` | Plans, events, evidence, selection, and index parsers for caller-supplied Qur’an and poem metadata |
| `:core:curriculum` | Curriculum loading and validation, scheduling, forecasting, simulation, and the fixture runner |
| `:core:audio` | Catalog and manifest parsers, range-to-playback planning, a transport interface, and the repeat-pause controller |
| `:core:mushaf` | Right-to-left page and spread navigation, appearance preferences, controls visibility, and listening-evidence policy |

## Run the sample plan

Install a JDK 21 and [Gradle 9.5.1](https://gradle.org/releases/). Gradle resolves the pinned Kotlin plugin from the Gradle Plugin Portal and libraries from Maven Central. The first run needs access to those repositories. See the [version catalog](gradle/libs.versions.toml) for the dependency versions.

From the repository root, run the fixture:

```sh
gradle -p apps/android --quiet :core:curriculum:fixtureRun --args=fixtures/synthetic-poem
```

The runner loads [the input](fixtures/synthetic-poem/input.json), [a curriculum](fixtures/synthetic-poem/curriculum.json), and [an invented eight-unit corpus](fixtures/synthetic-poem/corpus.json). It emits three projected tasks for 5–7 January 2026, followed by a `#STATE` checkpoint. The units carry coordinates and weights only. The fixture’s source digest is the SHA-256 of the synthetic count row `1<TAB>8<LF>`.

Run the JVM tests:

```sh
gradle -p apps/android :core:domain:test :core:curriculum:test :core:audio:test :core:mushaf:test
```

## Distribution scope

The fixture and selected tests use synthetic inputs. These libraries require no Android SDK, device, service account, or signing setup. To load your own data, supply an authorized curriculum JSON and a corpus index to the same public interfaces used by the fixture runner.

The export excludes the APK build, platform integration and release tooling, signing and service configuration, product imagery, the asset pack, fonts and rendered headers, religious text and associated indexes, recitations and reciter catalogs, built-in curriculum data, and tests that need those materials. The Gradle wrapper and other third-party binaries are omitted. Kotlin and kotlinx.serialization use Apache License 2.0. The JUnit test dependencies use Eclipse Public License 2.0. Refer to the repository notices for third-party terms.
