// Day generator — the deterministic heart of the engine.
//
// Implements daily rules from the compiled DSL, murājaʿah rotation and ramp,
// and boundary triggers
// R-J1/R-J2/R-C1 (§5/§6), listening look-ahead (§7), recovery (§8), fold &
// generation modes (§9), ordering & task_uid (§10).
//
// generate() is pure: no clocks, RNG, locale, or I/O. `today` and all
// reference data are inputs; dates ≤ today fold actual events, dates > today
// run in projection mode (every emitted content task is assumed completed).

import {
  CompiledCurriculum,
  resolveEvidence,
  resolveVariables,
  RuleSpec,
  SelectorSpec,
  TriggerInsertWeekEffect,
  TriggerScheduleEffect,
  TriggerSpec,
  VariableEnv,
} from "./dsl.ts";
import { curriculumChangeAt, foldEvents, FoldResult, isPausedOn, policyAt } from "./fold.ts";
import { CurriculumSet, resolveCurriculum } from "./curriculum_set.ts";
import { ContentIndex } from "./content_index.ts";
import {
  amountToMicropages,
  buildMemorizationOrder,
  globalsToContent,
  MemorizationOrder,
  orderContent,
  ResolvedAmount,
  rotationSlice,
  selectNextNew,
  splitNearEqual,
} from "./selectors.ts";
import {
  addDays,
  dayOfWeek,
  decimalParts,
  EngineError,
  EpochDay,
  formatLocalDate,
  idiv,
  parseLocalDate,
  PlanCalendar,
  PlanEvent,
  PlanPolicy,
  PlanState,
  PlanStatus,
  LearnerStartingState,
  roundHalfUp,
  TaskFlag,
  TaskInstance,
  TaskType,
  Weekday,
  weekStart,
  WEEKDAYS,
} from "./types.ts";
import { uuid5 } from "./uuid5.ts";
import { deduplicateExactExecution } from "./task_dedup.ts";

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

export interface PlanGenerationContext {
  plan_id: string;
  /** The curriculum the plan runs under before any `plan.curriculum_upgraded`. */
  curriculum: CompiledCurriculum;
  /**
   * D-054 / ENGINE_PARITY §4.2: extra compiled curricula this plan may switch
   * INTO, keyed `"{slug}@{version}"`. Omitting it (every single-curriculum
   * plan) is identical to `{}` — `curriculum` then applies on every date.
   */
  curricula?: Record<string, CompiledCurriculum>;
  quran: ContentIndex;
  policy: PlanPolicy;
  starting_state: LearnerStartingState;
  calendar: PlanCalendar;
  event_log: PlanEvent[];
  today: string; // LocalDate
}

export interface GenerationWindow {
  from: string;
  to: string;
}

export interface GenerationResult {
  tasks: TaskInstance[];
  state: PlanState;
}

const SESSION_RANK: Record<string, number> = { morning: 0, evening: 1, anytime: 2 };
const LOOKAHEAD_DAYS = 14; // listening look-ahead bound (ENGINE_SEMANTICS §7)

export function generate(ctx: PlanGenerationContext, window: GenerationWindow): GenerationResult {
  return new Generator(ctx).run(parseLocalDate(window.from), parseLocalDate(window.to));
}

// ---------------------------------------------------------------------------
// Internal task shape (pre-serialization)
// ---------------------------------------------------------------------------

interface InternalTask {
  session: string;
  ordering: number;
  type: TaskType;
  origin: string;
  contentGlobals: number[]; // in selection/walk order
  reps?: number;
  spacing?: number;
  listenCount?: number;
  window?: { opens_on: EpochDay; closes_on: EpochDay };
  infoOnly: boolean;
  /** CB-2: authored `est_minutes`; wins over the whole workload model. */
  estOverride?: number;
  // state-advance hooks
  newHifzLastPos?: number; // order position of last selected ayah (cursor advance)
  rotationNextCursor?: number; // murajaah cursor advance target
}

interface ScheduledTask {
  origin: string;
  type: TaskType;
  session: string;
  ordering: number;
  contentGlobals: number[];
  estOverride?: number;
}

interface InsertedWeek {
  weekStartDay: EpochDay;
  triggerId: string;
  mode: string;
  dayRules: RuleSpec[];
  blockJuz: number[]; // last-N-juz block, memorization-order sequence
}

// ---------------------------------------------------------------------------
// Generator
// ---------------------------------------------------------------------------

class Generator {
  private readonly ctx: PlanGenerationContext;
  private readonly index: ContentIndex;
  /** The BASE curriculum. Date-dependent reads must go through `curOn(day)`. */
  private readonly cur: CompiledCurriculum;
  private readonly curSet: CurriculumSet;
  private readonly fold: FoldResult;
  private readonly order: MemorizationOrder;
  private readonly anchor: EpochDay;
  private readonly firstActiveDay: EpochDay;
  private readonly today: EpochDay;
  private readonly exceptionByDate = new Map<EpochDay, string>();
  private readonly weekdayToClassBy = new Map<CompiledCurriculum, Map<Weekday, string>>();
  /** PC-5: `effective_from` dates at which the hard-boundary sweep must run. */
  private readonly boundaryDates = new Set<EpochDay>();
  private readonly strengthScaled: Int32Array; // per-ayah workload factor ×1000
  private readonly weak: Uint8Array; // per-ayah weak flag (slicing half-weight)
  private readonly declared: Uint8Array;
  private readonly targetCache = new Map<unknown, Uint8Array>();

  // Mutable simulation state
  private readonly completed: Uint8Array;
  private readonly completedInJuz: Int32Array;
  private readonly juzSize: Int32Array;
  private readonly juzFired: Uint8Array;
  private juzDoneCount = 0;
  private readonly juzCompletionOrder: number[] = [];
  private cursorPos: number;
  // E-4b (D-046): advancement requires a VERIFIED pass — a teacher-rejected
  // (mardūd) sabaq holds the cursor (and, per D-048, owes debt like any fail).
  // Read per-date in `advanceState`, since a curriculum switch can change it.
  // E-1 (D-038): each murājaʿah layer (rule) keeps its own rotation cursor,
  // keyed by origin_rule_id, so multiple layers over different pools coexist.
  private rotationCursors = new Map<string, number>();
  private readonly ledger = new Map<EpochDay, number[]>();
  private readonly scheduledByDate = new Map<EpochDay, ScheduledTask[]>();
  private readonly distSliceByDate = new Map<EpochDay, ScheduledTask>();
  private readonly insertedWeeks = new Map<EpochDay, InsertedWeek>();
  private cycleFiredCount = 0;
  private planCompleted = false;
  private targetCoveredCount = 0;
  private targetTotal = 0;
  private currentTarget: Uint8Array;
  /**
   * D-049: lost advancement slots. Each entry is ONE closed day that owed new
   * ḥifẓ and did not pass, carrying the µp it owed. `owedMp` is fixed when the
   * slot is lost and is discharged ONLY by catch-up work (redistribute extras) —
   * NOT by completing the content later, because completing it later is just
   * doing that day's work a day late: you are still a slot behind.
   */
  private readonly debt: { date: EpochDay; globals: number[]; owedMp: number }[] = [];
  private redistributeEpisode: {
    appliedOn: EpochDay;
    daysLeft: number;
    remainingMp: number | null; // lazily fixed on the first boost day (§11.23)
    extraByDay: Map<EpochDay, number>;
  } | null = null;
  private pendingRecoveryApps: EpochDay[];

