// Selector algebra (PRD §8.2) — pure range-selection helpers used by the
// generator. All ten selector kinds are covered:
//   next_new · ledger_window · week_to_date · pool_rotation · completed_juz ·
//   prior_hifz_split · block · tomorrow_new · fixed · block_slice
//
// ledger_window / week_to_date / tomorrow_new / pool_rotation need day-loop
// state; the generator orchestrates them on top of the primitives here.
// Precise arithmetic: ENGINE_SEMANTICS §§1–5 (D-013 40% round-down, D-014
// ⅓-bridge, micropage integer math, weak-boost half slicing weight).

import { ContentIndex, ResolvedAmount, resolveQuranAmount } from "./content_index.ts";
import {
  CanonicalRange,
  EngineError,
  idiv,
  OrderSpec,
  QuranAmount,
} from "./types.ts";

// Re-exported at their historical home: `ResolvedAmount` and `resolveAmount`
// moved to content_index.ts so `QuranIndex` can reach them without importing
// this module (which imports it back). Every existing call site is unchanged.
export type { ResolvedAmount };

// ---------------------------------------------------------------------------
// Memorization order (D-005 / ENGINE_SEMANTICS §2)
// ---------------------------------------------------------------------------

export interface MemorizationOrder {
  /** orderPos → global ayah index. */
  seq: Uint32Array;
  /** global ayah index → orderPos (-1 if absent, only possible for custom_list). */
  posOf: Int32Array;
}

export function buildMemorizationOrder(spec: OrderSpec, index: ContentIndex): MemorizationOrder {
  const total = index.totalAyahs;
  let seq: Uint32Array;

  switch (spec.kind) {
    case "mushaf_forward": {
      seq = new Uint32Array(total);
      for (let g = 0; g < total; g++) seq[g] = g;
      break;
    }
    case "juz_amma_backward": {
      // Juz blocks descending (30, 29, …, 1); within each block, surah
      // segments descending by surah; ayahs ascending within a segment.
      const out: number[] = [];
      for (let j = index.juzCount; j >= 1; j--) {
        const [start, end] = index.juzGlobalRange(j);
        // Group [start, end) into per-surah contiguous segments.
        const segments: [number, number][] = [];
        let s = start;
        while (s < end) {
          const surah = index.surahOf(s);
          let e = s;
          while (e + 1 < end && index.surahOf(e + 1) === surah) e++;
          segments.push([s, e]);
          s = e + 1;
        }
        segments.sort((a, b) => index.surahOf(b[0]) - index.surahOf(a[0]));
        for (const [a, b] of segments) {
          for (let g = a; g <= b; g++) out.push(g);
        }
      }
      seq = Uint32Array.from(out);
      break;
    }
    case "custom_list": {
      const seen = new Uint8Array(total);
      const out: number[] = [];
      for (const r of spec.list) {
        const [a, b] = index.rangeToGlobal(r);
        for (let g = a; g <= b; g++) {
          if (!seen[g]) {
            seen[g] = 1;
            out.push(g);
          }
        }
      }
      if (out.length === 0) throw new EngineError("custom_list memorization order is empty");
      seq = Uint32Array.from(out);
      break;
    }
    default:
      throw new EngineError(`unknown memorization order kind: ${(spec as { kind: string }).kind}`);
  }

  const posOf = new Int32Array(total).fill(-1);
  for (let i = 0; i < seq.length; i++) posOf[seq[i]] = i;
  return { seq, posOf };
}

// ---------------------------------------------------------------------------
// Amount resolution (ENGINE_SEMANTICS §1)
// ---------------------------------------------------------------------------

/**
 * The Qurʾān's amount resolution. Corpus-aware callers use
 * `index.resolveAmount(...)`, which dispatches per corpus; this alias remains
 * for the Qurʾān-specific unit tests that have always called it directly.
 */
export const resolveAmount = resolveQuranAmount;

export function amountToMicropages(amount: QuranAmount, index: ContentIndex): number {
  const r = index.resolveAmount(amount);
  if (r.kind === "micropages") return r.micropages;
  const unitMicropages = index.uniformUnitMicropages;
  if (unitMicropages === null) {
    throw new EngineError(
      `unit ${amount.unit} is count-based and this corpus has nonuniform unit weights`,
    );
  }
  return r.count * unitMicropages;
}

