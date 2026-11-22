# Testing a contribution

The [planner example](../backend/README.md) prints one row per task and a final state. Start with its focused test to check expected ranges, dates and deterministic task IDs. Change one fixture input at a time and explain any expected output changes in your PR.

- For Swift and Kotlin planning changes, run the focused unit check and fixture runner in the [Swift guide](../apps/ios/README.md) and [Kotlin guide](../apps/android/README.md). Compare task order, identifiers, ranges and final state across affected implementations.
- For changes to event validation, ordering and pagination, run the [sync tests](../backend/sync/README.md).
- For interface changes, exercise the [SwiftUI](../mobile-ui/ios/README.md) or [Compose](../mobile-ui/android/README.md) example in both languages. Check right-to-left layout, large text, and accessibility labels. Record the OS version and which interactions you personally verified.
- For changes to serialized fields, check the expected shape and compatibility with the [schemas](../contracts/README.md).

Use synthetic fixtures and include the commands and outcomes in the PR. Record compiler or device checks separately from a read of the source.


## Compare the same plan across languages

The TypeScript, Swift and Kotlin runners can all read `backend/examples/synthetic-plan`. With Deno 2, the Swift package toolchain and Gradle 9.5.1 available, run these commands from the repository root. Each comparison exits successfully when the five task rows and final state match byte-for-byte.

```sh
output_dir=$(mktemp -d)
deno run --no-config --no-remote --allow-read=backend/examples/synthetic-plan backend/engine/fixture_runner.ts backend/examples/synthetic-plan > "$output_dir/ts.stream"
swift run --package-path apps/ios/Packages FixtureRunner backend/examples/synthetic-plan > "$output_dir/swift.stream"
gradle -p apps/android --quiet :core:curriculum:fixtureRun --args=../../backend/examples/synthetic-plan > "$output_dir/kotlin.stream"
cmp "$output_dir/ts.stream" "$output_dir/swift.stream"
cmp "$output_dir/ts.stream" "$output_dir/kotlin.stream"
```
