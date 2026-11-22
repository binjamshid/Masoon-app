# Engine semantics

The planner interprets versioned [curriculum definitions](../../contracts/json-schema/curriculum-v1.schema.json) against a content index. The rules below describe the v1 engine. A curriculum chooses which rules, selectors, and triggers to use.

## 1. Units and workload

A page-equivalent is 1,000,000 micropages. For Qur’an page-based calculation, each ayah receives the integer quotient of 1,000,000 divided by the number of ayahs assigned to its projection page. A range weighs the sum of its ayah weights. The standard Qur’an amounts use 20,000,000 micropages per juzʾ, 10,000,000 per hizb, 2,500,000 per rubʿ, and 66,666 per line. Decimal amounts convert to integer micropages with round-half-up. Ayah-count selection uses the number of atomic units.

A corpus with a uniform atomic-unit weight can convert a unit count into micropages. With a nonuniform index, a selector that requires a weight must receive a supported weight-based amount. For example, the [poem reference format](../../contracts/json-schema/corpus-ref-v1.schema.json) specifies 100,000 micropages per atomic unit.

The workload calculation uses integer rates and strength multipliers. The multipliers, scaled by 1,000, are 1,000 for strong, 1,200 for moderate, and 1,500 for weak material. Mixed-strength selections sum weighted units before rounding the result to minutes. Repetition estimates include the number of repetitions. Listening multiplies the lesson rate by the number of listens.

## 2. New material

The new-material selector walks from the cursor in memorization order and returns whole units. For a page-equivalent Qur’an amount, it takes the smallest prefix that reaches the weight target. If that prefix exceeds the target by more than 400,000 micropages, it can drop the final unit while keeping at least one. Crossing a surah boundary is permitted when the tail of the current surah is smaller than a third of the requested amount.

The plan supplies a memorization order. Canonical forward order and explicit custom ranges are examples. The cursor advances once the applicable completion condition is met. A curriculum can require teacher verification before advancing.

## 3. Ledgers and windows

Past and current dates use completion events to populate the new-material ledger. Future dates use projected completions. Warm-up and review selectors can query ranges from an exact prior day, a rolling window, or the current week. Content-bearing rules with an empty selection produce no task. An information-only rule can emit without a range.

## 4. Rotation

A rotating review pool can draw on declared starting knowledge and material completed in the plan. The selector may remove material already covered by a warm-up window. Daily volume can be derived from a ramp and ceiling or from a fixed target interval across the pool. The rotation cursor wraps around and advances on qualifying completions. Projected dates assume completion.

Where enabled, weak material has half its normal rotation weight. This gives it more frequent review while preserving its full content weight for workload calculations.

## 5–6. Boundary triggers and inserted weeks

A boundary trigger can fire when in-plan completions cover a complete structural unit such as a juzʾ or a work. Declared prior knowledge contributes to review pools. In-plan completion is what advances the boundary count.

A trigger can schedule whole-unit review, split a pool into whole-unit slices, or insert a week with extra rules and suppression of ordinary rules. Distributing a pool uses cumulative weight boundaries. Each nonempty slice stays in the corresponding slot, with unavailable days handled by the scheduling rules. A curriculum can defer an inserted week until scheduled reviews finish. Support for a DSL branch must be checked in the engine because some schema-accepted constructs, such as `cursor_reaches` and flag effects, have no v1 behavior.

## 7. Listening look-ahead

A next-material listening selector previews the next eligible new-material task within the engine's look-ahead window. The preview uses the effective policy for that date and assumes completion of the current day's new task. An empty preview produces no listening task.

## 8. Recovery

Only closed dates can accrue missed-work debt. The engine treats a closed, unexcused new-material task that failed its advancement gate as a missed slot. Completing the material later advances the cursor. The lost slot can still affect the projected finish date.

- `strict_backlog` resumes from the held cursor. Missed slots can move the projected finish date.
- `redistribute` can add bounded weight to subsequent eligible days. It calculates the debt at the first boosted day, divides remaining debt by remaining boost days with round-half-up, and caps the extra by the configured daily maximum. Each boosted day consumes a day of the recovery window. Completing a boosted task reduces the remaining weight by the extra that day.
- `pause_and_resume` suspends generation during a pause interval and resumes from a supplied anchor.

A failed-task trigger can insert a recovery week. Separately, a scheduled review week can suppress new-material tasks as part of its curriculum. The cause of the suppression determines whether the closed slots accrue debt.

## 9. Fold and generation modes

Fold acknowledged events in server sequence order, followed by unacknowledged local events in device and client sequence order. A superseded record is kept for history and plays no active part in plan state. Use a task event's `payload.date` for the scheduled day. Older records may fall back to the date part of `occurred_at_local`.

For a date on or before `today`, calculate state from actual events. For dates after `today`, project as if the emitted content tasks complete. A date on or before `today` can still be open for completion. Use the effective policy and curriculum for each plan date. Policy changes require an effective date. Some older supervisor overrides without one apply from the plan start.

## 10. Ordering and task IDs

Use [engine parity](ENGINE_PARITY.md) for task ordering, UUID generation, and the normalized stream. Emission slots feed task IDs and the completion log. Changes to ordering or ID inputs therefore need review alongside schedule behavior.
