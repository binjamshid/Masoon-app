// Compiled curriculum DSL loader (PRD §8, D-028).
//
// Loads compiled curriculum JSON documents into a typed
// CompiledCurriculum and performs reference validation:
//   - unique rule/trigger ids; selectors and variables referenced exist
//   - `$pace` is a reserved binding supplied by the engine from
//     PlanPolicy.new_amount (falling back to units.default_pace) — D-028(1);
//     no curriculum may declare a variable named `pace`
//   - `when.day_class` names resolve to calendar day_classes
//   - `suppressed_by` entries resolve to trigger ids

import {
  DeclaredStrength,
  EngineError,
  EvidenceSpec,
  PlanPolicy,
  QuranAmount,
  Weekday,
} from "./types.ts";

// ---------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------

export type VarRef = string; // "$name"
export type IntOrRef = number | VarRef;
export type AmountOrRef = QuranAmount | VarRef;

export interface CompiledVariable {
  type: "int" | "bool" | "amount" | "weekday_set" | "enum";
  default: unknown;
  min?: number;
  max?: number;
  values?: string[];
  non_negotiable?: boolean;
}

export interface RampSpecDsl {
  start: AmountOrRef;
  step: AmountOrRef;
  ceiling: AmountOrRef;
}

// E-1 (D-038): which prior ḥifẓ a murājaʿah layer rotates — all of it, or the
// most-recently-memorized window (by memorization order).
export type PoolSpecDsl =
  | "prior_hifz"
  | { recent_pages: IntOrRef }
  | { recent_juz: IntOrRef }
  // E-1b (D-043): the exact complement of the recent window — material that has
  // rolled OFF it (ITQAAN's murājaʿah list of pages beyond the active window).
  | { all_except_recent_pages: IntOrRef }
  | { all_except_recent_juz: IntOrRef };

/**
 * How much of the pool to take each day.
 *  - `ramp`: grows with WEEKS elapsed, capped at a ceiling (Maknoon-style).
 *  - `cycle_days` (E-3a, D-045): cover the whole pool every N days. The amount is
 *    derived from the POOL SIZE, so each item's review interval stays FIXED as the
 *    corpus grows — the daily load rises instead. This is the South-Asian **Dhor**
 *    mechanic ("each juzʾ reviewed at least once every N days"), which a ramp
 *    cannot express.
 */
export type PerDaySpecDsl =
  | { ramp: RampSpecDsl }
  | { cycle_days: IntOrRef };

export type SelectorSpec =
  | { next_content: { amount: AmountOrRef } }
  | { next_new: { amount: AmountOrRef } }
  | { ledger_window: { days: IntOrRef; sunday_days?: IntOrRef } }
  | { ledger_offset: { days_ago: IntOrRef } }
  | { week_to_date: Record<never, never> }
  | { pool_rotation: { pool: PoolSpecDsl; per_day: PerDaySpecDsl; weak_boost?: number } }
  | { completed_juz: { which: "last" } }
  | { prior_hifz_split: { parts: number } }
  | { block: { juz_count: IntOrRef; which: "last" } }
  | { tomorrow_new: Record<never, never> }
  | { fixed: { range: { surah: number; ayah_start: number; ayah_end: number }[] } }
  | { block_slice: { of: string; parts: number } }
  | { intersect_prior_hifz: { of: string | SelectorSpec } };

export interface RuleWhen {
  day_class: string | string[];
  session: string;
  not?: string[]; // e.g. ["first_active_day"]
  enabled?: VarRef;
  day_in?: VarRef;
}

export interface RuleEmit {
  type: string;
  select?: string | SelectorSpec; // name into selectors, or inline (block_slice)
  repetitions?: IntOrRef;
  spacing_minutes?: IntOrRef;
  listen_count?: IntOrRef;
  window?: { opens: Weekday; closes: Weekday };
  info_only?: boolean;
  ordering: number;
  /**
   * CB-2: an authored estimate that WINS OVER the workload model — before the
   * `prep_dhikr` zero-out and before any rate lookup. No built-in curriculum
   * sets it; corpus-agnostic curricula (poems, adhkār) whose content carries no
   * page weight need it, since the µp model would estimate zero.
   */
  est_minutes?: number;
  /** Authored bilingual task label. Presentation only — never stream-visible. */
  label?: Record<string, string>;
}

