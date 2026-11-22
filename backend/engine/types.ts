// Masoon curriculum engine — shared types & pure civil-date arithmetic.
//
// The reference and event shapes mirror the planner's wire format.
//
// The engine is pure: no Date objects, no clocks, no locale, no I/O.
// All size math is integer micropages (µp): 1 page = 1_000_000 µp.

// ---------------------------------------------------------------------------
// Canonical Quran references (riwayah implicit = hafs v1 for fixture data)
// ---------------------------------------------------------------------------

export interface CanonicalRange {
  surah: number; // 1..114
  ayah_start: number;
  ayah_end: number; // inclusive; single-surah by construction
}

export interface CanonicalPosition {
  surah: number;
  ayah: number;
}

export type QuranUnit = "ayah" | "line" | "page" | "rub" | "hizb" | "juz" | "custom";

/** `value` is a decimal string in fixtures; compiled curricula may carry numbers. */
export interface QuranAmount {
  unit: QuranUnit;
  value: string | number;
}

// Micropage constants (ENGINE_SEMANTICS §1).
export const MICROPAGES_PER_PAGE = 1_000_000;
export const MICROPAGES: Readonly<Partial<Record<QuranUnit, number>>> = {
  page: 1_000_000,
  juz: 20_000_000,
  hizb: 10_000_000,
  rub: 2_500_000,
  line: 66_666,
};

// ---------------------------------------------------------------------------
// Integer helpers (all math integer; values stay far below 2^53)
// ---------------------------------------------------------------------------

/** Truncating integer division toward zero for non-negative operands. */
export function idiv(n: number, d: number): number {
  return Math.trunc(n / d);
}

/** Round-half-up on the integer ratio n/d (n ≥ 0, d > 0). */
export function roundHalfUp(n: number, d: number): number {
  return idiv(n + idiv(d, 2), d);
}

/**
 * Parse a decimal-string (or number) QuranAmount value against a µp-per-unit
 * constant: µp = round_half_up(value × unit_µp). No binary floating point.
 */
export function decimalTimesUnit(value: string | number, unitMicropages: number): number {
  const s = typeof value === "number" ? String(value) : value;
  if (!/^\d+(\.\d+)?$/.test(s)) throw new EngineError(`invalid decimal amount value: ${JSON.stringify(value)}`);
  const [intPart, fracPart = ""] = s.split(".");
  if (fracPart.length > 6) throw new EngineError(`amount value has more than 6 fraction digits: ${s}`);
  const scale = 10 ** fracPart.length;
  const numerator = Number(intPart) * scale + Number(fracPart === "" ? 0 : fracPart);
  return roundHalfUp(numerator * unitMicropages, scale);
}

/** Parse a decimal-string amount value as a positive integer (ayah counts). */
export function decimalToInt(value: string | number): number {
  const scaled = decimalTimesUnit(value, 1_000_000);
  return roundHalfUp(scaled, 1_000_000);
}

/**
 * Exact decimal decomposition `value = units / den`, both integers (Swift's
 * `DecimalValue(units:denominator:)`, b1_engine's `Decimal`). Used wherever a
 * curriculum-authored decimal (workload rate, strength factor) must multiply
 * an integer without ever becoming a binary float (ENGINE_PARITY §1).
 */
export function decimalParts(value: string | number): { units: number; den: number } {
  const s = typeof value === "number" ? String(value) : value;
  if (!/^\d+(\.\d+)?$/.test(s)) throw new EngineError(`invalid decimal value: ${JSON.stringify(value)}`);
  const [intPart, fracPart = ""] = s.split(".");
  const den = 10 ** fracPart.length;
  return { units: Number(intPart) * den + (fracPart === "" ? 0 : Number(fracPart)), den };
}

// ---------------------------------------------------------------------------
// LocalDate — pure civil-date arithmetic. Represented as epoch-day integer
// (days since 1970-01-01). No JS Date anywhere.
// ---------------------------------------------------------------------------

export type EpochDay = number;

export type Weekday = "sun" | "mon" | "tue" | "wed" | "thu" | "fri" | "sat";
export const WEEKDAYS: readonly Weekday[] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

