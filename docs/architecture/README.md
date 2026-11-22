# Architecture

Masoon's iOS and Android clients calculate study schedules and record learner actions in a local database. The planner takes a curriculum definition, a content index, plan policy, a local calendar, and a plan event log. It produces tasks and derived plan state. The TypeScript engine exposes the same scheduling model for fixtures and server-side use.

## Follow a task completion

1. The Today screen sends the plan ID, task ID, scheduled local date, and completion evidence to the local data layer.
2. The plan store appends a `task.completed` event and regenerates affected tasks in the same database transaction. The UI observes the local result. This path works offline.
3. In a configured sync deployment, the outbox submits pending events. The sync service authorizes each plan and acknowledges events by ID. A receiving client applies server-ordered events and regenerates its local projection. See the [offline and sync design](SYNC.md).

| Area | Where to start |
| --- | --- |
| Platform entry points and setup | [iOS](../../apps/ios/README.md) and [Android](../../apps/android/README.md) |
| Planner and synthetic fixture | [TypeScript engine](../../backend/README.md) |
| Versioned data formats | [Contracts](../../contracts/README.md) |
| Cross-platform invariants | [Domain model](DOMAIN_MODEL.md), [engine semantics](ENGINE_SEMANTICS.md), and [engine parity](ENGINE_PARITY.md) |

## Content and services

A plan references the corpus by canonical coordinates. The reader maps those coordinates to an edition-specific page and line layout. Playback uses separately configured audio sources and can use downloaded per-surah packages. The engine's synthetic fixture exercises scheduling with a standalone content index.

The service flows in these docs specify how clients and a compatible backend interact. The public checkout provides source and specifications. Running network features requires your own configured service and any applicable permissions for the content it serves.