// D-013: overshoot tolerance = 40% of a page.
const OVERSHOOT_LIMIT = 400_000;

/**
 * next_new (ENGINE_SEMANTICS §2, D-013/D-014).
 *
 * Walks `order.seq` from `cursorPos`, skipping ayahs in `excluded`
 * (declared/completed material), accumulating weight until the smallest
 * ayah-aligned prefix ≥ amount. Overshoot > 400_000 µp drops the final ayah
 * (never below 1 ayah). At a surah transition with the amount not yet
 * reached: bridge if the current surah's selected tail < amount/3, else
 * truncate at the boundary. Ayah-count amounts use ayah counts for both the
 * target and the ⅓ rule; they cannot overshoot.
 *
 * Returns the selected order positions (ascending walk order); empty when the
 * cursor is exhausted.
 */
export function selectNextNew(
  order: MemorizationOrder,
  index: ContentIndex,
  cursorPos: number,
  amount: ResolvedAmount,
  isSelectable: (g: number) => boolean,
): number[] {
  const seq = order.seq;
  const selected: number[] = [];
  let accWeight = 0;
  let accCount = 0;
  let currentSurah = -1;
  let surahSegWeight = 0; // weight/count selected within the current surah segment
  let surahSegCount = 0;

  const target = amount.kind === "micropages" ? amount.micropages : amount.count;
  const acc = () => (amount.kind === "micropages" ? accWeight : accCount);
  const segAcc = () => (amount.kind === "micropages" ? surahSegWeight : surahSegCount);

  for (let p = cursorPos; p < seq.length; p++) {
    const g = seq[p];
    if (!isSelectable(g)) continue;
    const surah = index.surahOf(g);
    if (currentSurah !== -1 && surah !== currentSurah) {
      // Surah boundary before reaching the amount (D-014):
      // bridge when the tail taken from the surah we are leaving < amount/3,
      // else truncate the selection at the boundary.
      //
      // Cross-multiplied, NOT `segAcc() >= idiv(target, 3)`. The floored form moves the
      // threshold down whenever `target % 3 != 0`, so the two disagree for every tail equal
      // to `floor(target/3)` — e.g. target 20: exact bridges a tail of 6 (6*3=18 < 20), the
      // floored form truncates it (6 >= 6). Swift (Engine.swift:581,604) and Kotlin
      // (Selection.kt:76,113) both use the exact form; TypeScript was the lone outlier, and
      // no existing golden happens to land in that band, which is why it went undetected.
      // ENGINE_SEMANTICS §2 states the rule as `tail < amount/3` with no rounding qualifier,
      // while §11.22 says "integer division" explicitly for the sibling rule — that silence
      // is meaningful drafting, so the exact reading governs.
      if (segAcc() * 3 >= target) return selected;
      surahSegWeight = 0;
      surahSegCount = 0;
    }
    currentSurah = surah;

    const w = index.weightOf(g);
    if (amount.kind === "micropages" && accWeight + w >= target) {
      // Reaching/passing the target with this ayah: overshoot check (D-013).
      const overshoot = accWeight + w - target;
      if (overshoot > OVERSHOOT_LIMIT && selected.length >= 1) return selected;
      selected.push(p);
      return selected;
    }
    selected.push(p);
    accWeight += w;
    accCount += 1;
    surahSegWeight += w;
    surahSegCount += 1;
    if (acc() >= target) return selected;
  }
  return selected;
}

// ---------------------------------------------------------------------------
// Unions & content construction
// ---------------------------------------------------------------------------

/** Sorted-unique global list → canonical coalesced ranges (mushaf order). */
export function globalsToContent(index: ContentIndex, globals: number[]): CanonicalRange[] {
  const sorted = [...globals].sort((a, b) => a - b);
  return index.globalsToRanges(sorted);
}

/**
 * Content range list ordered for serialization: ranges sorted by the
 * memorization-order position of their first ayah (ENGINE_PARITY §3
 * "in mushaf order of the plan's memorization order"); identical to canonical
 * order for mushaf_forward.
 */