export interface RuleSpec {
  id: string;
  when: RuleWhen;
  emit: RuleEmit;
  suppressed_by?: string[];
}

export interface TriggerScheduleEffect {
  schedule: {
    type: string;
    select: string;
    starting?: "next_active_day";
    distribute_over_days?: number;
    into_session?: string;
    /** CB-2: same authored-override semantics as `RuleEmit.est_minutes`. */
    est_minutes?: number;
    label?: Record<string, string>;
  };
}

export interface TriggerInsertWeekEffect {
  insert_week: {
    name: string;
    mode_var: string;
    day_rules: RuleSpec[];
  };
}

export interface TriggerCompletePlanEffect {
  complete_plan: Record<never, never>;
}

export type TriggerEffect = TriggerScheduleEffect | TriggerInsertWeekEffect | TriggerCompletePlanEffect;

export interface TriggerSpec {
  id: string;
  /**
   * `boundary` fires on a juzʾ/target boundary. E-5 (D-047) `task_failed` fires
   * when the task emitted by `rule` on a CLOSED day was not verified — the Wifaq
   * weekly milestone the student failed (or did not sit).
   */
  on: {
    boundary?: "juz" | "hizb" | "surah" | "target";
    every?: IntOrRef;
    task_failed?: { rule: string };
  };
  effects: TriggerEffect[];
}

export interface CompiledCurriculum {
  meta: { slug: string; title: Record<string, string>; non_negotiables?: string[] };
  units: { allowed: string[]; default_pace: QuranAmount };
  calendar: {
    week_start: Weekday;
    day_classes: Record<string, Weekday[]>;
    exception_classes: string[];
  };
  sessions: { id: string; title?: Record<string, string>; default_time?: string; anchor?: string }[];
  variables: Record<string, CompiledVariable>;
  selectors: Record<string, SelectorSpec>;
  rules: RuleSpec[];
  triggers: TriggerSpec[];
  task_deduplication?: { mode: "exact_execution" };
  recovery?: { allowed_policies: string[]; default: string; escalation_days: number };
  // E-4b (D-046): `require_verified` ⇒ advancing needs a VERIFIED pass. A
  // teacher-rejected (mardūd) sabaq is completed-but-unverified, so it holds the
  // cursor and re-queues; only maqbūl advances.
  //
  // NB (D-048): there is deliberately NO `gate: mastery` knob. It once meant
  // "an unmastered portion owes no debt", but the engine counts every closed
  // non-pass owes debt — which left the gate with no remaining semantic (the
  // cursor already holds on any non-pass), so it was removed rather than kept as
  // a no-op that reads like it does something.
  advancement?: { require_verified?: boolean };
  evidence_defaults?: Record<string, unknown>;
  forecast: {
    workload_rates: Record<string, number>;
    strength_factors: Record<DeclaredStrength, number>;
  };
}

// ---------------------------------------------------------------------------
// Loading & reference validation
// ---------------------------------------------------------------------------

const RESERVED_PACE = "pace";

