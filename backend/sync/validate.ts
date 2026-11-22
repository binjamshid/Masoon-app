// Structural validation for incoming plan events.

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** UUIDv7: version nibble 7, RFC 4122 variant. */
export const UUID_V7_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** ISO-8601 local datetime WITH offset, e.g. 2026-07-14T06:42:11+03:00. */
export const OCCURRED_AT_LOCAL_RE =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/;

/** PlanEvent taxonomy known to this server build. */
export const KNOWN_EVENT_TYPES: ReadonlySet<string> = new Set([
  "plan.created",
  "plan.activated",
  "plan.paused",
  "plan.resumed",
  "plan.policy_changed",
  "plan.curriculum_upgraded",
  "plan.recovery_applied",
  "plan.day_closed",
  "plan.superseded",
  "task.started",
  "task.completed",
  "task.uncompleted",
  "task.excused",
  "assessment.logged",
  "override.applied",
  "starting_state.declared",
  "starting_state.amended",
]);

/** Highest event schema_version this server build understands. */
export const KNOWN_MAX_SCHEMA_VERSION = 1;

/** Envelope fields the server owns/derives; client-supplied values are ignored. */
const SERVER_OWNED_FIELDS: ReadonlySet<string> = new Set([
  "actor_user_id",
  "actor_role",
  "device_id",
  "server_seq",
  "superseded_by",
  "received_at",
]);

const ENVELOPE_FIELDS: ReadonlySet<string> = new Set([
  "event_id",
  "type",
  "schema_version",
  "client_seq",
  "occurred_at_local",
  "payload",
]);

export interface PlanEventInput {
  event_id: string;
  type: string;
  schema_version: number;
  client_seq: number;
  occurred_at_local: string;
  payload: Record<string, unknown>;
}

export interface ValidationOutcome<T> {
  value?: T;
  /** Structural errors that prevent validation. */
  errors: Record<string, unknown>[];
  /** Acceptance notes and ignored-field notes. */
  warnings: string[];
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function isNonNegativeInt(v: unknown): v is number {
  return typeof v === "number" && Number.isSafeInteger(v) && v >= 0;
}

/**
 * Validate one PlanEvent envelope. `where` is a human-readable locator like
 * "batches[0].events[3]".
 */
export function validateEventEnvelope(
  raw: unknown,
  where: string,
): ValidationOutcome<PlanEventInput> {
  const errors: Record<string, unknown>[] = [];
  const warnings: string[] = [];

  if (!isPlainObject(raw)) {
    return {
      errors: [{ at: where, reason: "event must be an object" }],
      warnings,
    };
  }

  const e = raw as Record<string, unknown>;

  if (typeof e.event_id !== "string" || !UUID_V7_RE.test(e.event_id)) {
    errors.push({ at: `${where}.event_id`, reason: "must be a UUIDv7 string" });
  }
  if (
    typeof e.type !== "string" || e.type.length === 0 || e.type.length > 128
  ) {
    errors.push({ at: `${where}.type`, reason: "must be a non-empty string" });
  }
  if (
    typeof e.schema_version !== "number" ||
    !Number.isSafeInteger(e.schema_version) || e.schema_version < 1
  ) {
    errors.push({
      at: `${where}.schema_version`,
      reason: "must be an integer ≥ 1",
    });
  }
  if (!isNonNegativeInt(e.client_seq)) {
    errors.push({
      at: `${where}.client_seq`,
      reason: "must be an integer ≥ 0",
    });
  }
  if (
    typeof e.occurred_at_local !== "string" ||
    !OCCURRED_AT_LOCAL_RE.test(e.occurred_at_local) ||
    Number.isNaN(Date.parse(e.occurred_at_local))
  ) {
    errors.push({
      at: `${where}.occurred_at_local`,
      reason: "must be ISO-8601 with offset, e.g. 2026-07-14T06:42:11+03:00",
    });
  }
  if (!isPlainObject(e.payload)) {
    errors.push({ at: `${where}.payload`, reason: "must be a JSON object" });
  }

  // Ignore extra fields with a warning. The server assigns actor, device,
  // and sequencing metadata independently.
  for (const key of Object.keys(e)) {
    if (ENVELOPE_FIELDS.has(key)) continue;
    if (SERVER_OWNED_FIELDS.has(key)) {
      warnings.push(
        `${where}.${key}: server-owned field ignored; set by the server`,
      );
    } else {
      warnings.push(`${where}.${key}: unknown envelope field ignored`);
    }
  }

  if (errors.length > 0) return { errors, warnings };

  const event: PlanEventInput = {
    event_id: (e.event_id as string).toLowerCase(),
    type: e.type as string,
    schema_version: e.schema_version as number,
    client_seq: e.client_seq as number,
    occurred_at_local: e.occurred_at_local as string,
    payload: e.payload as Record<string, unknown>,
  };

  // Keep unfamiliar types and versions intact for forward compatibility.
  if (!KNOWN_EVENT_TYPES.has(event.type)) {
    warnings.push(
      `${where} (${event.event_id}): unknown event type '${event.type}' accepted as an opaque event`,
    );
  } else if (event.schema_version > KNOWN_MAX_SCHEMA_VERSION) {
    warnings.push(
      `${where} (${event.event_id}): schema_version ${event.schema_version} is newer than this validator understands; accepted as an opaque event`,
    );
  }

  return { value: event, errors, warnings };
}

/** Structural checks for override.applied payloads. */
export function validateOverridePayload(
  payload: Record<string, unknown>,
  where: string,
): Record<string, unknown>[] {
  const errors: Record<string, unknown>[] = [];
  if (payload.supersedes !== undefined) {
    if (
      !Array.isArray(payload.supersedes) ||
      payload.supersedes.some((x) => typeof x !== "string" || !UUID_RE.test(x))
    ) {
      errors.push({
        at: `${where}.payload.supersedes`,
        reason: "must be an array of event_id UUIDs",
      });
    }
  }
  if (payload.removed_task_uids !== undefined) {
    if (
      !Array.isArray(payload.removed_task_uids) ||
      payload.removed_task_uids.some((x) =>
        typeof x !== "string" || !UUID_RE.test(x)
      )
    ) {
      errors.push({
        at: `${where}.payload.removed_task_uids`,
        reason: "must be an array of task_uid UUIDs",
      });
    }
  }
  if (
    payload.effective_from !== undefined &&
    (typeof payload.effective_from !== "string" ||
      !/^\d{4}-\d{2}-\d{2}$/.test(payload.effective_from))
  ) {
    errors.push({
      at: `${where}.payload.effective_from`,
      reason: "must be a YYYY-MM-DD local date",
    });
  }
  return errors;
}