export function orderContent(
  index: ContentIndex,
  order: MemorizationOrder,
  ranges: CanonicalRange[],
): CanonicalRange[] {
  return [...ranges].sort((a, b) => {
    const pa = order.posOf[index.toGlobal(a.surah, a.ayah_start)];
    const pb = order.posOf[index.toGlobal(b.surah, b.ayah_start)];
    if (pa !== pb) return pa - pb;
    return index.toGlobal(a.surah, a.ayah_start) - index.toGlobal(b.surah, b.ayah_start);
  });
}

// ---------------------------------------------------------------------------
// Near-equal µp split (prior_hifz_split / block_slice; ENGINE_SEMANTICS §5)
// ---------------------------------------------------------------------------

/**
 * Split a memorization-order-sorted list of globals into `parts` near-equal
 * slices: slice k = prefix(k) − prefix(k−1) where prefix(k) is the smallest
 * ayah-aligned prefix with weight ≥ k×total/parts (integer division, §11.22).
 * Empty slices are possible for tiny pools and are returned as empty arrays
 * at their positional index (callers must NOT compact them). `weightOf`
 * defaults to plain µp weights — both R-J1 distribution and block_slice use
 * plain µp (§11.22 as amended: weak-boost is rotation-frequency only); the
 * parameter exists as generic plumbing.
 */
export function splitNearEqual(
  index: ContentIndex,
  orderedGlobals: number[],
  parts: number,
  weightOf: (g: number) => number = (g) => index.weightOf(g),
): number[][] {
  if (parts < 1) throw new EngineError("split parts must be ≥ 1");
  let total = 0;
  for (const g of orderedGlobals) total += weightOf(g);
  const slices: number[][] = [];
  let i = 0;
  let cum = 0;
  for (let k = 1; k <= parts; k++) {
    const boundary = idiv(k * total, parts);
    const slice: number[] = [];
    while (i < orderedGlobals.length && (cum < boundary || k === parts)) {
      slice.push(orderedGlobals[i]);
      cum += weightOf(orderedGlobals[i]);
      i++;
      if (cum >= boundary && k < parts) break;
    }
    slices.push(slice);
  }
  return slices;
}

// ---------------------------------------------------------------------------
// Murājaʿah rotation slice (ENGINE_SEMANTICS §4, D-029)
// ---------------------------------------------------------------------------

export interface RotationSliceResult {
  /** selected pool order positions in walk order (may wrap). */
  positions: number[];
  /** order position just past the slice end (cursor advance target). */
  nextCursor: number;
}

/**
 * Day's rotation slice: smallest consecutive run of pool ayahs from the
 * rotation cursor with slicing-weight sum ≥ M (never split an ayah; wrap at
 * pool end; whole pool exactly once when pool slicing-weight ≤ M).
 *
 * `poolPositions` = memorization-order positions of pool members, ascending.
 * `slicingWeightAt(pos)` = weight or weight/2 for weak ayahs (D-012).
 */
export function rotationSlice(
  poolPositions: number[],
  rotationCursor: number,
  m: number,
  slicingWeightAt: (pos: number) => number,
  orderLength: number,
): RotationSliceResult | null {
  const n = poolPositions.length;
  if (n === 0 || m <= 0) return null;

  let poolTotal = 0;
  for (const p of poolPositions) poolTotal += slicingWeightAt(p);

  // First pool member at/after the cursor (wrap to pool start).
  let startIdx = lowerBound(poolPositions, rotationCursor);
  if (startIdx === n) startIdx = 0;

  const positions: number[] = [];
  let sum = 0;
  let idx = startIdx;
  const takeAll = poolTotal <= m;
  for (let taken = 0; taken < n; taken++) {
    const p = poolPositions[idx];
    positions.push(p);
    sum += slicingWeightAt(p);
    idx = (idx + 1) % n;
    if (!takeAll && sum >= m) break;
  }
  const last = positions[positions.length - 1];
  return { positions, nextCursor: (last + 1) % orderLength };
}

function lowerBound(arr: number[], x: number): number {
  let lo = 0, hi = arr.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (arr[mid] < x) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}