export function loadCurriculum(json: unknown): CompiledCurriculum {
  if (typeof json !== "object" || json === null) throw new EngineError("curriculum: not an object");
  const cur = json as CompiledCurriculum;
  for (const key of ["meta", "units", "calendar", "sessions", "variables", "selectors", "rules", "triggers", "forecast"]) {
    if (!(key in cur)) throw new EngineError(`curriculum: missing required key ${key}`);
  }

  if (RESERVED_PACE in cur.variables) {
    throw new EngineError("curriculum: `pace` is a reserved variable name (D-028)");
  }

  const dayClassNames = new Set(Object.keys(cur.calendar.day_classes));
  const sessionIds = new Set(cur.sessions.map((s) => s.id));
  const selectorNames = new Set(Object.keys(cur.selectors));
  const triggerIds = new Set<string>();
  for (const t of cur.triggers) {
    if (triggerIds.has(t.id)) throw new EngineError(`curriculum: duplicate trigger id ${t.id}`);
    triggerIds.add(t.id);
  }

  const checkVarRef = (ref: unknown, ctx: string) => {
    if (typeof ref !== "string" || !ref.startsWith("$")) return;
    const name = ref.slice(1);
    if (name === RESERVED_PACE) return; // engine-bound (D-028)
    if (!(name in cur.variables)) throw new EngineError(`curriculum: ${ctx} references unknown variable ${ref}`);
  };

  const checkRule = (r: RuleSpec, seenIds: Set<string>, ctx: string) => {
    if (seenIds.has(r.id)) throw new EngineError(`curriculum: duplicate rule id ${r.id}`);
    seenIds.add(r.id);
    const classes = Array.isArray(r.when.day_class) ? r.when.day_class : [r.when.day_class];
    for (const c of classes) {
      if (!dayClassNames.has(c)) throw new EngineError(`curriculum: ${ctx} ${r.id} uses unknown day_class ${c}`);
    }
    if (!sessionIds.has(r.when.session)) {
      throw new EngineError(`curriculum: ${ctx} ${r.id} uses unknown session ${r.when.session}`);
    }
    checkVarRef(r.when.enabled, `rule ${r.id}.when.enabled`);
    checkVarRef(r.when.day_in, `rule ${r.id}.when.day_in`);
    const sel = r.emit.select;
    if (typeof sel === "string" && !selectorNames.has(sel)) {
      throw new EngineError(`curriculum: ${ctx} ${r.id} references unknown selector ${sel}`);
    }
    if (typeof sel === "object" && sel !== null && "block_slice" in sel) {
      const of = (sel as { block_slice: { of: string } }).block_slice.of;
      if (!selectorNames.has(of)) {
        throw new EngineError(`curriculum: ${ctx} ${r.id} block_slice references unknown selector ${of}`);
      }
    }
    checkVarRef(r.emit.repetitions, `rule ${r.id}.emit.repetitions`);
    checkVarRef(r.emit.spacing_minutes, `rule ${r.id}.emit.spacing_minutes`);
    checkVarRef(r.emit.listen_count, `rule ${r.id}.emit.listen_count`);
    for (const s of r.suppressed_by ?? []) {
      if (!triggerIds.has(s)) throw new EngineError(`curriculum: ${ctx} ${r.id} suppressed_by unknown trigger ${s}`);
    }
  };

  const ruleIds = new Set<string>();
  for (const r of cur.rules) checkRule(r, ruleIds, "rule");

  if (cur.advancement !== undefined) {
    const rv = cur.advancement.require_verified;
    if (rv !== undefined && typeof rv !== "boolean") {
      throw new EngineError(`curriculum: advancement.require_verified must be a boolean (got ${JSON.stringify(rv)})`);
    }
  }

  for (const t of cur.triggers) {
    checkVarRef(t.on.every, `trigger ${t.id}.on.every`);
    if (t.on.task_failed !== undefined) {
      if (!ruleIds.has(t.on.task_failed.rule)) {
        throw new EngineError(
          `curriculum: trigger ${t.id}.on.task_failed references unknown rule ${t.on.task_failed.rule}`,
        );
      }
    }
    for (const eff of t.effects) {
      if ("schedule" in eff) {
        if (!selectorNames.has(eff.schedule.select)) {
          throw new EngineError(`curriculum: trigger ${t.id} schedule references unknown selector ${eff.schedule.select}`);
        }
        if (eff.schedule.into_session && !sessionIds.has(eff.schedule.into_session)) {
          throw new EngineError(`curriculum: trigger ${t.id} schedule into unknown session ${eff.schedule.into_session}`);
        }
      } else if ("insert_week" in eff) {
        if (!(eff.insert_week.mode_var in cur.variables)) {
          throw new EngineError(`curriculum: trigger ${t.id} insert_week unknown mode_var ${eff.insert_week.mode_var}`);
        }
        const inserted = new Set<string>();
        for (const dr of eff.insert_week.day_rules) checkRule(dr, inserted, `trigger ${t.id} day_rule`);
      }
    }
  }

  // Selector-level variable references.
  for (const [name, spec] of Object.entries(cur.selectors)) {
    walkVarRefs(spec, (ref) => checkVarRef(ref, `selector ${name}`));
  }

  return cur;
}

