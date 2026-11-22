# TypeScript planning engine

Run the planner from the repository root with [Deno 2](https://deno.com/).

```sh
deno run --no-config --no-remote --no-prompt --allow-read=backend/examples/synthetic-plan backend/engine/fixture_runner.ts backend/examples/synthetic-plan
```

The example projects three evenings of study for the six-line
[sample poem](examples/synthetic-plan/window-lamp.txt). It prints three new
memorization tasks, two reviews, and a `#STATE` line with `status=completed`.
The example's `today` precedes the plan start, so these tasks represent a
projection.

```text
2028-05-01|study|evening|1|new_hifz|learn_lines|1:1-2|||||5|self|first_active_day|4ccca84c-83b6-5413-92c2-ee5a8ed4ef04
```

This row assigns lines 1–2 of work 1, estimates five minutes, and uses a
self-check for completion. The last field is a deterministic task ID.

## Change the example

- [input.json](examples/synthetic-plan/input.json) selects the content, starting
  position, date window, pace, and event log.
- [curriculum.json](examples/synthetic-plan/curriculum.json) defines study days,
  the new-material and review rules, and when the plan completes.
- [poem-ref.json](examples/synthetic-plan/poem-ref.json) defines the ordered
  works and counts their study units. `source_sha256` records the hash of the
  UTF-8 sample poem.

The wire fields `surah` and `ayah` represent work and line numbers in this
example. Keep the unit count and source hash aligned with any edits to the
sample text.

## Use the engine from TypeScript

Load the curriculum with `loadCurriculum` from [dsl.ts](engine/dsl.ts) and a
content index with `loadPoemIndex` from [poem_index.ts](engine/poem_index.ts) or
`loadQuranIndex` from [quran_index.ts](engine/quran_index.ts). Pass them to
`generate(context, window)` in [generator.ts](engine/generator.ts). The context
supplies a policy, calendar, starting position, event log, and explicit `today`
date. The generator returns tasks and a state snapshot. Its inputs and results
require no network, credentials, or database. Use validated curriculum and index
documents you have permission to use. The Qur’an adapter takes supplied
reference data.

Howard Hinnant documented the civil-date formulas used by
[types.ts](engine/types.ts) and dedicated those formulas to the public domain.
[Chrono-compatible date algorithms](https://howardhinnant.github.io/date_algorithms.html#Summary)

## Run the focused tests

```sh
deno test --no-config --no-remote --no-prompt --allow-read=backend/examples/synthetic-plan backend/engine/types_test.ts backend/engine/uuid5_test.ts backend/examples/synthetic-plan/fixture_test.ts
```