  constructor(ctx: PlanGenerationContext) {
    this.ctx = ctx;
    this.index = ctx.quran;
    this.cur = ctx.curriculum;
    this.curSet = { base: ctx.curriculum, byKey: ctx.curricula ?? {} };
    this.fold = foldEvents(ctx.event_log);
    this.order = buildMemorizationOrder(ctx.policy.memorization_order, this.index);
    this.anchor = parseLocalDate(ctx.calendar.anchor_date);
    this.firstActiveDay = this.anchor; // see SEMANTIC GAPS: first active day = anchor date
    this.today = parseLocalDate(ctx.today);
    this.pendingRecoveryApps = [...this.fold.recoveryApplications];

    for (const ex of ctx.calendar.org_exceptions ?? []) {
      this.exceptionByDate.set(parseLocalDate(ex.date), ex.class);
    }
    for (const change of this.fold.curriculumTimeline) this.boundaryDates.add(change.effectiveFrom);

    const total = this.index.totalAyahs;
    this.completed = new Uint8Array(total);
    this.declared = new Uint8Array(total);
    this.strengthScaled = new Int32Array(total).fill(1000);
    this.weak = new Uint8Array(total);
    const factors = this.cur.forecast.strength_factors;
    for (const dr of ctx.starting_state.memorized_ranges ?? []) {
      const [a, b] = this.index.rangeToGlobal(dr.range);
      // Exact ×1000 scaling (ENGINE_PARITY §1: no binary float may reach an
      // emitted value). `1.2 * 1000` is 1200.0000000000002 in IEEE-754.
      const f = decimalParts(factors[dr.strength] ?? 1);
      const scaled = roundHalfUp(f.units * 1000, f.den);
      for (let g = a; g <= b; g++) {
        this.declared[g] = 1;
        this.strengthScaled[g] = scaled;
        this.weak[g] = dr.strength === "weak" ? 1 : 0;
      }
    }

    this.juzSize = new Int32Array(this.index.juzCount + 1);
    this.completedInJuz = new Int32Array(this.index.juzCount + 1);
    this.juzFired = new Uint8Array(this.index.juzCount + 1);
    for (let j = 1; j <= this.index.juzCount; j++) {
      const [a, b] = this.index.juzGlobalRange(j);
      this.juzSize[j] = b - a;
    }

    const pc = ctx.starting_state.placement_cursor;
    const g = this.index.toGlobal(pc.surah, pc.ayah);
    const pos = this.order.posOf[g];
    if (pos < 0) throw new EngineError(`placement_cursor ${pc.surah}:${pc.ayah} is not in the memorization order`);
    this.cursorPos = pos;

    this.currentTarget = this.targetSetFor(ctx.policy);
    this.recountTarget();
  }

  // ------------------------------------------------------------------
  // Target range
  // ------------------------------------------------------------------

  private targetSetFor(policy: PlanPolicy): Uint8Array {
    const key = policy.target_range;
    const cached = this.targetCache.get(key);
    if (cached) return cached;
    const set = new Uint8Array(this.index.totalAyahs);
    if (key === "full_quran") {
      set.fill(1);
    } else {
      for (const r of key) {
        const [a, b] = this.index.rangeToGlobal(r);
        for (let g = a; g <= b; g++) set[g] = 1;
      }
    }
    this.targetCache.set(key, set);
    return set;
  }

  private recountTarget(): void {
    let total = 0, covered = 0;
    const t = this.currentTarget;
    for (let g = 0; g < t.length; g++) {
      if (t[g]) {
        total++;
        if (this.declared[g] || this.completed[g]) covered++;
      }
    }
    this.targetTotal = total;
    this.targetCoveredCount = covered;
  }

  // ------------------------------------------------------------------
  // Calendar helpers
  // ------------------------------------------------------------------

  /**
   * PC-4 (D-054): the curriculum active on `day`. An empty curriculum
   * timeline uses `this.cur` on every date.
   */
  private curOn(day: EpochDay): CompiledCurriculum {
    if (this.fold.curriculumTimeline.length === 0) return this.cur;
    return resolveCurriculum(this.curSet, curriculumChangeAt(this.fold, day));
  }

  private weekdayToClass(cur: CompiledCurriculum): Map<Weekday, string> {
    let m = this.weekdayToClassBy.get(cur);
    if (m === undefined) {
      m = new Map<Weekday, string>();
      for (const [name, days] of Object.entries(cur.calendar.day_classes)) {
        for (const d of days) m.set(d, name);
      }
      this.weekdayToClassBy.set(cur, m);
    }
    return m;
  }

  /**
   * PC-5 (D-054 hard-boundary sweep): curricula have near-disjoint session and
   * day-class vocabularies, so machinery scheduled under the OLD curriculum
   * would silently emit nothing (or misclassify) under the new one. On a
   * switch's `effective_from`, drop every consolidation week whose span has not
   * fully elapsed, every distribution slice and scheduled juz review on/after
   * that date, and reset EVERY murājaʿah rotation cursor (a new curriculum's
   * rule ids generally name different pools, so a carried-over position is
   * meaningless even on an id collision). Cursor, ledger and debt are untouched.
   *
   * Runs before the day's consolidation week is resolved, so the sweep cannot
   * suppress the very boundary day it exists to unblock. Inert whenever the
   * curriculum timeline is empty.
   */
  private sweepAtBoundary(day: EpochDay): void {
    if (!this.boundaryDates.has(day)) return;
    for (const [start, _week] of [...this.insertedWeeks]) {
      if (start + 6 >= day) this.insertedWeeks.delete(start);
    }
    for (const d of [...this.distSliceByDate.keys()]) {
      if (d >= day) this.distSliceByDate.delete(d);
    }
    for (const d of [...this.scheduledByDate.keys()]) {
      if (d >= day) this.scheduledByDate.delete(d);
    }
    this.rotationCursors.clear();
  }

  private classOf(day: EpochDay): string {
    const ex = this.exceptionByDate.get(day);
    if (ex !== undefined) return ex;
    const cls = this.weekdayToClass(this.curOn(day)).get(dayOfWeek(day));
    if (cls === undefined) throw new EngineError(`weekday ${dayOfWeek(day)} has no day_class in curriculum calendar`);
    return cls;
  }

  private isException(day: EpochDay): boolean {
    return this.exceptionByDate.has(day);
  }

  /** A day carries sessions: not an org-exception day and not paused. */
  private dayAllows(day: EpochDay): boolean {
    return !this.isException(day) && !isPausedOn(this.fold, day);
  }

  private myWeekStart(day: EpochDay): EpochDay {
    return weekStart(day, this.curOn(day).calendar.week_start);
  }

  /** completed_weeks(D) = count of week-start days after the first active day and ≤ D. */
  private completedWeeks(day: EpochDay): number {
    const target = WEEKDAYS.indexOf(this.curOn(day).calendar.week_start);
    const dow = WEEKDAYS.indexOf(dayOfWeek(this.firstActiveDay));
    let first = this.firstActiveDay + ((target - dow + 7) % 7);
    if (first <= this.firstActiveDay) first += 7; // strictly after
    if (first > day) return 0;
    return idiv(day - first, 7) + 1;
  }

  // ------------------------------------------------------------------
  // Ledger windows
  // ------------------------------------------------------------------

  private unionLedger(from: EpochDay, to: EpochDay): Set<number> {
    const out = new Set<number>();
    for (let d = from; d <= to; d++) {
      const globals = this.ledger.get(d);
      if (globals) for (const g of globals) out.add(g);
    }
    return out;
  }

