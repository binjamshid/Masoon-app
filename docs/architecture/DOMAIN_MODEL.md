# Domain model

## 1. Value objects

- A `CanonicalPosition` identifies one unit within a corpus. A `CanonicalRange` covers an inclusive, ordered span within a single work. A Qur’an range is scoped by riwāyah and uses `surah`, `ayah_start`, and `ayah_end`. A selection crossing surahs uses an array of ranges. Some serializers retain these field names for poem work and unit coordinates.
- A projection maps a canonical range to pages and lines in a specific edition. Edition and page can change independently of the canonical range.
- A `QuranAmount` combines a unit and value. The content index resolves it to an atomic-unit count or page-equivalent weight, depending on the unit. The planner uses integer micropages for weight calculations.
- A plan-local date and weekday describe calendar inputs. The app resolves wall-clock timestamps in the plan's time zone before handing dates to the engine.
- An [evidence requirement](../../contracts/json-schema/evidence-spec-v1.schema.json) describes what a task needs for completion. An [evidence payload](../../contracts/json-schema/evidence-payload-v1.schema.json) records what the learner or teacher submitted.

## 2. Plans and tasks

A plan pins a curriculum version, a content reference, policy, starting state, anchor date, and time zone. A plan may be owned by an individual learner or by a managed household profile. A managed profile represents a learner under a separate account and has no sign-in identity of its own. In supervised use, an organization associates a learner with authorized staff and can define versioned assessment forms.

A curriculum specifies calendar classes, sessions, selectors, rules, and triggers. The plan's policy supplies choices such as pace, active weekdays, and recovery behavior. Curriculum and policy updates form timelines of changes effective on particular plan dates.

A task instance is a regenerable projection of a plan, curriculum, and event log. Its ID is deterministic for a given plan and emission slot. The event log records actions, including completions, reversals, and supervisor overrides. A closed task can be missed if it lacks a completion and has neither been excused nor superseded. Evidence and policy determine when a completion also counts as verified.

## 3. Plan events

The event envelope carries an `event_id`, `plan_id`, `type`, `schema_version`, `payload`, `device_id`, `client_seq`, and `occurred_at_local`. A sync service may attach an actor, a `server_seq`, and a `superseded_by` reference. The client generates the UUIDv7 event ID once and reuses it on retry. `client_seq` increases on the writing device.

Event families include plan lifecycle and policy changes, starting-state declarations, task actions, supervisor overrides, and assessments. Task action payloads carry the task ID and its scheduled plan-local date. `occurred_at_local` is the action timestamp with its original UTC offset.

Preserve acknowledged event contents. A learner reversal or a supervisor correction is represented by a new event. Superseded records remain available in history. The fold applies acknowledged events in server sequence order, then pending local events in device and client sequence order. An unknown event type is preserved as opaque data and does not change the derived state.

## 4. Client boundaries

Screens call the application's data layer. The data layer owns transactions and sync coordination. The planner owns deterministic projection and keeps persistence, wall-clock resolution, and transport outside its core. See [engine semantics](ENGINE_SEMANTICS.md) and [offline and sync design](SYNC.md).