export function isLeapYear(y: number): boolean {
  return (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
}

const DAYS_IN_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

export function daysInMonth(y: number, m: number): number {
  return m === 2 && isLeapYear(y) ? 29 : DAYS_IN_MONTH[m - 1];
}

// Civil-date conversions use Howard Hinnant's public-domain formulas.
// https://howardhinnant.github.io/date_algorithms.html#Summary

/** Civil date → epoch day (integer-only). */
export function toEpochDay(y: number, m: number, d: number): EpochDay {
  if (m < 1 || m > 12 || d < 1 || d > daysInMonth(y, m)) {
    throw new EngineError(`invalid civil date ${y}-${m}-${d}`);
  }
  const yy = m <= 2 ? y - 1 : y;
  const era = Math.floor(yy / 400);
  const yoe = yy - era * 400; // 0..399
  const mp = (m + 9) % 12; // Mar=0..Feb=11
  const doy = idiv(153 * mp + 2, 5) + d - 1;
  const doe = yoe * 365 + idiv(yoe, 4) - idiv(yoe, 100) + doy;
  return era * 146097 + doe - 719468;
}

/** Epoch day → civil date. */
export function fromEpochDay(e: EpochDay): { year: number; month: number; day: number } {
  const z = e + 719468;
  const era = Math.floor(z / 146097);
  const doe = z - era * 146097; // 0..146096
  const yoe = idiv(doe - idiv(doe, 1460) + idiv(doe, 36524) - idiv(doe, 146096), 365);
  const yy = yoe + era * 400;
  const doy = doe - (365 * yoe + idiv(yoe, 4) - idiv(yoe, 100));
  const mp = idiv(5 * doy + 2, 153);
  const day = doy - idiv(153 * mp + 2, 5) + 1;
  const month = mp < 10 ? mp + 3 : mp - 9;
  return { year: month <= 2 ? yy + 1 : yy, month, day };
}

export function parseLocalDate(s: string): EpochDay {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
  if (!m) throw new EngineError(`invalid LocalDate string: ${JSON.stringify(s)}`);
  return toEpochDay(Number(m[1]), Number(m[2]), Number(m[3]));
}

export function formatLocalDate(e: EpochDay): string {
  const { year, month, day } = fromEpochDay(e);
  const pad = (n: number, w: number) => String(n).padStart(w, "0");
  return `${pad(year, 4)}-${pad(month, 2)}-${pad(day, 2)}`;
}

/** 0 = Sunday … 6 = Saturday. 1970-01-01 (epoch day 0) was a Thursday. */
export function dayOfWeekIndex(e: EpochDay): number {
  return ((e + 4) % 7 + 7) % 7;
}

export function dayOfWeek(e: EpochDay): Weekday {
  return WEEKDAYS[dayOfWeekIndex(e)];
}

export function addDays(e: EpochDay, n: number): EpochDay {
  return e + n;
}

/** The first day of the week containing `e`. */
export function weekStart(e: EpochDay, weekStartDay: Weekday = "sun"): EpochDay {
  const target = WEEKDAYS.indexOf(weekStartDay);
  return e - ((dayOfWeekIndex(e) - target + 7) % 7);
}

// ---------------------------------------------------------------------------
// Evidence
// ---------------------------------------------------------------------------

export type EvidenceSpec =
  | { kind: "self_check" }
  | { kind: "timer"; min_seconds: number }
  | { kind: "counter"; target: number }
  | { kind: "teacher_verification"; form_version_id?: string }
  | { kind: "form"; form_version_id: string }
  | { kind: "composite"; parts: EvidenceSpec[] };

// ---------------------------------------------------------------------------
// Plan events (DOMAIN_MODEL §3)
// ---------------------------------------------------------------------------

export type PlanEventType =
  | "plan.created"
  | "plan.activated"
  | "plan.paused"
  | "plan.resumed"
  | "plan.policy_changed"
  | "plan.curriculum_upgraded"
  | "plan.recovery_applied"
  | "plan.day_closed"
  | "task.started"
  | "task.completed"
  | "task.uncompleted"
  | "task.excused"
  | "assessment.logged"
  | "override.applied"
  | "starting_state.declared"
  | "starting_state.amended";

export interface TaskCompletedPayload {
  task_uid: string;
  evidence?: { kind: string; [k: string]: unknown };
  verified?: boolean;
}

export interface TaskRefPayload {
  task_uid: string;
  reason?: string;
  by?: string;
}

export interface PolicyChangePayload {
  /**
   * Raw JSON, not `Partial<PlanPolicy>`: PC-6(b) gives a present JSON `null`
   * the meaning "clear this field back to the curriculum default", which a
   * `Partial<>` cannot express.
   */
  patch: Record<string, unknown>;
  effective_from: string; // LocalDate
  change_reason?: string;
  reason?: string;
  supersedes?: string[];
}

/** D-054 `plan.curriculum_upgraded`: switch the plan onto another curriculum. */
export interface CurriculumUpgradedPayload {
  slug: string;
  version?: string;
  effective_from: string; // LocalDate
  /** Optional policy patch riding the SAME effective_from into the policy timeline. */
  policy_patch?: Record<string, unknown>;
}

export interface PausePayload {
  effective_from?: string; // LocalDate; falls back to occurred_at_local's date
}

export interface ResumePayload {
  anchor: string; // LocalDate generation re-anchors from
}

export interface RecoveryAppliedPayload {
  effective_from?: string; // LocalDate; falls back to occurred_at_local's date
}

export interface PlanEvent {
  event_id: string;
  type: PlanEventType | string; // unknown types preserved opaquely (I-4)
  payload?: Record<string, unknown>;
  schema_version?: number;
  actor_user_id?: string;
  actor_role?: string;
  device_id: string;
  client_seq: number;
  occurred_at_local: string; // ISO8601 with offset
  server_seq?: number; // absent for local-unacked events
  superseded_by?: string | null;
}

// ---------------------------------------------------------------------------
// Policy & starting state (PRD §7.2 / ENGINE_PARITY §4.1)
// ---------------------------------------------------------------------------

export type OrderSpec =
  | { kind: "mushaf_forward" }
  | { kind: "juz_amma_backward" }
  | { kind: "custom_list"; list: CanonicalRange[] };

export type RecoveryPolicy =
  | { kind: "strict_backlog" }
  | { kind: "redistribute"; days: number; max_extra: QuranAmount }
  | { kind: "pause_and_resume" };

export interface SessionSpec {
  id: string;
  start: string; // "HH:mm"
}

export interface RampSpec {
  start: QuranAmount;
  step: QuranAmount;
}

export interface PlanPolicy {
  new_amount: QuranAmount;
  target_range: "full_quran" | CanonicalRange[];
  memorization_order: OrderSpec;
  active_weekdays: Weekday[];
  sessions: SessionSpec[];
  separate_session_completion: boolean;
  listening_days: Weekday[];
  listening_count: number;
  takrar_count: number;
  takrar_spacing_minutes: number;
  murajaah_daily_ceiling: QuranAmount;
  /**
   * PC-6(b): a policy patch may clear this back to the curriculum's own DSL
   * ramp with an explicit JSON `null` (§11.7 then reads the DSL literal), so
   * the field is optional/nullable rather than always present.
   */
  murajaah_ramp?: RampSpec | null;
  recovery_policy: RecoveryPolicy;
  variable_overrides?: Record<string, unknown>;
  cycle_week_mode?: "pause_new" | "parallel";
  /**
   * task_type → evidence spec in the **DSL wire shape** (`{"timer":{...}}`,
   * `{"counter":{"target":…}}`, `"self_check"`, …) — the same shape a
   * curriculum's `evidence_defaults` uses, and the shape Swift/Kotlin parse.
   * NOT the internal `{kind:…}` shape; `resolveEvidence` normalizes it.
   */
  evidence_policy?: Record<string, unknown>;
}

export type DeclaredStrength = "strong" | "moderate" | "weak";

export interface DeclaredRange {
  range: CanonicalRange;
  strength: DeclaredStrength;
  declared_by: "self" | "teacher";
}

export interface LearnerStartingState {
  memorized_ranges: DeclaredRange[];
  placement_cursor: CanonicalPosition;
}

export interface OrgException {
  date: string; // LocalDate
  class: string; // holiday | org_assessment | custom | ...
}

export interface PlanCalendar {
  timezone: string; // IANA id — carried, never used for arithmetic (dates are civil)
  anchor_date: string; // LocalDate
  org_exceptions: OrgException[];
}

// ---------------------------------------------------------------------------
// Plan state (fold output summary; PRD §7.3)
// ---------------------------------------------------------------------------

export type PlanStatus = "awaiting_start_state" | "active" | "paused" | "completed" | "superseded";

export type TaskStatus =
  | "pending"
  | "in_progress"
  | "completed"
  | "verified"
  | "missed"
  | "excused"
  | "superseded";

export interface PlanState {
  cursor: CanonicalPosition | null; // null once the order is exhausted
  juz_completed_count: number;
  cycle_weeks: number;
  debt_new_ranges: number;
  status: PlanStatus;
}

// ---------------------------------------------------------------------------
// Task output (PRD §7.4 / ENGINE_PARITY §3)
// ---------------------------------------------------------------------------

export type TaskType =
  | "prep_dhikr"
  | "warmup"
  | "new_hifz"
  | "takrar"
  | "murajaah"
  | "listening"
  | "weekend_consolidation"
  | "tasmee"
  | "juz_review"
  | "juz_review_distributed"
  | "cycle_consolidation"
  | "tilawah";

export type TaskFlag =
  | "info_only"
  | "suppressed"
  | "first_active_day"
  | "consolidation_week"
  | "travel_skipped"
  | `source_rule:${string}`;

export interface TaskInstance {
  task_uid: string;
  plan_id: string;
  date: string; // YYYY-MM-DD
  day_class: string; // weekday | friday | saturday | exception class name
  session: string; // morning | evening | anytime
  ordering: number;
  type: TaskType;
  origin_rule_id: string;
  occurrence: number;
  content: CanonicalRange[];
  target_repetitions?: number;
  spacing_minutes?: number;
  listen_count?: number;
  window?: { opens_on: string; closes_on: string };
  estimated_minutes: number;
  evidence: EvidenceSpec | null; // null ⇒ info_only, serialized as empty field
  flags: TaskFlag[];
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

export class EngineError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "EngineError";
  }
}