  private warmupWindowSet(day: EpochDay, env: VariableEnv, spec?: { days: unknown; sunday_days?: unknown }): Set<number> {
    const days = spec ? env.int(spec.days as number | string) : 7;
    const sundayDays = spec?.sunday_days !== undefined ? env.int(spec.sunday_days as number | string) : days;
    // §3/§11: the longer window applies on the curriculum's WEEK-START day (for
    // Maknoon that is Sunday, hence the field name), not on Sunday literally.
    // Swift/b1_engine both compare against `calendar.week_start`; only
    // masoon_method declares `sunday_days` and its week_start IS "sun", so this
    // is inert for every current fixture.
    const k = dayOfWeek(day) === this.curOn(day).calendar.week_start ? sundayDays : days;
    return this.unionLedger(addDays(day, -k), addDays(day, -1));
  }

  // ------------------------------------------------------------------
  // Selection primitives
  // ------------------------------------------------------------------

  private isSelectableNew = (g: number): boolean =>
    this.currentTarget[g] === 1 && this.completed[g] === 0 && this.declared[g] === 0;

  /** µp weight of the next `count` selectable ayahs from the cursor. */
  private nextSelectableWeight(count: number): number {
    let sum = 0, taken = 0;
    for (let p = this.cursorPos; p < this.order.seq.length && taken < count; p++) {
      const g = this.order.seq[p];
      if (!this.isSelectableNew(g)) continue;
      sum += this.index.weightOf(g);
      taken++;
    }
    return sum;
  }

  /** Resolve the day's new-hifz selection (redistribute extra included). */
  private selectNew(day: EpochDay, env: VariableEnv, amountRef: unknown, policy: PlanPolicy): number[] {
    let amount: ResolvedAmount = this.index.resolveAmount(env.amount(amountRef as string));
    const extra = this.redistributeExtra(day, policy);
    if (extra > 0) {
      const baseMp = amount.kind === "micropages" ? amount.micropages : this.nextSelectableWeight(amount.count);
      amount = { kind: "micropages", micropages: baseMp + extra };
    }
    const positions = selectNextNew(this.order, this.index, this.cursorPos, amount, this.isSelectableNew);
    return positions;
  }

  /** Sequential corpus reading; declared/completed hifz is deliberately not skipped. */
  private selectContent(env: VariableEnv, amountRef: unknown): number[] {
    const amount = this.index.resolveAmount(env.amount(amountRef as string));
    return selectNextNew(
      this.order,
      this.index,
      this.cursorPos,
      amount,
      (g) => this.currentTarget[g] === 1,
    );
  }

  /**
   * Redistribute extra µp for day D (§8, §11.23):
   * extra_i = min(rhu(remaining / daysLeft), max_extra) with daysLeft counting
   * down N, N−1, …; `remaining` is fixed at episode start (uncovered missed
   * µp) and decreases by a day's extra only when that day's new-ḥifẓ completes.
   */
  private redistributeExtra(day: EpochDay, policy: PlanPolicy): number {
    if (policy.recovery_policy?.kind !== "redistribute") return 0;
    const ep = this.redistributeEpisode;
    if (!ep || ep.daysLeft <= 0 || day <= ep.appliedOn) return 0;
    if (ep.remainingMp === null) ep.remainingMp = this.remainingDebtMicropages(); // lazy init on first boost day
    if (ep.remainingMp <= 0) return 0;
    const maxExtra = amountToMicropages(policy.recovery_policy.max_extra, this.index);
    const extra = Math.min(roundHalfUp(ep.remainingMp, ep.daysLeft), maxExtra);
    ep.extraByDay.set(day, extra);
    return extra;
  }

  private remainingDebtMicropages(): number {
    let sum = 0;
    for (const entry of this.debt) sum += entry.owedMp;
    return sum;
  }

  private weightOfGlobals(globals: number[]): number {
    let sum = 0;
    for (const g of globals) sum += this.index.weightOf(g);
    return sum;
  }

  /**
   * D-049: discharge `mp` of catch-up work against the OLDEST lost slots first.
   * Only work BEYOND a day's base amount repays a slot — one day's normal ḥifẓ
   * cannot repay a day that was lost.
   */
  private dischargeDebt(mp: number): void {
    let left = mp;
    for (const entry of this.debt) {
      if (left <= 0) break;
      const take = Math.min(entry.owedMp, left);
      entry.owedMp -= take;
      left -= take;
    }
    for (let i = this.debt.length - 1; i >= 0; i--) {
      if (this.debt[i].owedMp <= 0) this.debt.splice(i, 1);
    }
  }

  // ------------------------------------------------------------------
  // Murājaʿah (pool_rotation)
  // ------------------------------------------------------------------

  private murajaahSlice(
    day: EpochDay,
    env: VariableEnv,
    spec: { pool: import("./dsl.ts").PoolSpecDsl; per_day: import("./dsl.ts").PerDaySpecDsl; weak_boost?: number },
    policy: PlanPolicy,
    warmupSet: Set<number>,
    distSliceMicropages: number,
    cursorKey: string,
  ): { positions: number[]; nextCursor: number } | null {
    const poolPositions = this.murajaahPoolPositions(spec.pool, env, warmupSet);
    if (poolPositions.length === 0) return null;
    const seq = this.order.seq;

    const slicingWeightAt = (pos: number): number => this.slicingWeightOf(seq[pos]);
    let poolSlicingTotal = 0;
    for (const p of poolPositions) poolSlicingTotal += slicingWeightAt(p);

    let m: number;
    if ("cycle_days" in spec.per_day) {
      // E-3a (D-045): fixed-interval cycling — cover the WHOLE pool every N days.
      // The daily amount is derived from the pool, so the per-item review interval
      // stays FIXED as the corpus grows (a ramp cannot express this: it scales with
      // weeks elapsed, not corpus size). This is why Dhor "becomes the dominant
      // daily time commitment" as more juzʾ accumulate. Ceil so the guarantee is
      // "at least once every N days". No ceiling exists in this mode, so the
      // GX-09 distributed-slice clamp does not apply.
      const n = env.int(spec.per_day.cycle_days);
      if (n < 1) throw new EngineError(`pool_rotation.per_day.cycle_days must be >= 1 (got ${n})`);
      m = Math.min(idiv(poolSlicingTotal + n - 1, n), poolSlicingTotal);
    } else {
      const rampStartAmount = policy.murajaah_ramp?.start ?? env.amount(spec.per_day.ramp.start as string);
      const rampStepAmount = env.amount(spec.per_day.ramp.step as string);
      const ceilingAmount = env.amount(spec.per_day.ramp.ceiling as string);
      const startMp = amountToMicropages(rampStartAmount, this.index);
      const stepMp = amountToMicropages(rampStepAmount, this.index);
      const ceilMp = amountToMicropages(ceilingAmount, this.index);

      const ramp = startMp + stepMp * this.completedWeeks(day);
      m = Math.min(ceilMp, ramp, poolSlicingTotal);
      // Ceiling interaction with a distributed juz-review slice (GX-09):
      if (distSliceMicropages > 0) m = Math.min(m, Math.max(0, ceilMp - distSliceMicropages));
    }
    if (m <= 0) return null;

    return rotationSlice(poolPositions, this.rotationCursors.get(cursorKey) ?? 0, m, slicingWeightAt, seq.length);
  }

