import type { PlanEventInput } from "./validate.ts";

export const PULL_PAGE_LIMIT = 500;

export interface ServerPlanEvent extends PlanEventInput {
  server_seq: number;
  actor_role: string;
  superseded_by: string | null;
  /** A client sequence is only monotonic within its originating device. */
  device_id: string;
}

export interface PlanEventsPage {
  plan_id: string;
  events: ServerPlanEvent[];
  next_cursor: string | null;
}

/** Encode a continuation cursor for a plan UUID and its last returned sequence. */
export function encodeNextCursor(
  planId: string,
  afterServerSeq: number,
): string {
  return btoa(
    JSON.stringify({ plan_id: planId, after_server_seq: afterServerSeq }),
  );
}

/**
 * Project rows the caller is authorized to read for one plan. The caller
 * provides rows strictly after its cursor, in ascending server_seq order,
 * including a sentinel row when more than PULL_PAGE_LIMIT rows remain.
 */
export function projectPlanEventsPage(
  planId: string,
  rows: readonly ServerPlanEvent[],
): PlanEventsPage {
  const page = rows.slice(0, PULL_PAGE_LIMIT);
  return {
    plan_id: planId,
    events: page.map((row) => ({
      server_seq: row.server_seq,
      event_id: row.event_id,
      type: row.type,
      schema_version: row.schema_version,
      client_seq: row.client_seq,
      occurred_at_local: row.occurred_at_local,
      payload: row.payload,
      actor_role: row.actor_role,
      superseded_by: row.superseded_by,
      device_id: row.device_id,
    })),
    next_cursor: rows.length > PULL_PAGE_LIMIT
      ? encodeNextCursor(planId, page[PULL_PAGE_LIMIT - 1].server_seq)
      : null,
  };
}
