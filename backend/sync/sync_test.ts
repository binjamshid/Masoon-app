import assert from "node:assert/strict";
import { canonicalJson, policyChecksum } from "./checksum.ts";
import {
  projectPlanEventsPage,
  PULL_PAGE_LIMIT,
  type ServerPlanEvent,
} from "./page.ts";
import {
  type PlanEventInput,
  validateEventEnvelope,
  validateOverridePayload,
} from "./validate.ts";

const planId = "00000000-0000-4000-8000-000000000001";
const deviceA = "00000000-0000-4000-8000-000000000002";
const deviceB = "00000000-0000-4000-8000-000000000003";
const eventId = "00000000-0000-7000-8000-00000000000a";
const overrideId = "00000000-0000-7000-8000-00000000000b";

const input: PlanEventInput = {
  event_id: eventId,
  type: "task.completed",
  schema_version: 1,
  client_seq: 0,
  occurred_at_local: "2026-01-01T08:00:00+00:00",
  payload: { task_uid: "00000000-0000-4000-8000-000000000004" },
};
const at = "batches[0].events[0]";

Deno.test("event validation normalizes UUIDs and discards server-owned fields", () => {
  const outcome = validateEventEnvelope({
    ...input,
    event_id: eventId.toUpperCase(),
    actor_role: "supervisor",
    device_id: deviceB,
    server_seq: 10,
    another_field: true,
  }, at);

  assert.deepEqual(outcome.value, input);
  assert.deepEqual(outcome.errors, []);
  for (const field of ["actor_role", "device_id", "server_seq"]) {
    assert.ok(
      outcome.warnings.some((warning) =>
        warning.startsWith(`${at}.${field}: server-owned field ignored`)
      ),
    );
  }
  assert.ok(
    outcome.warnings.some((warning) =>
      warning.startsWith(`${at}.another_field: unknown envelope field ignored`)
    ),
  );
});

Deno.test("event validation rejects malformed envelope fields", () => {
  const outcome = validateEventEnvelope({
    ...input,
    event_id: planId,
    client_seq: Number.MAX_SAFE_INTEGER + 1,
    schema_version: 0,
    occurred_at_local: "2026-01-01T08:00:00",
    payload: [],
  }, at);

  assert.equal(outcome.value, undefined);
  assert.deepEqual(
    outcome.errors.map((error) => error.at),
    ["event_id", "schema_version", "client_seq", "occurred_at_local", "payload"]
      .map((field) => `${at}.${field}`),
  );
});

Deno.test("event validation keeps unfamiliar types and versions opaque", () => {
  for (
    const event of [
      { ...input, type: "example.future", payload: { count: [1, 2] } },
      { ...input, schema_version: 2 },
    ]
  ) {
    const outcome = validateEventEnvelope(event, at);
    assert.deepEqual(outcome.value, event);
    assert.deepEqual(outcome.errors, []);
    assert.equal(outcome.warnings.length, 1);
    assert.match(outcome.warnings[0], /accepted as an opaque event/);
  }
});

Deno.test("override validation checks explicit supersession fields", () => {
  assert.deepEqual(validateOverridePayload({}, at), []);
  assert.deepEqual(
    validateOverridePayload({
      supersedes: [eventId],
      removed_task_uids: [input.payload.task_uid],
      effective_from: "2026-01-02",
    }, at),
    [],
  );
  const errors = validateOverridePayload({
    supersedes: "a label",
    removed_task_uids: [1],
    effective_from: "2026-01-02T08:00:00Z",
  }, at);
  assert.deepEqual(
    errors.map((error) => error.at),
    ["supersedes", "removed_task_uids", "effective_from"]
      .map((field) => `${at}.payload.${field}`),
  );
});

function row(serverSeq: number, deviceId: string = deviceA): ServerPlanEvent {
  return {
    ...input,
    event_id: `00000000-0000-7000-8000-${
      serverSeq.toString(16).padStart(12, "0")
    }`,
    server_seq: serverSeq,
    actor_role: "learner",
    superseded_by: null,
    device_id: deviceId,
  };
}

Deno.test("pull projection ends empty and exact-limit pages without a cursor", () => {
  assert.deepEqual(projectPlanEventsPage(planId, []), {
    plan_id: planId,
    events: [],
    next_cursor: null,
  });

  const rows = Array.from({ length: PULL_PAGE_LIMIT }, (_, i) => row(i + 1));
  const page = projectPlanEventsPage(planId, rows);
  assert.deepEqual(page.events, rows);
  assert.equal(page.next_cursor, null);
});

Deno.test("pull projection emits a cursor for the last returned row", () => {
  // Sequences can have gaps. The sentinel appears on the next page.
  const rows = Array.from(
    { length: PULL_PAGE_LIMIT + 1 },
    (_, i) => row((i + 1) * 3),
  );
  const page = projectPlanEventsPage(planId, rows);
  assert.equal(page.events.length, PULL_PAGE_LIMIT);
  assert.ok(page.next_cursor);

  const lastReturnedSeq = PULL_PAGE_LIMIT * 3;
  const cursor = JSON.parse(atob(page.next_cursor));
  assert.deepEqual(cursor, {
    plan_id: planId,
    after_server_seq: lastReturnedSeq,
  });

  const nextPage = projectPlanEventsPage(
    cursor.plan_id,
    rows.filter((event) => event.server_seq > cursor.after_server_seq),
  );
  assert.deepEqual(nextPage.events, [rows[PULL_PAGE_LIMIT]]);
  assert.equal(nextPage.next_cursor, null);
});

Deno.test("pull projection preserves device and supersession metadata", () => {
  const first = { ...row(1), superseded_by: overrideId };
  const storageRow = { ...first, storage_metadata: "synthetic" };
  const second = row(2, deviceB);
  assert.equal(first.client_seq, second.client_seq);
  assert.deepEqual(
    projectPlanEventsPage(planId, [storageRow, second]).events,
    [first, second],
  );
});

Deno.test("policy checksums use canonical JSON regardless of object key order", async () => {
  const first = { pace: 2, flags: [true, { z: false, a: null }] };
  const second = { flags: [true, { a: null, z: false }], pace: 2 };
  assert.equal(
    canonicalJson(first),
    '{"flags":[true,{"a":null,"z":false}],"pace":2}',
  );
  assert.equal(
    await policyChecksum(first),
    "2d62382c6075d7bdba6edd08929c2520361b75c91930e3bb3929e23a29853faa",
  );
  assert.equal(await policyChecksum(first), await policyChecksum(second));
  assert.notEqual(
    await policyChecksum(first),
    await policyChecksum({
      ...first,
      flags: [...first.flags].reverse(),
    }),
  );
});