  // E-1 (D-038): resolve a murājaʿah pool window to order positions.
  //  - "prior_hifz": all declared+completed, minus today's warm-up windows.
  //  - {recent_pages|recent_juz: N}: the most-recently-memorized N pages/juz by
  //    memorization order (naturally a rolling window as new ḥifẓ accrues); does
  //    NOT subtract the warm-up window (a recent layer is meant to cover it).
  //  - E-1b (D-043) {all_except_recent_pages|all_except_recent_juz: N}: the exact
  //    complement of the recent window — everything that has ROLLED OFF it. Like
  //    prior_hifz it subtracts the warm-up union (it is an "old material" layer).
  private murajaahPoolPositions(
    pool: import("./dsl.ts").PoolSpecDsl,
    env: VariableEnv,
    warmupSet: Set<number>,
  ): number[] {
    const seq = this.order.seq;
    const memorized: number[] = [];
    for (let p = 0; p < seq.length; p++) {
      const g = seq[p];
      if (this.declared[g] || this.completed[g]) memorized.push(p);
    }
    if (pool === "prior_hifz") {
      return memorized.filter((p) => !warmupSet.has(seq[p]));
    }

    // The most-recent window: walk memorization order backwards accumulating
    // weight. E-1b's complement is defined as EXACTLY this window's inverse, so
    // both are derived from one walk and can never drift apart.
    const recentSpec = (): { unitMp: number; count: number; complement: boolean } => {
      if ("recent_pages" in pool) return { unitMp: 1_000_000, count: env.int(pool.recent_pages), complement: false };
      if ("recent_juz" in pool) return { unitMp: 20_000_000, count: env.int(pool.recent_juz), complement: false };
      if ("all_except_recent_pages" in pool) {
        return { unitMp: 1_000_000, count: env.int(pool.all_except_recent_pages), complement: true };
      }
      return { unitMp: 20_000_000, count: env.int(pool.all_except_recent_juz), complement: true };
    };
    const { unitMp, count, complement } = recentSpec();
    const targetMp = count * unitMp;

    let cut = memorized.length; // first index INSIDE the recent window
    let acc = 0;
    for (let i = memorized.length - 1; i >= 0 && acc < targetMp; i--) {
      cut = i;
      acc += this.index.weightOf(seq[memorized[i]]);
    }
    if (!complement) return memorized.slice(cut);
    return memorized.slice(0, cut).filter((p) => !warmupSet.has(seq[p]));
  }

  // ------------------------------------------------------------------
  // Listening look-ahead (tomorrow_new, §7)
  // ------------------------------------------------------------------

  private tomorrowNew(day: EpochDay, todaysNewLastPos: number | undefined): number[] {
    // Projection assumes completion of D's new material.
    const savedCursor = this.cursorPos;
    if (todaysNewLastPos !== undefined) this.cursorPos = todaysNewLastPos + 1;
    try {
      for (let e = addDays(day, 1); e <= addDays(day, LOOKAHEAD_DAYS); e++) {
        if (!this.dayAllows(e)) continue;
        // §7/§11.9: evaluated against the curriculum AND policy in force on the
        // look-ahead date E, not on D — a curriculum switch between the two
        // changes both which rule fires and how much it takes.
        const curE = this.curOn(e);
        const newRules = curE.rules.filter((r) => r.emit.type === "new_hifz");
        const cls = this.classOf(e);
        const week = this.insertedWeeks.get(this.myWeekStart(e));
        const policyE = policyAt(this.ctx.policy, this.fold, e);
        const envE = resolveVariables(curE, policyE);
        for (const rule of newRules) {
          if (!this.ruleMatches(rule, cls, e, envE, policyE)) continue;
          if (week && week.mode === "pause_new" && rule.suppressed_by?.includes(week.triggerId)) continue;
          const sel = this.selectorOf(rule.emit.select, curE);
          if (!("next_new" in sel)) continue;
          const amount = this.index.resolveAmount(envE.amount(sel.next_new.amount));
          const positions = selectNextNew(this.order, this.index, this.cursorPos, amount, this.isSelectableNew);
          if (positions.length > 0) return positions.map((p) => this.order.seq[p]);
        }
      }
      return [];
    } finally {
      this.cursorPos = savedCursor;
    }
  }

  // ------------------------------------------------------------------
  // Rule matching & selector dispatch
  // ------------------------------------------------------------------

  /** Weak-declared ayahs carry half slicing-weight (D-012, §11.22). */
  private slicingWeightOf(g: number): number {
    const w = this.index.weightOf(g);
    return this.weak[g] ? idiv(w, 2) : w;
  }

  private ruleMatches(rule: RuleSpec, cls: string, day: EpochDay, env: VariableEnv, policy: PlanPolicy): boolean {
    const classes = Array.isArray(rule.when.day_class) ? rule.when.day_class : [rule.when.day_class];
    if (!classes.includes(cls)) return false;
    // §11.19: R-N1 emission days additionally respect policy.active_weekdays.
    if (rule.emit.type === "new_hifz" && !this.isActiveWeekday(day, policy)) return false;
    if (rule.when.enabled !== undefined && !env.bool(rule.when.enabled)) return false;
    if (rule.when.day_in !== undefined && !env.weekdaySet(rule.when.day_in).includes(dayOfWeek(day))) return false;
    for (const cond of rule.when.not ?? []) {
      if (cond === "first_active_day" && day === this.firstActiveDay) return false;
    }
    return true;
  }

  private selectorOf(sel: string | SelectorSpec | undefined, cur: CompiledCurriculum = this.cur): SelectorSpec {
    if (sel === undefined) throw new EngineError("rule emit has no selector");
    if (typeof sel === "string") {
      const found = cur.selectors[sel];
      if (!found) throw new EngineError(`unknown selector ${sel}`);
      return found;
    }
    return sel;
  }

  // ------------------------------------------------------------------
  // Trigger firing (juz boundaries, target completion)
  // ------------------------------------------------------------------

  private markCompleted(globals: number[]): void {
    for (const g of globals) {
      if (this.completed[g]) continue;
      this.completed[g] = 1;
      this.completedInJuz[this.index.juzOf(g)]++;
      if (this.currentTarget[g] && !this.declared[g]) this.targetCoveredCount++;
    }
  }

  private checkBoundaryTriggers(day: EpochDay, envDay: VariableEnv): void {
    // Juz completion — in-plan completions only (declared never fires triggers).
    for (let j = 1; j <= this.index.juzCount; j++) {
      if (!this.juzFired[j] && this.completedInJuz[j] === this.juzSize[j]) {
        this.juzFired[j] = 1;
        this.juzDoneCount++;
        this.juzCompletionOrder.push(j);
        this.fireJuzTriggers(day, j, envDay);
      }
    }
    // Target completion (R-C1): every target ayah declared or completed.
    if (!this.planCompleted && this.targetTotal > 0 && this.targetCoveredCount >= this.targetTotal) {
      for (const t of this.curOn(day).triggers) {
        if (t.on.boundary === "target" && t.effects.some((e) => "complete_plan" in e)) {
          this.planCompleted = true;
        }
      }
    }
  }

  private fireJuzTriggers(day: EpochDay, juz: number, env: VariableEnv): void {
    for (const trigger of this.curOn(day).triggers) {
      if (trigger.on.boundary !== "juz") continue;
      const every = trigger.on.every !== undefined ? env.int(trigger.on.every) : 1;
      if (every < 1 || this.juzDoneCount % every !== 0) continue;
      for (let ei = 0; ei < trigger.effects.length; ei++) {
        const eff = trigger.effects[ei];
        if ("schedule" in eff) this.applyScheduleEffect(day, juz, trigger, eff, ei);
        else if ("insert_week" in eff) this.applyInsertWeekEffect(day, trigger, eff, env);
      }
    }
  }

