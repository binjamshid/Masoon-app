// Event fold & status derivation (ENGINE_SEMANTICS §9, DOMAIN_MODEL §3).
//
// Fold order: all acked events by server_seq, then local-unacked events by
// (device_id, client_seq). Superseded events fold as no-ops for state but
// remain visible for history/status derivation.

import {
  CurriculumUpgradedPayload,
  EngineError,
  EpochDay,
  parseLocalDate,
  PausePayload,
  PlanEvent,
  PlanPolicy,
  PolicyChangePayload,
  RecoveryAppliedPayload,
  ResumePayload,
  TaskCompletedPayload,
  TaskRefPayload,
  TaskStatus,
} from "./types.ts";

export interface CompletionRecord {
  completed: boolean;
  verified: boolean;
  excused: boolean;
  started: boolean;
  /** true if a superseded completion exists but no live one (status derivation). */
  supersededCompletion: boolean;
}

export interface PauseInterval {
  from: EpochDay; // first paused day (inclusive)
  resumeAnchor?: EpochDay; // generation resumes at this day (exclusive end); open if absent
}

export interface PolicyTimelineEntry {
  effectiveFrom: EpochDay;
  patch: Record<string, unknown>;
}

/**
 * D-054 curriculum switch, folded from `plan.curriculum_upgraded`: append-only
 * in fold order, one entry per well-formed event. Day D resolves to the entry
 * with the greatest `effectiveFrom ≤ D` (ties broken by fold order — the later
 * fold wins, mirroring `policyTimeline`); the base curriculum applies before
 * the earliest entry or when the timeline is empty.
 */
export interface CurriculumChange {
  effectiveFrom: EpochDay;
  slug: string;
  version: string;
}

export interface FoldResult {
  /** per task_uid derived completion facts. */
  completions: Map<string, CompletionRecord>;
  /** policy patches in fold order (apply cumulatively; day D uses entries with effectiveFrom ≤ D). */
  policyTimeline: PolicyTimelineEntry[];
  /** curriculum switches in fold order (PC-1). Empty for every single-curriculum plan. */
  curriculumTimeline: CurriculumChange[];
  pauses: PauseInterval[];
  /** dates on which plan.recovery_applied took effect, in fold order. */
  recoveryApplications: EpochDay[];
}

/** Deterministic fold order (I-3). Stable; input order never matters beyond the sort keys. */
export function orderEvents(events: readonly PlanEvent[]): PlanEvent[] {
  const acked = events.filter((e) => typeof e.server_seq === "number");
  const local = events.filter((e) => typeof e.server_seq !== "number");
  acked.sort((a, b) => (a.server_seq! - b.server_seq!) || cmpStr(a.event_id, b.event_id));
  local.sort(
    (a, b) => cmpStr(a.device_id, b.device_id) || (a.client_seq - b.client_seq) || cmpStr(a.event_id, b.event_id),
  );
  return [...acked, ...local];
}

