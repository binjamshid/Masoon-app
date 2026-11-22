// Corpus-agnostic content index (Batch 3 Stage 2; Swift parity:
// `MasoonDomain/ContentIndex.swift`, Kotlin parity: `masoon/domain/ContentIndex.kt`).
//
// The engine's arithmetic is defined over three things only: a total unit
// count, a µp weight per unit, and a boundary partition. Nothing in the day
// loop is Qurʾān-specific. The interface lets `QuranIndex` and `PoemIndex`
// run through the same generator.
//
// VOCABULARY NOTE. The wire format, the DSL, and this interface all keep the
// Qurʾānic member names (`surah`/`ayah`, `juz`) even for a poem corpus, where
// they mean work/unit and work-boundary. That is deliberate: `ENGINE_PARITY §3`
// pins the stream field names, and renaming them here would fork the
// serializer per corpus for no behavioural gain. Swift and Kotlin made the
// opposite choice (`work`/`unit`) because their `CanonicalPosition` is a domain
// type they own; TypeScript's is the wire shape itself.

import { CanonicalPosition, CanonicalRange, decimalTimesUnit, decimalToInt, EngineError, MICROPAGES, QuranAmount } from "./types.ts";

/**
 * An amount resolved against a corpus: either an absolute µp size, or a count
 * of atomic units (which has no fixed µp size until the units are known).
 * Mirrors Swift/Kotlin `AmountResolution`; their third case, `Unsupported`, is
 * a thrown `EngineError` here, matching how TypeScript already reports an
 * unusable unit.
 */
export type ResolvedAmount =
  | { kind: "micropages"; micropages: number }
  | { kind: "ayah_count"; count: number };

export interface ContentIndex {
  /** Total atomic units in the corpus (ayahs / abyāt). */
  readonly totalAyahs: number;

  /** Global 0-based unit id for a (work, unit) pair. Throws when out of range. */
  toGlobal(work: number, unit: number): number;
  positionOf(g: number): CanonicalPosition;
  /** The work (surah / poem) a global unit belongs to, by its canonical number. */
  surahOf(g: number): number;
  /** µp weight of one unit (ENGINE_SEMANTICS §1). */
  weightOf(g: number): number;

  /**
   * Boundary partition — juzʾ for the Qurʾān, one whole work for a poem
   * collection. `juzGlobalRange` is HALF-OPEN `[start, end)`, the convention
   * the generator's boundary bookkeeping already assumes.
   */
  readonly juzCount: number;
  juzOf(g: number): number;
  juzGlobalRange(j: number): [number, number];

  rangeToGlobal(r: CanonicalRange): [number, number];
  globalsToRanges(sortedGlobals: readonly number[]): CanonicalRange[];

  /** Exact µp size of one atomic unit when every unit has the same weight. */
  readonly uniformUnitMicropages: number | null;

  /**
   * Corpus-aware amount resolution (Swift/Kotlin `amountMicroPages`). A unit
   * with no analogue in this corpus throws rather than silently resolving —
   * `juz` means nothing in a poem collection, and quietly giving it the
   * Qurʾānic 20-page size would yield a plausible but wholly wrong stream.
   */
  resolveAmount(amount: QuranAmount): ResolvedAmount;
}

/**
 * The Qurʾān's amount resolution, unchanged from the original free function in
 * `selectors.ts` (which still re-exports it under that name). Lives here so
 * `QuranIndex` can call it without importing `selectors.ts`, which imports back.
 */
export function resolveQuranAmount(amount: QuranAmount): ResolvedAmount {
  if (amount.unit === "ayah") {
    const count = decimalToInt(amount.value);
    if (count < 1) throw new EngineError("ayah amount must be ≥ 1");
    return { kind: "ayah_count", count };
  }
  const unitMp = MICROPAGES[amount.unit];
  if (unitMp === undefined) throw new EngineError(`unsupported amount unit: ${amount.unit}`);
  const mp = decimalTimesUnit(amount.value, unitMp);
  if (mp < 1) throw new EngineError("amount resolves to zero micropages");
  return { kind: "micropages", micropages: mp };
}