  private applyScheduleEffect(
    day: EpochDay,
    juz: number,
    trigger: TriggerSpec,
    eff: TriggerScheduleEffect,
    effectIndex: number,
  ): void {
    const s = eff.schedule;
    const origin = `${trigger.id}.${s.type}`;
    const session = s.into_session ?? "morning";
    const ordering = 90 + effectIndex;
    const estOverride = s.est_minutes;
    const selector = this.selectorOf(s.select, this.curOn(day));

    if ("completed_juz" in selector) {
      // (a) whole just-completed juz on the next active day (§11.19:
      // active_weekdays is authoritative for "next active day").
      const [a, b] = this.index.juzGlobalRange(juz);
      const globals: number[] = [];
      for (let g = a; g < b; g++) globals.push(g);
      let d = addDays(day, 1);
      const bound = addDays(day, 366);
      while (!(this.dayAllows(d) && this.isActiveWeekday(d, policyAt(this.ctx.policy, this.fold, d)))) {
        d++;
        if (d > bound) return; // no active day within a year (e.g. open-ended pause)
      }
      const list = this.scheduledByDate.get(d) ?? [];
      list.push({ origin, type: s.type as TaskType, session, ordering, contentGlobals: globals, estOverride });
      this.scheduledByDate.set(d, list);
      return;
    }

    if ("prior_hifz_split" in selector) {
      // (b) §11.22 (as amended): prior hifz (in-plan + declared, excluding
      // juz `juz`) in near-equal PLAIN-µp slices — weak-boost is a rotation-
      // frequency concept only. Slice k (1-based) is emitted on calendar day
      // fire_date + k. Empty slices leave their day empty (no compaction);
      // paused/exception/occupied days skip forward (§11.11).
      const parts = s.distribute_over_days ?? selector.prior_hifz_split.parts;
      const [ja, jb] = this.index.juzGlobalRange(juz);
      const ordered: number[] = [];
      const seq = this.order.seq;
      for (let p = 0; p < seq.length; p++) {
        const g = seq[p];
        if ((this.declared[g] || this.completed[g]) && (g < ja || g >= jb)) ordered.push(g);
      }
      const slices = splitNearEqual(this.index, ordered, parts);
      const bound = addDays(day, 366 + parts);
      for (let k = 1; k <= parts; k++) {
        const slice = slices[k - 1];
        if (!slice || slice.length === 0) continue; // §11.22: empty slice, day stays empty
        let d = addDays(day, k);
        while (!this.dayAllows(d) || this.distSliceByDate.has(d)) {
          d++;
          if (d > bound) return; // no assignable day within a year
        }
        this.distSliceByDate.set(d, {
          origin,
          type: s.type as TaskType,
          session,
          ordering,
          contentGlobals: slice,
          estOverride,
        });
      }
      return;
    }

    throw new EngineError(`trigger ${trigger.id}: unsupported schedule selector`);
  }

  private applyInsertWeekEffect(
    day: EpochDay,
    trigger: TriggerSpec,
    eff: TriggerInsertWeekEffect,
    env: VariableEnv,
  ): void {
    // D-017: the consolidation week is the next full week after any pending
    // R-J1 distribution finishes; overlap defers to the following week start.
    let lastPending = day;
    for (const d of this.distSliceByDate.keys()) {
      if (d > lastPending) lastPending = d;
    }
    let candidate = this.myWeekStart(day) + 7;
    while (lastPending >= candidate) candidate = this.myWeekStart(lastPending) + 7;
    while (this.insertedWeeks.has(candidate)) candidate += 7;

    const blockLen = this.blockJuzCount(eff.insert_week.day_rules, env, this.curOn(day));
    // NB: `slice(-0)` returns the WHOLE array (−0 === 0), so a block-less pause
    // week (E-5) must be spelled out rather than relying on slice semantics.
    const blockJuz = blockLen === 0 ? [] : this.juzCompletionOrder.slice(-blockLen);
    // Block juz in memorization-order sequence.
    blockJuz.sort((a, b) => {
      const pa = this.order.posOf[this.index.juzGlobalRange(a)[0]];
      const pb = this.order.posOf[this.index.juzGlobalRange(b)[0]];
      return pa - pb;
    });

    this.insertedWeeks.set(candidate, {
      weekStartDay: candidate,
      triggerId: trigger.id,
      mode: env.str(`$${eff.insert_week.mode_var}`),
      dayRules: eff.insert_week.day_rules,
      blockJuz,
    });
    this.cycleFiredCount++;
  }

  /** juz_count of the block referenced by the inserted week's day rules. */
  private blockJuzCount(dayRules: RuleSpec[], env: VariableEnv, cur: CompiledCurriculum = this.cur): number {
    // E-5 (D-047): a PURE pause week declares no day_rules of its own — it only
    // suppresses. It has no block, so there is nothing to size. (A non-empty
    // day_rules set with no block selector is still an authoring error below.)
    if (dayRules.length === 0) return 0;
    for (const r of dayRules) {
      const sel = this.selectorOf(r.emit.select, cur);
      if ("block" in sel) return env.int(sel.block.juz_count);
      if ("block_slice" in sel) {
        const inner = this.selectorOf(sel.block_slice.of, cur);
        if ("block" in inner) return env.int(inner.block.juz_count);
      }
    }
    throw new EngineError("insert_week day_rules reference no block selector");
  }

  private blockGlobals(week: InsertedWeek): number[] {
    const out: number[] = [];
    for (const j of week.blockJuz) {
      const [a, b] = this.index.juzGlobalRange(j);
      for (let g = a; g < b; g++) out.push(g);
    }
    return out;
  }

  // ------------------------------------------------------------------
  // Workload model (§7.10 / ENGINE_SEMANTICS §1)
  // ------------------------------------------------------------------

  /**
   * B:CB-0 finding 4 — unified rate lookup. The old switch bound each type to
   * ONE hard-coded rate key, so a curriculum that declared a rate under the
   * task type's own name (e.g. `tasmee`) was ignored, and a MISSING key
   * produced `undefined * n === NaN` rather than a defined fallback. Swift's
   * order is now matched exactly:
   *   1. an authored `est_minutes` override (CB-2) — before everything, even
   *      the `prep_dhikr` zero-out;
   *   2. `prep_dhikr` ⇒ 0 (§11.3);
   *   3. `rates[type]` ▸ `rates[fallbackKey]` ▸ 0 (never NaN).
   * Rates are decomposed exactly (units/denominator) rather than multiplied as
   * JS numbers, so a decimal rate can never introduce binary float into an
   * emitted value (ENGINE_PARITY §1).
   */
  private estimateMinutes(
    cur: CompiledCurriculum,
    type: TaskType,
    globals: number[],
    reps?: number,
    listenCount?: number,
    estOverride?: number,
  ): number {
    if (estOverride !== undefined) return estOverride;
    if (type === "prep_dhikr") return 0;
    const rates = cur.forecast.workload_rates;
    // ENGINE_SEMANTICS §11.16: listening = rate[listening_lesson] × listen_count.
    if (type === "listening") {
      const raw = rates["listening_lesson"] ?? rates[type];
      if (raw === undefined) return 0;
      const { units, den } = decimalParts(raw);
      return roundHalfUp(units * (listenCount ?? 1), den);
    }
    let fallbackKey: string;
    let perRep = false;
    switch (type) {
      case "new_hifz":
        fallbackKey = "new_hifz";
        break;
      case "warmup":
        fallbackKey = "warmup";
        break;
      case "takrar":
      case "weekend_consolidation":
        fallbackKey = "takrar_rep";
        perRep = true;
        break;
      // §11.3 review-pass fallback: murajaah, tasmee, juz_review(±distributed),
      // cycle_consolidation, and any unknown type all price as a review pass.
      default:
        fallbackKey = "murajaah";
    }
    const raw = rates[type] ?? rates[fallbackKey];
    if (raw === undefined) return 0;
    const { units, den } = decimalParts(raw);
    let weighted = 0;
    for (const g of globals) weighted += this.index.weightOf(g) * this.strengthScaled[g];
    if (weighted <= 0) return 0;
    const n = perRep ? (reps ?? 1) : 1;
    return roundHalfUp(units * weighted * n, den * 1_000_000_000);
  }

  // ------------------------------------------------------------------
  // Main loop
  // ------------------------------------------------------------------