function walkVarRefs(node: unknown, fn: (ref: string) => void): void {
  if (typeof node === "string") {
    if (node.startsWith("$")) fn(node);
    return;
  }
  if (Array.isArray(node)) {
    for (const x of node) walkVarRefs(x, fn);
    return;
  }
  if (typeof node === "object" && node !== null) {
    for (const v of Object.values(node)) walkVarRefs(v, fn);
  }
}

// ---------------------------------------------------------------------------
// Variable environment (curriculum defaults ⊕ policy field mapping ⊕ overrides)
// ---------------------------------------------------------------------------

export interface VariableEnv {
  get(nameOrRef: string): unknown;
  int(nameOrRef: IntOrRef): number;
  bool(nameOrRef: string | boolean): boolean;
  amount(nameOrRef: AmountOrRef): QuranAmount;
  weekdaySet(nameOrRef: string | Weekday[]): Weekday[];
  str(nameOrRef: string): string;
}

/**
 * Policy-field → DSL-variable binding (ENGINE_SEMANTICS §11.21, closed map).
 * Resolution precedence: `variable_overrides` > named policy field > DSL
 * default. `$pace` binds to policy.new_amount (D-028); `murajaah_ramp.start`
 * is consumed directly by the generator (§11.7), not via a variable.
 */
export function resolveVariables(cur: CompiledCurriculum, policy: PlanPolicy): VariableEnv {
  const values = new Map<string, unknown>();
  for (const [name, v] of Object.entries(cur.variables)) values.set(name, v.default);
  const mapIf = (name: string, v: unknown) => {
    if (v !== undefined && values.has(name)) values.set(name, v);
  };
  mapIf("takrar_count", policy.takrar_count);
  mapIf("takrar_spacing_min", policy.takrar_spacing_minutes);
  mapIf("listening_days", policy.listening_days);
  mapIf("listening_count", policy.listening_count);
  mapIf("murajaah_ceiling", policy.murajaah_daily_ceiling);
  mapIf("murajaah_ramp_step", policy.murajaah_ramp?.step);
  mapIf("cycle_week_mode", policy.cycle_week_mode);
  for (const [name, v] of Object.entries(policy.variable_overrides ?? {})) {
    if (values.has(name)) values.set(name, v); // §11.21: overrides win over named fields
  }
  values.set(RESERVED_PACE, policy.new_amount ?? cur.units.default_pace);

  const resolve = (nameOrRef: unknown): unknown => {
    if (typeof nameOrRef === "string" && nameOrRef.startsWith("$")) {
      const name = nameOrRef.slice(1);
      if (!values.has(name)) throw new EngineError(`unresolved variable reference ${nameOrRef}`);
      return values.get(name);
    }
    return nameOrRef;
  };

  return {
    get: (n) => resolve(n),
    int: (n) => {
      const v = resolve(n);
      if (typeof v !== "number" || !Number.isInteger(v)) throw new EngineError(`variable ${String(n)} is not an int`);
      return v;
    },
    bool: (n) => {
      const v = resolve(n);
      if (typeof v !== "boolean") throw new EngineError(`variable ${String(n)} is not a bool`);
      return v;
    },
    amount: (n) => {
      const v = resolve(n) as QuranAmount;
      if (typeof v !== "object" || v === null || !("unit" in v)) {
        throw new EngineError(`variable ${String(n)} is not an amount`);
      }
      return v;
    },
    weekdaySet: (n) => {
      const v = resolve(n);
      if (!Array.isArray(v)) throw new EngineError(`variable ${String(n)} is not a weekday set`);
      return v as Weekday[];
    },
    str: (n) => {
      const v = resolve(n);
      if (typeof v !== "string") throw new EngineError(`variable ${String(n)} is not a string`);
      return v;
    },
  };
}

