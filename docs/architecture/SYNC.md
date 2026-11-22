# Offline and sync design

Local task recording is part of the client architecture. The remote exchange described here requires a configured, compatible sync service and an authorized account. See the [domain model](DOMAIN_MODEL.md) for event fields and [engine semantics](ENGINE_SEMANTICS.md) for projection.

## 1. Local write path

A client validates the action, assigns the event ID and local sequence, appends it, and regenerates affected tasks in one local database transaction. The plan store serializes writes within the process. The UI observes the committed local state. A late action includes the scheduled plan-local date so regeneration can include the affected day.

### Watch ingest

The Apple Watch companion queues actions for the phone via WatchConnectivity. The phone checks account scope, deduplicates by event ID, and checks whether a newer action already applies to the same task and scheduled date. The phone keeps the wrist event ID and action timestamp, assigns the phone's device ID and next client sequence, and writes through the same plan store transaction.

## 2. Outbox

The outbox groups pending events by plan and sends them in client sequence order. Each event keeps its original ID across retries. Transient failures remain retryable and may use backoff. A permanent validation failure can quarantine a batch for review while the queue continues with other work.

A compatible service authorizes the caller and the plan before accepting events. It validates the batch, assigns sequence numbers, and returns acknowledgment details for each accepted event. A valid replay uses the existing sequence. An acknowledged event may also carry a supersession reference. The client applies the response only to the account and batch that initiated it.

## 3. Pull and hydration

A device requests server-ordered changes after each plan's cursor. A new device hydrates plan metadata and the curriculum definitions needed to replay the log, then ingests event pages. Persist accepted events and cursor progress consistently so a restarted pull can resume safely. Re-fold with pending local events and regenerate affected tasks after ingesting changes.

Consume any server-authored snapshots through the appropriate client data layer. Authorization is checked when loading both events and snapshots.

## 4. Conflicts and corrections

The server can mark conflicting learner events as superseded by an authorized supervisor override. The client retains the original event and applies the replacement in the fold. This keeps history available for needs-attention and preserves any pending local actions during reconciliation.

A correction from the learner, such as uncompleting a task, is another event. When actions from multiple devices affect the same task, the server sequence establishes their acknowledged order. The scheduled date and task ID together identify the affected occurrence for regeneration.

## 5. Verification scenarios

Exercise local app restart before sync, replay after a lost acknowledgment, authorization or account changes in flight, multi-device actions on the same task, recovery after a rejected batch, supersession of a completion, and paginated hydration with pending local events. Verify plan-local date handling at time zone and daylight saving transitions in the client's clock layer.