  run(windowFrom: EpochDay, windowTo: EpochDay): GenerationResult {
    const out: TaskInstance[] = [];
    for (let day = this.anchor; day <= windowTo; day++) {
      const tasks = this.generateDay(day);
      if (day >= windowFrom && day <= windowTo) out.push(...tasks);
    }
    return { tasks: out, state: this.finalState(windowTo) };
  }

  private generateDay(day: EpochDay): TaskInstance[] {
    if (isPausedOn(this.fold, day)) return [];

    // Redistribute episode activation (latest application ≤ day replaces prior).
    while (this.pendingRecoveryApps.length > 0 && this.pendingRecoveryApps[0] <= day) {
      const appliedOn = this.pendingRecoveryApps.shift()!;
      const pol = policyAt(this.ctx.policy, this.fold, appliedOn);
      if (pol.recovery_policy?.kind === "redistribute") {
        this.redistributeEpisode = {
          appliedOn,
          daysLeft: pol.recovery_policy.days,
          remainingMp: null,
          extraByDay: new Map(),
        };
      }
    }

    // PC-5: the hard-boundary sweep runs BEFORE the day's consolidation week is
    // resolved, so it cannot suppress the boundary day it exists to unblock.
    this.sweepAtBoundary(day);

    const curDay = this.curOn(day);
    const policy = policyAt(this.ctx.policy, this.fold, day);
    this.currentTarget = this.targetSetFor(policy);
    if (this.targetCache.size > 1) this.recountTarget();
    const env = resolveVariables(curDay, policy);
    const cls = this.classOf(day);
    const emitted: InternalTask[] = [];

    if (!this.isException(day)) {
      const week = this.insertedWeeks.get(this.myWeekStart(day));
      const inCycleWeek = week !== undefined;
      const suppressNew = inCycleWeek && week!.mode === "pause_new";
      const warmupSet = this.warmupSetForDay(day, cls, env, policy);
      const distSlice = this.distSliceByDate.get(day);
      const distSliceMp = distSlice ? distSlice.contentGlobals.reduce((s, g) => s + this.index.weightOf(g), 0) : 0;
      const selectorMemo = new Map<string, number[]>();

      // 1) Daily rules in curriculum order (of the curriculum active TODAY).
      for (const rule of curDay.rules) {
        if (suppressNew && rule.suppressed_by?.includes(week!.triggerId)) {
          // D-048: a FAILURE week (inserted by a task_failed trigger) costs the
          // learner advancement slots they did not choose to give up, so each
          // suppressed new-ḥifẓ day owes debt — slot-based per D-035, because
          // that is how many slots the schedule actually lost. A PLANNED pause
          // (Maknoon's juzʾ-boundary consolidation week) is the curriculum
          // working as designed and owes nothing.
          if (
            rule.emit.type === "new_hifz" && day < this.today &&
            this.isFailureWeek(week!) && this.isActiveWeekday(day, policy)
          ) {
            const sel = this.selectorOf(rule.emit.select, curDay);
            if ("next_new" in sel) {
              const globals = this.selectNew(day, env, sel.next_new.amount, policy);
              if (globals.length > 0) this.debt.push({ date: day, globals, owedMp: this.weightOfGlobals(globals) });
            }
          }
          continue;
        }
        if (!this.ruleMatches(rule, cls, day, env, policy)) continue;
        const task = this.emitRule(rule, day, env, policy, warmupSet, distSliceMp, selectorMemo, 0, curDay);
        if (task) emitted.push(task);
      }

      // 2) Inserted consolidation-week day rules (cycle_consolidation, ordering 90+).
      if (inCycleWeek) {
        for (const rule of week!.dayRules) {
          if (!this.ruleMatches(rule, cls, day, env, policy)) continue;
          const task = this.emitCycleRule(rule, day, env, week!, curDay);
          if (task) emitted.push(task);
        }
      }

      // 3) Trigger-scheduled tasks.
      for (const st of this.scheduledByDate.get(day) ?? []) {
        emitted.push({
          session: st.session,
          ordering: st.ordering,
          type: st.type,
          origin: st.origin,
          contentGlobals: st.contentGlobals,
          infoOnly: false,
          estOverride: st.estOverride,
        });
      }
      if (distSlice) {
        emitted.push({
          session: distSlice.session,
          ordering: distSlice.ordering,
          type: distSlice.type,
          origin: distSlice.origin,
          contentGlobals: distSlice.contentGlobals,
          infoOnly: false,
          estOverride: distSlice.estOverride,
        });
      }
    }

    // Sort: session → ordering → origin_rule_id (UTF-8 bytes). Session order
    // follows the curriculum's DECLARED session sequence (so a custom "midday"
    // sits between morning and evening); Maknoon's morning<evening is the
    // special case (2026-07-16 multi-curriculum parity fix). Unknown ids last.
    const sessionRank = (id: string): number => {
      const i = curDay.sessions.findIndex((s) => s.id === id);
      return i >= 0 ? i : 999;
    };
    emitted.sort((a, b) =>
      sessionRank(a.session) - sessionRank(b.session) ||
      a.ordering - b.ordering ||
      (a.origin < b.origin ? -1 : a.origin > b.origin ? 1 : 0)
    );

    // Occurrence + uid + materialize.
    const occCounter = new Map<string, number>();
    const dateStr = formatLocalDate(day);
    const inCycleWeekFlag = !this.isException(day) && this.insertedWeeks.has(this.myWeekStart(day));
    const tasks: TaskInstance[] = [];
    for (const t of emitted) {
      const occKey = `${t.session}|${t.origin}`;
      const occurrence = occCounter.get(occKey) ?? 0;
      occCounter.set(occKey, occurrence + 1);
      const uid = uuid5(this.ctx.plan_id, `${dateStr}|${t.session}|${t.origin}|${occurrence}`);
      const flags: TaskFlag[] = [];
      if (t.infoOnly) flags.push("info_only");
      if (day === this.firstActiveDay) flags.push("first_active_day");
      if (inCycleWeekFlag) flags.push("consolidation_week");
      flags.sort();
      const content = orderContent(this.index, this.order, globalsToContent(this.index, t.contentGlobals));
      tasks.push({
        task_uid: uid,
        plan_id: this.ctx.plan_id,
        date: dateStr,
        day_class: cls,
        session: t.session,
        ordering: t.ordering,
        type: t.type,
        origin_rule_id: t.origin,
        occurrence,
        content,
        target_repetitions: t.reps,
        spacing_minutes: t.spacing,
        listen_count: t.listenCount,
        window: t.window
          ? { opens_on: formatLocalDate(t.window.opens_on), closes_on: formatLocalDate(t.window.closes_on) }
          : undefined,
        estimated_minutes: this.estimateMinutes(curDay, t.type, t.contentGlobals, t.reps, t.listenCount, t.estOverride),
        evidence: t.infoOnly ? null : resolveEvidence(curDay, policy, env, t.type),
        flags,
      });
    }

    const deduplicated = curDay.task_deduplication?.mode === "exact_execution"
      ? deduplicateExactExecution(tasks)
      : { output: tasks, state_tasks: tasks };
    this.advanceState(day, emitted, deduplicated.state_tasks, env, curDay);
    return deduplicated.output;
  }

  // H-5 (2026-07-16): the murājaʿah pool subtracts the UNION of every warm-up
  // window emitted TODAY (§4 "no double coverage") — not one arbitrary
  // ledger_window selector. Days with no warm-up subtract nothing. Maknoon
  // (one warm-up window on weekdays) is unchanged; multi-window curricula
  // (part-time's yesterday+sabqi) now converge tri-platform.
  private warmupSetForDay(day: EpochDay, cls: string, env: VariableEnv, policy: PlanPolicy): Set<number> {
    const set = new Set<number>();
    const curDay = this.curOn(day);
    for (const rule of curDay.rules) {
      if (rule.emit.type !== "warmup" || rule.emit.select === undefined) continue;
      if (!this.ruleMatches(rule, cls, day, env, policy)) continue;
      const sel = this.selectorOf(rule.emit.select, curDay);
      if ("ledger_window" in sel) {
        for (const g of this.warmupWindowSet(day, env, sel.ledger_window)) set.add(g);
      }
    }
    return set;
  }