function cmpStr(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/** Civil date of an ISO8601 local timestamp with offset (no Date parsing). */
export function localDateOfTimestamp(ts: string): EpochDay {
  const m = /^(\d{4}-\d{2}-\d{2})[T ]/.exec(ts);
  if (!m) throw new EngineError(`invalid occurred_at_local timestamp: ${JSON.stringify(ts)}`);
  return parseLocalDate(m[1]);
}

function eventEffectiveDate(e: PlanEvent, explicit?: string): EpochDay {
  if (explicit) return parseLocalDate(explicit);
  return localDateOfTimestamp(e.occurred_at_local);
}

export function foldEvents(events: readonly PlanEvent[]): FoldResult {
  const completions = new Map<string, CompletionRecord>();
  const policyTimeline: PolicyTimelineEntry[] = [];
  const curriculumTimeline: CurriculumChange[] = [];
  const pauses: PauseInterval[] = [];
  const recoveryApplications: EpochDay[] = [];

  const rec = (uid: string): CompletionRecord => {
    let r = completions.get(uid);
    if (!r) {
      r = { completed: false, verified: false, excused: false, started: false, supersededCompletion: false };
      completions.set(uid, r);
    }
    return r;
  };

  for (const e of orderEvents(events)) {
    const superseded = e.superseded_by != null;
    switch (e.type) {
      case "task.started": {
        const p = e.payload as unknown as TaskRefPayload;
        if (!superseded && p?.task_uid) rec(p.task_uid).started = true;
        break;
      }
      case "task.completed": {
        const p = e.payload as unknown as TaskCompletedPayload;
        if (!p?.task_uid) break;
        const r = rec(p.task_uid);
        if (superseded) {
          if (!r.completed) r.supersededCompletion = true;
        } else {
          r.completed = true;
          r.supersededCompletion = false;
          if (p.verified === true || p.evidence?.kind === "teacher_verification") r.verified = true;
        }
        break;
      }
      case "task.uncompleted": {
        const p = e.payload as unknown as TaskRefPayload;
        if (!superseded && p?.task_uid) {
          const r = rec(p.task_uid);
          r.completed = false;
          r.verified = false;
        }
        break;
      }
      case "task.excused": {
        const p = e.payload as unknown as TaskRefPayload;
        if (!superseded && p?.task_uid) rec(p.task_uid).excused = true;
        break;
      }
      case "plan.policy_changed": {
        if (superseded) break;
        const p = e.payload as unknown as PolicyChangePayload;
        // §11.20: policy_changed without effective_from (or patch) is
        // malformed and ignored as a deterministic no-op.
        if (!p?.patch || !p.effective_from) break;
        policyTimeline.push({ effectiveFrom: parseLocalDate(p.effective_from), patch: p.patch });
        break;
      }
      case "override.applied": {
        if (superseded) break;
        const p = e.payload as unknown as PolicyChangePayload;
        if (!p?.patch) break;
        // D-032.5 / §11.20: an override without effective_from applies from
        // the beginning of the plan (supervisor authority never narrowed).
        const from = p.effective_from ? parseLocalDate(p.effective_from) : Number.NEGATIVE_INFINITY;
        policyTimeline.push({ effectiveFrom: from, patch: p.patch });
        break;
      }
      case "plan.curriculum_upgraded": {
        if (superseded) break;
        const p = e.payload as unknown as CurriculumUpgradedPayload;
        // D-054 (I-4 house style, same as plan.policy_changed above): a missing
        // `slug` or `effective_from` makes the WHOLE event a deterministic
        // no-op — including any bundled `policy_patch`.
        if (!p?.slug || !p.effective_from) break;
        const from = parseLocalDate(p.effective_from);
        curriculumTimeline.push({ effectiveFrom: from, slug: p.slug, version: p.version ?? "" });
        // A bundled `policy_patch` rides the SAME effective_from into the
        // policy timeline (not a supervisor override).
        if (p.policy_patch) policyTimeline.push({ effectiveFrom: from, patch: p.policy_patch });
        break;
      }
      case "plan.paused": {
        if (superseded) break;
        const p = (e.payload ?? {}) as PausePayload;
        pauses.push({ from: eventEffectiveDate(e, p.effective_from) });
        break;
      }
      case "plan.resumed": {
        if (superseded) break;
        const p = e.payload as unknown as ResumePayload;
        if (!p?.anchor) throw new EngineError(`plan.resumed event ${e.event_id} missing anchor`);
        const open = pauses.find((x) => x.resumeAnchor === undefined);
        if (open) open.resumeAnchor = parseLocalDate(p.anchor);
        break;
      }
      case "plan.recovery_applied": {
        if (superseded) break;
        const p = (e.payload ?? {}) as RecoveryAppliedPayload;
        recoveryApplications.push(eventEffectiveDate(e, p.effective_from));
        break;
      }
      default:
        // Unknown types are preserved opaquely (I-4): fold ignores them.
        break;
    }
  }

  return { completions, policyTimeline, curriculumTimeline, pauses, recoveryApplications };
}

export function isPausedOn(fold: FoldResult, day: EpochDay): boolean {
  for (const p of fold.pauses) {
    if (day >= p.from && (p.resumeAnchor === undefined || day < p.resumeAnchor)) return true;
  }
  return false;
}

/**
 * PC-6 policy-patch semantics (B:CB-0 finding 5 — this replaces the old
 * `Object.assign(out, entry.patch)`, which shallow-clobbered whole nested
 * dicts and copied unrecognized keys straight through).
 *
 *  - MERGE_DICT keys (`variable_overrides`, `evidence_policy`) are per-name
 *    dictionaries: a present object merges KEY BY KEY over what is already
 *    there, so two cumulative patches compose instead of the second erasing
 *    the first's names. PC-6(b): a present JSON `null` CLEARS the whole dict
 *    back to the curriculum's own defaults.
 *  - `murajaah_ramp` holds ONE value, so PC-6(b)'s `null` resets it to absent
 *    (§11.7 then falls back to the curriculum DSL ramp).
 *  - Every other whitelisted key REPLACES the field wholesale.
 *  - An ABSENT key always means "don't touch" (only a present `null` clears).
 *
 * An unrecognized key is ignored, matching Swift (`PlanPolicy.applying(patch:)`
 * has no `else` branch). Kotlin throws on one; no fixture exercises either, and
 * this engine is the server's write-time authority, where silently ignoring an
 * unknown key is strictly safer than rejecting a whole plan. See the report.
 */
const MERGE_DICT_KEYS = new Set(["variable_overrides", "evidence_policy"]);
const REPLACE_KEYS = new Set([
  "new_amount",
  "target_range",
  "memorization_order",
  "active_weekdays",
  "listening_days",
  "listening_count",
  "takrar_count",
  "takrar_spacing_minutes",
  "murajaah_daily_ceiling",
  "recovery_policy",
  "cycle_week_mode",
  "sessions",
  "separate_session_completion",
]);

export function applyPolicyPatch(policy: PlanPolicy, patch: Record<string, unknown>): PlanPolicy {
  const out = { ...policy } as PlanPolicy & Record<string, unknown>;
  for (const [key, value] of Object.entries(patch)) {
    if (MERGE_DICT_KEYS.has(key)) {
      if (value === null) {
        out[key] = {};
      } else if (typeof value === "object" && !Array.isArray(value)) {
        out[key] = { ...(out[key] as Record<string, unknown> ?? {}), ...(value as Record<string, unknown>) };
      }
      continue;
    }
    if (key === "murajaah_ramp") {
      if (value === null) out.murajaah_ramp = null;
      else if (typeof value === "object") out.murajaah_ramp = value as PlanPolicy["murajaah_ramp"];
      continue;
    }
    if (REPLACE_KEYS.has(key)) {
      if (value !== null && value !== undefined) out[key] = value;
      continue;
    }
    // Unrecognized key: no-op (Swift parity).
  }
  return out;
}

/** Effective policy for day D: base policy plus every patch with effectiveFrom ≤ D, in fold order. */
export function policyAt(base: PlanPolicy, fold: FoldResult, day: EpochDay): PlanPolicy {
  let out = base;
  for (const entry of fold.policyTimeline) {
    if (entry.effectiveFrom <= day) out = applyPolicyPatch(out, entry.patch);
  }
  return out;
}

/**
 * PC-4 (D-054): which curriculum key applies on `day` — the timeline entry with
 * the greatest `effectiveFrom ≤ day`, ties broken by fold order (later wins).
 * `null` before the earliest entry, or when the timeline is empty.
 */
export function curriculumChangeAt(fold: FoldResult, day: EpochDay): CurriculumChange | null {
  let best: CurriculumChange | null = null;
  for (const entry of fold.curriculumTimeline) {
    if (entry.effectiveFrom <= day && (best === null || entry.effectiveFrom >= best.effectiveFrom)) best = entry;
  }
  return best;
}

/**
 * Derived task status (PRD §7.4 / DOMAIN_MODEL invariants). Never stored:
 * completed ⟺ non-superseded task.completed exists; verified adds teacher
 * verification; missed ⟺ date < today ∧ no completion ∧ not excused/superseded.
 */
export function deriveTaskStatus(
  fold: FoldResult,
  taskUid: string,
  taskDate: EpochDay,
  today: EpochDay,
): TaskStatus {
  const r = fold.completions.get(taskUid);
  if (r) {
    if (r.completed) return r.verified ? "verified" : "completed";
    if (r.excused) return "excused";
    if (r.supersededCompletion) return "superseded";
    if (taskDate < today) return "missed";
    if (r.started) return "in_progress";
    return "pending";
  }
  return taskDate < today ? "missed" : "pending";
}
