# Engine parity

Swift, Kotlin, and TypeScript engines use the same inputs to produce the same normalized task stream. Use [engine semantics](ENGINE_SEMANTICS.md) for scheduling behavior and the [backend setup guide](../../backend/README.md) for the synthetic TypeScript fixture.

## 1. Deterministic inputs

Pass the planner a curriculum version, content index, start state, policy, calendar, event log, today's plan-local date, and requested window. Resolve clock and time zone dependencies before invoking the engine. Use decimal strings for policy amounts that can be fractional and convert them to integer micropages at the defined rounding point. Keep reference data the same on every runner.

Sort tasks by date, session (`morning`, `evening`, `anytime`), integer ordering, and ASCII rule identifier. Reuse the engine's emission order within tied slots.

## 2. Task identity

Use UUIDv5 with the plan ID as the namespace and the UTF-8 name `{date}|{session}|{origin_rule_id}|{occurrence}`. The date is `YYYY-MM-DD`. The occurrence counter starts at zero for each rule in a given date and session. Serialize the UUID in lowercase hyphenated form.

## 3. Normalized task stream

Serialize one UTF-8 line per task in this field order.

```text
date|day_class|session|ordering|type|origin_rule_id|content|reps|spacing_min|listen_count|window|est_min|evidence|flags|task_uid
```

- Use `YYYY-MM-DD` for a local date. A window is `{opens_on}..{closes_on}`.
- Serialize a canonical range as `{surah}:{ayah_start}-{ayah_end}`. Join several ranges with `+` in task selection order. These slots are work and unit coordinates for a poem corpus.
- Serialize evidence as `self`, `timer:{seconds}`, `counter:{count}`, `teacher`, `form:{version_id}`, or `composite({part}+{part})` with the same encoding applied recursively. A missing evidence requirement is empty.
- Join flags with commas in ASCII order. Absent optional values produce empty fields. Field values must be free of pipe and newline characters.

Append one state checkpoint line after the tasks.

```text
#STATE|cursor={surah}:{ayah}|juz_done={count}|cycle_weeks={count}|debt_new={count}|status={plan_status}
```

An exhausted cursor is `-`. The fixed `juz_done` field counts completed structural units such as juzʾ boundaries or works, according to the corpus. End the stream with exactly one LF.

## 4. Fixture input

A fixture directory contains an `input.json` with `plan_id`, `curriculum_definition`, `today`, `window`, `policy`, `starting_state`, `calendar`, and `event_log`. The curriculum definition path resolves relative to the fixture directory. Optional `extra_curricula` contains inline `{slug, version, definition}` entries for replaying curriculum version changes.

Supply exactly one of the following content references.

- `quran_ref` is a relative path to a Qur’an reference index.
- `corpus_ref` carries a `kind` and relative `path`. The `quran` kind is equivalent to `quran_ref`. The `poem` kind uses a [corpus reference document](../../contracts/json-schema/corpus-ref-v1.schema.json). Its declared kind must agree with the fixture.

## 5. Verification

Compare the normalized stream byte for byte across runners given identical, redistributable inputs. Compare against an independently reviewed expected stream when checking an engine behavior change. A single engine replay verifies that runner. Cross-platform parity requires replay on all engines being compared. Verify device-side date resolution separately because the fixture hands a resolved local date to the engine.