  private emitRule(
    rule: RuleSpec,
    day: EpochDay,
    env: VariableEnv,
    policy: PlanPolicy,
    warmupSet: Set<number>,
    distSliceMp: number,
    memo: Map<string, number[]>,
    orderingBase: number,
    cur: CompiledCurriculum = this.cur,
  ): InternalTask | null {
    const e = rule.emit;
    const infoOnly = e.info_only === true;
    let contentGlobals: number[] = [];
    let newHifzLastPos: number | undefined;
    let rotationNextCursor: number | undefined;

    if (!infoOnly && e.select !== undefined) {
      const sel = this.selectorOf(e.select, cur);
      const memoKey = typeof e.select === "string" ? e.select : undefined;
      if (memoKey !== undefined && memo.has(memoKey)) {
        contentGlobals = memo.get(memoKey)!;
        if (("next_new" in sel || "next_content" in sel) && contentGlobals.length > 0) {
          newHifzLastPos = this.order.posOf[contentGlobals[contentGlobals.length - 1]];
        }
      } else if ("next_content" in sel) {
        const positions = this.selectContent(env, sel.next_content.amount);
        contentGlobals = positions.map((p) => this.order.seq[p]);
        if (positions.length > 0) newHifzLastPos = positions[positions.length - 1];
      } else if ("next_new" in sel) {
        const positions = this.selectNew(day, env, sel.next_new.amount, policy);
        contentGlobals = positions.map((p) => this.order.seq[p]);
        if (positions.length > 0) newHifzLastPos = positions[positions.length - 1];
      } else if ("ledger_window" in sel) {
        contentGlobals = [...this.warmupWindowSet(day, env, sel.ledger_window)].sort((a, b) => a - b);
      } else if ("ledger_offset" in sel) {
        // E-2 (D-039): the new-ḥifẓ ledger of exactly one prior day (D − N).
        const k = env.int(sel.ledger_offset.days_ago);
        contentGlobals = [...this.unionLedger(addDays(day, -k), addDays(day, -k))].sort((a, b) => a - b);
      } else if ("week_to_date" in sel) {
        contentGlobals = [...this.unionLedger(this.myWeekStart(day), addDays(day, -1))].sort((a, b) => a - b);
      } else if ("pool_rotation" in sel) {
        const slice = this.murajaahSlice(day, env, sel.pool_rotation, policy, warmupSet, distSliceMp, rule.id);
        if (slice) {
          contentGlobals = slice.positions.map((p) => this.order.seq[p]);
          rotationNextCursor = slice.nextCursor;
        }
      } else if ("tomorrow_new" in sel) {
        const todaysNew = memo.get(this.newHifzSelectorName(cur) ?? "") ?? this.todaysNewGlobals(memo, cur);
        const lastPos = todaysNew.length > 0 ? this.order.posOf[todaysNew[todaysNew.length - 1]] : undefined;
        contentGlobals = this.tomorrowNew(day, lastPos);
      } else if ("fixed" in sel) {
        for (const r of sel.fixed.range) {
          const [a, b] = this.index.rangeToGlobal(r);
          for (let g = a; g <= b; g++) contentGlobals.push(g);
        }
      } else if ("intersect_prior_hifz" in sel) {
        const inner = this.selectorOf(sel.intersect_prior_hifz.of, cur);
        if (!("fixed" in inner)) {
          throw new EngineError("intersect_prior_hifz currently requires a fixed selector");
        }
        for (const r of inner.fixed.range) {
          const [a, b] = this.index.rangeToGlobal(r);
          for (let g = a; g <= b; g++) {
            if (this.declared[g] || this.completed[g]) contentGlobals.push(g);
          }
        }
      } else {
        throw new EngineError(`rule ${rule.id}: selector kind not usable in daily rules`);
      }
      if (memoKey !== undefined && !memo.has(memoKey)) memo.set(memoKey, contentGlobals);
      if (contentGlobals.length === 0) return null; // empty-content rule (§3)
    }

    const window = e.window
      ? {
        opens_on: this.weekdayDateInWeek(day, e.window.opens),
        closes_on: this.weekdayDateInWeek(day, e.window.closes),
      }
      : undefined;

    return {
      session: rule.when.session,
      ordering: orderingBase + e.ordering,
      type: e.type as TaskType,
      origin: rule.id,
      contentGlobals,
      reps: e.repetitions !== undefined ? env.int(e.repetitions) : undefined,
      spacing: e.spacing_minutes !== undefined ? env.int(e.spacing_minutes) : undefined,
      listenCount: e.listen_count !== undefined ? env.int(e.listen_count) : undefined,
      window,
      infoOnly,
      estOverride: e.est_minutes,
      newHifzLastPos,
      rotationNextCursor,
    };
  }

  private newHifzSelectorName(cur: CompiledCurriculum = this.cur): string | undefined {
    for (const r of cur.rules) {
      if (r.emit.type === "new_hifz" && typeof r.emit.select === "string") return r.emit.select;
    }
    return undefined;
  }

  private todaysNewGlobals(memo: Map<string, number[]>, cur: CompiledCurriculum = this.cur): number[] {
    // Only meaningful on days where a new_hifz rule actually emitted; the memo
    // holds the day's selection when it did. Otherwise there is no new today.
    const name = this.newHifzSelectorName(cur);
    if (name && memo.has(name)) return memo.get(name)!;
    return [];
  }

  /** Date of a weekday within D's curriculum week. */
  private weekdayDateInWeek(day: EpochDay, wd: Weekday): EpochDay {
    const ws = this.myWeekStart(day);
    const offset = (WEEKDAYS.indexOf(wd) - WEEKDAYS.indexOf(this.curOn(day).calendar.week_start) + 7) % 7;
    return ws + offset;
  }

  private emitCycleRule(
    rule: RuleSpec,
    day: EpochDay,
    env: VariableEnv,
    week: InsertedWeek,
    cur: CompiledCurriculum = this.cur,
  ): InternalTask | null {
    const sel = this.selectorOf(rule.emit.select, cur);
    let contentGlobals: number[] = [];
    if ("block_slice" in sel) {
      const parts = sel.block_slice.parts;
      // Which weekday-class slot of the inserted week is this? (Sun→Thu = 0..4)
      let slot = 0;
      for (let d = week.weekStartDay; d < day; d++) {
        if (!this.isException(d) && this.classOf(d) === this.classOf(day)) slot++;
      }
      if (week.blockJuz.length === parts) {
        // ENGINE_SEMANTICS §6: one whole block juz per weekday, memorization order.
        const j = week.blockJuz[slot % parts];
        const [a, b] = this.index.juzGlobalRange(j);
        for (let g = a; g < b; g++) contentGlobals.push(g);
      } else {
        const all = this.blockGlobals(week);
        const slices = splitNearEqual(this.index, all, parts);
        contentGlobals = slices[slot % parts] ?? [];
      }
    } else if ("block" in sel) {
      contentGlobals = this.blockGlobals(week);
    } else {
      throw new EngineError(`cycle rule ${rule.id}: unsupported selector`);
    }
    if (contentGlobals.length === 0) return null;
    return {
      session: rule.when.session,
      ordering: 90 + rule.emit.ordering,
      type: rule.emit.type as TaskType,
      origin: rule.id,
      contentGlobals,
      reps: rule.emit.repetitions !== undefined ? env.int(rule.emit.repetitions) : undefined,
      infoOnly: rule.emit.info_only === true,
      estOverride: rule.emit.est_minutes,
    };
  }