// ---------------------------------------------------------------------------
// Evidence resolution (policy.evidence_policy ▸ curriculum evidence_defaults ▸ self_check)
// ---------------------------------------------------------------------------

/**
 * Resolution order (Swift `EngineRun.resolveEvidence`, b1_engine `evidence()`):
 * `policy.evidence_policy[type]` ▸ `curriculum.evidence_defaults[type]` ▸
 * `evidence_defaults["default"]` ▸ `self_check`.
 *
 * BUGFIX (Batch 2): the policy branch used to `return fromPolicy` RAW, assuming
 * the internal `{kind:…}` shape. Both the fixture wire shape and Swift/Kotlin
 * use the DSL shape (`{"timer":{"min_seconds":300}}`), so any plan with a
 * non-empty `evidence_policy` threw `unknown evidence kind` at serialization.
 * No fixture set one until PP-01. The policy value now goes through exactly the
 * same normalizer as a curriculum default.
 *
 * An unparseable spec falls through to the next source rather than throwing —
 * `EvidenceSpec.parse` returns `nil` in Swift and the `else if` chain continues.
 */
export function resolveEvidence(
  cur: CompiledCurriculum,
  policy: PlanPolicy,
  env: VariableEnv,
  taskType: string,
): EvidenceSpec {
  const defaults = cur.evidence_defaults ?? {};
  return normalizeEvidence(policy.evidence_policy?.[taskType], env) ??
    normalizeEvidence(defaults[taskType], env) ??
    normalizeEvidence(defaults["default"], env) ??
    { kind: "self_check" };
}

/** `$var`-aware int resolution that yields null instead of throwing (Swift `resolveInt`). */
function evidenceInt(v: unknown, env: VariableEnv): number | null {
  if (typeof v === "number" && Number.isInteger(v)) return v;
  if (typeof v === "string" && v.startsWith("$")) {
    try {
      return env.int(v as IntOrRef);
    } catch {
      return null;
    }
  }
  return null;
}

/**
 * DSL-shape evidence spec → internal `EvidenceSpec`. `null` when the value is
 * absent or not a recognizable spec (never throws — see `resolveEvidence`).
 */
export function normalizeEvidence(spec: unknown, env: VariableEnv): EvidenceSpec | null {
  if (spec === undefined || spec === null) return null;
  if (typeof spec === "string") return spec === "self_check" ? { kind: "self_check" } : null;
  if (typeof spec !== "object" || Array.isArray(spec)) return null;
  const o = spec as Record<string, unknown>;
  if ("self_check" in o) return { kind: "self_check" };
  if ("counter" in o) {
    const t = evidenceInt((o.counter as { target?: unknown } ?? {}).target, env);
    return t === null ? null : { kind: "counter", target: t };
  }
  if ("timer" in o) {
    const s = evidenceInt((o.timer as { min_seconds?: unknown } ?? {}).min_seconds, env);
    return s === null ? null : { kind: "timer", min_seconds: s };
  }
  if ("teacher_verification" in o) {
    const fv = (o.teacher_verification as { form_version_id?: string } ?? {}).form_version_id;
    return fv ? { kind: "teacher_verification", form_version_id: fv } : { kind: "teacher_verification" };
  }
  if ("form" in o) {
    const id = (o.form as { form_version_id?: string } ?? {}).form_version_id;
    return typeof id === "string" ? { kind: "form", form_version_id: id } : null;
  }
  if ("composite" in o) {
    const items = o.composite;
    if (!Array.isArray(items) || items.length === 0) return null;
    const parts: EvidenceSpec[] = [];
    for (const p of items) {
      const parsed = normalizeEvidence(p, env);
      if (parsed === null) return null;
      parts.push(parsed);
    }
    return { kind: "composite", parts };
  }
  return null;
}