  // ------------------------------------------------------------------
  // State advancement (actual vs projection; ENGINE_SEMANTICS §9)
  // ------------------------------------------------------------------

  private advanceState(
    day: EpochDay,
    emitted: InternalTask[],
    tasks: TaskInstance[],
    env: VariableEnv,
    cur: CompiledCurriculum = this.cur,
  ): void {
    // E-4b (D-046): the advancement gate is the ACTIVE curriculum's, so a
    // switch onto (or off) a require_verified curriculum takes effect that day.
    const requireVerified = cur.advancement?.require_verified === true;
    const projection = day > this.today;
    let anyCompletion = false;
    let newCompletedToday = false;

    for (let i = 0; i < emitted.length; i++) {
      const t = emitted[i];
      const uid = tasks[i]?.task_uid;
      const rec = uid ? this.fold.completions.get(uid) : undefined;
      const done = projection || rec?.completed === true;

      if (t.type === "new_hifz" && t.contentGlobals.length > 0) {
        // E-4b (D-046): under require_verified, a completed-but-UNVERIFIED
        // portion is a teacher REJECTION (mardūd) — it must not advance. In
        // projection every day is assumed to pass (else a forecast could never
        // progress).
        const pass = requireVerified && !projection
          ? rec?.completed === true && rec?.verified === true
          : done;
        if (pass) {
          this.markCompleted(t.contentGlobals);
          const prev = this.ledger.get(day) ?? [];
          this.ledger.set(day, [...prev, ...t.contentGlobals]);
          if (t.newHifzLastPos !== undefined) this.cursorPos = t.newHifzLastPos + 1;
          anyCompletion = true;
          newCompletedToday = true;
        } else if (day < this.today && !rec?.excused) {
          // A FAIL BECOMES DEBT (D-048). Every closed
          // non-pass owes debt — whether it was missed, attempted but not
          // mastered, or teacher-rejected (mardūd). The line is open-vs-closed
          // (D-043), not by-design-vs-failure: `today` has not closed, so the
          // learner may still complete it and owes nothing; once the day closes
          // without a pass, the schedule lost that advancement slot and the
          // forecast must say so. Excused tasks stay exempt.
          this.debt.push({ date: day, globals: t.contentGlobals, owedMp: this.weightOfGlobals(t.contentGlobals) });
        }
      } else if (t.type === "tilawah" && t.contentGlobals.length > 0) {
        if (done && t.newHifzLastPos !== undefined) this.cursorPos = t.newHifzLastPos + 1;
      } else if (t.type === "murajaah" && t.rotationNextCursor !== undefined) {
        // Cursor advances only on completion (actual) or unconditionally
        // (projection); keyed per layer by origin_rule_id (E-1).
        if (done) this.rotationCursors.set(t.origin, t.rotationNextCursor);
      }
    }

    // D-049: lost slots are repaid by CATCH-UP work only. The old sweep dropped
    // every entry whose CONTENT had been completed — but missed days share the
    // frozen cursor content, so one completion cleared them all and `debt_new`
    // read 0 while the learner was still N days behind. Doing the material a day
    // late is not catching up; only the redistribute extra is.

    // Redistribute countdown (§11.23): a boosted day (valid active weekday
    // after the application) consumes daysLeft regardless of completion;
    // `remaining` decreases by the day's extra only when new-ḥifẓ completed.
    const ep = this.redistributeEpisode;
    if (
      ep && day > ep.appliedOn && ep.daysLeft > 0 &&
      this.dayAllows(day) && this.isActiveWeekday(day, policyAt(this.ctx.policy, this.fold, day))
    ) {
      const extra = ep.extraByDay.get(day) ?? 0;
      if (newCompletedToday && ep.remainingMp !== null) {
        ep.remainingMp = Math.max(0, ep.remainingMp - extra);
        this.dischargeDebt(extra); // D-049: the extra IS the catch-up
      }
      ep.daysLeft--;
    }

    if (anyCompletion) this.checkBoundaryTriggers(day, env);
    this.checkTaskFailedTriggers(day, emitted, tasks, env);
  }

  /**
   * E-5 (D-047): a `task_failed` trigger fires when the task its `rule` emitted
   * today was NOT verified. Only on a CLOSED day (`day < today`) — an open day's
   * test has not been sat yet, and a projected day is assumed to pass (§8/D-043,
   * same principle as debt). Wifaq: failing the weekly milestone inserts a
   * pause-new week, so the following week carries no new material.
   */
  private checkTaskFailedTriggers(
    day: EpochDay,
    emitted: InternalTask[],
    tasks: TaskInstance[],
    env: VariableEnv,
  ): void {
    if (day >= this.today) return;
    for (const trigger of this.curOn(day).triggers) {
      const tf = trigger.on.task_failed;
      if (!tf) continue;
      for (let i = 0; i < emitted.length; i++) {
        if (emitted[i].origin !== tf.rule) continue;
        const uid = tasks[i]?.task_uid;
        const rec = uid ? this.fold.completions.get(uid) : undefined;
        if (rec?.verified === true || rec?.excused === true) continue; // passed (or excused)
        for (const eff of trigger.effects) {
          if ("insert_week" in eff) this.applyInsertWeekEffect(day, trigger, eff, env);
        }
      }
    }
  }

  /**
   * D-048: was this week inserted because the learner FAILED something (a
   * `task_failed` trigger), rather than by the curriculum's own design (a juzʾ
   * boundary)? A failure week costs advancement slots the learner did not choose
   * to give up, so those slots owe debt; a planned consolidation week does not.
   */
  private isFailureWeek(week: InsertedWeek): boolean {
    // The week may have been inserted by a curriculum the plan has since
    // switched away from, so search every curriculum this run knows about.
    for (const c of [this.cur, ...Object.values(this.curSet.byKey)]) {
      const trigger = c.triggers.find((t) => t.id === week.triggerId);
      if (trigger) return trigger.on.task_failed !== undefined;
    }
    return false;
  }

  /** §11.19: policy.active_weekdays gates new-ḥifẓ/redistribute/next-active-day. */
  private isActiveWeekday(day: EpochDay, policy: PlanPolicy): boolean {
    return (policy.active_weekdays ?? []).includes(dayOfWeek(day));
  }

  // ------------------------------------------------------------------
  // Final state (#STATE checkpoint)
  // ------------------------------------------------------------------

  private finalState(windowTo: EpochDay): PlanState {
    // Cursor = next selectable new-hifz ayah.
    let cursor: PlanState["cursor"] = null;
    const isTilawahPlan = this.cur.rules.some((rule) => rule.emit.type === "tilawah");
    for (let p = this.cursorPos; p < this.order.seq.length; p++) {
      const g = this.order.seq[p];
      if (isTilawahPlan || this.isSelectableNew(g)) {
        cursor = this.index.positionOf(g);
        break;
      }
    }

    // D-049: the count of still-owed lost slots (a slot's content may well be
    // memorized by now — that does not give the lost day back).
    let debtRanges = 0;
    for (const entry of this.debt) {
      if (entry.owedMp > 0) debtRanges += globalsToContent(this.index, entry.globals).length;
    }

    let status: PlanStatus = "active";
    if (this.planCompleted) status = "completed";
    else if (isPausedOn(this.fold, windowTo)) status = "paused";

    return {
      cursor,
      juz_completed_count: this.juzDoneCount,
      cycle_weeks: this.cycleFiredCount,
      debt_new_ranges: debtRanges,
      status,
    };
  }
}
