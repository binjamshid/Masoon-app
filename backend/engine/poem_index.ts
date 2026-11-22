// Poem corpus reference index — the second `ContentIndex` implementation
// (Swift parity: `MasoonDomain/PoemIndex.swift`; Kotlin parity:
// `masoon/domain/PoemIndex.kt`), proving the curriculum engine generalizes past
// the Qurʾān.
//
// Parses any schema-valid `corpus-ref-v1` document
// (`contracts/json-schema/corpus-ref-v1.schema.json`) into the same
// global-position / µp-weight shape `QuranIndex` exposes, over a corpus of
// titled "works" made of "atomic units" (a poem collection's bayt) rather than
// surahs and ayahs.
//
// Counts, titles, and the recension come from the supplied reference document.

import { ContentIndex, ResolvedAmount } from "./content_index.ts";
import {
  CanonicalPosition,
  CanonicalRange,
  decimalTimesUnit,
  decimalToInt,
  EngineError,
  MICROPAGES_PER_PAGE,
} from "./types.ts";

/**
 * Load-bearing batch-wide invariants, declared `const` by corpus-ref-v1 and
 * re-checked at parse time rather than trusted: 10 abyāt = 1 page, so one
 * atomic unit is 1_000_000 / 10 = 100_000 µp. The two constants are the same
 * invariant expressed twice and must never diverge.
 */
export const UNITS_PER_PAGE = 10;
export const UNIT_MICROPAGES = MICROPAGES_PER_PAGE / UNITS_PER_PAGE; // 100_000

export interface PoemWork {
  /** 1-based reference document ordering (`works[].no`). */
  no: number;
  slug: string;
  unitCount: number;
  titleAr: string;
  titleEn?: string;
}

export class PoemIndex implements ContentIndex {
  readonly corpusId: string;
  /** Which curriculum-v1 `meta.corpora` KIND token this corpus instantiates (D-198). */
  readonly corpusKind: string;
  readonly titleAr: string;
  readonly titleEn?: string;
  readonly recension: string;
  readonly sourceSha256: string;
  readonly atomicUnit: string;
  readonly boundaryKind: string;
  /** In `no` order. */
  readonly works: readonly PoemWork[];

  readonly totalAyahs: number;
  /** global unit id → index into `works`. */
  private readonly workIndexOfG: Int32Array;
  /** global unit id → 1-based unit-within-work number. */
  private readonly unitNumberOfG: Int32Array;
  /** `works` index (0-based) → global id of its first unit. */
  private readonly workStartG: Int32Array;
  /** `works[].no` → 0-based index into `works`. */
  private readonly indexOfWorkNo = new Map<number, number>();

  constructor(doc: unknown) {
    if (typeof doc !== "object" || doc === null) throw new PoemIndexError("not an object");
    const root = doc as Record<string, unknown>;

    const str = (key: string): string => {
      const v = root[key];
      if (typeof v !== "string" || v.length === 0) throw new PoemIndexError(`${key} missing`);
      return v;
    };

    this.corpusId = str("corpus_id");
    this.corpusKind = str("corpus_kind");
    // Required, not optional-with-a-fallback: the only fallback available would
    // be echoing `corpus_id` at the learner, and a corpus that cannot be named
    // cannot honestly be offered as a choice (D-198).
    const title = root["title"];
    if (typeof title !== "object" || title === null) throw new PoemIndexError("title missing");
    const titleAr = (title as Record<string, unknown>)["ar"];
    if (typeof titleAr !== "string" || titleAr.length === 0) throw new PoemIndexError("title.ar missing");
    this.titleAr = titleAr;
    const titleEn = (title as Record<string, unknown>)["en"];
    this.titleEn = typeof titleEn === "string" ? titleEn : undefined;

    this.recension = str("recension");
    this.sourceSha256 = str("source_sha256");
    this.atomicUnit = str("atomic_unit");
    this.boundaryKind = str("boundary_kind");

    // Re-checked here rather than trusting the document's provenance: a
    // malformed or tampered corpus-ref must not smuggle in a different
    // per-unit size, which would silently rescale every estimate in the plan.
    if (root["units_per_page"] !== UNITS_PER_PAGE) {
      throw new PoemIndexError(`units_per_page must be ${UNITS_PER_PAGE}`);
    }
    if (root["unit_micropages"] !== UNIT_MICROPAGES) {
      throw new PoemIndexError(`unit_micropages must be ${UNIT_MICROPAGES}`);
    }

    const worksRaw = root["works"];
    if (!Array.isArray(worksRaw) || worksRaw.length === 0) {
      throw new PoemIndexError("works must be a non-empty array");
    }
    const works = worksRaw.map(parseWork).sort((a, b) => a.no - b.no);

    // The build tool's cross-field check already rejects duplicates before a
    // document is written; re-validated because this index must not trust its
    // input file blindly.
    const seenNo = new Set<number>();
    const seenSlug = new Set<string>();
    for (const w of works) {
      if (seenNo.has(w.no)) throw new PoemIndexError(`duplicate works[].no = ${w.no}`);
      if (seenSlug.has(w.slug)) throw new PoemIndexError(`duplicate works[].slug = ${JSON.stringify(w.slug)}`);
      seenNo.add(w.no);
      seenSlug.add(w.slug);
    }
    this.works = works;

    this.workStartG = new Int32Array(works.length);
    let running = 0;
    for (let i = 0; i < works.length; i++) {
      this.workStartG[i] = running;
      this.indexOfWorkNo.set(works[i].no, i);
      running += works[i].unitCount;
    }
    this.totalAyahs = running;

    this.workIndexOfG = new Int32Array(running);
    this.unitNumberOfG = new Int32Array(running);
    let g = 0;
    for (let i = 0; i < works.length; i++) {
      for (let u = 1; u <= works[i].unitCount; u++) {
        this.workIndexOfG[g] = i;
        this.unitNumberOfG[g] = u;
        g++;
      }
    }
  }

  // ---- ContentIndex conformance -------------------------------------------

  /** Global 0-based unit id for a (work `no`, 1-based unit) pair. */
  toGlobal(work: number, unit: number): number {
    const i = this.indexOfWorkNo.get(work);
    if (i === undefined) throw new EngineError(`invalid work ${work}`);
    if (!Number.isInteger(unit) || unit < 1 || unit > this.works[i].unitCount) {
      throw new EngineError(`invalid unit ${work}:${unit}`);
    }
    return this.workStartG[i] + unit - 1;
  }

  positionOf(g: number): CanonicalPosition {
    if (g < 0 || g >= this.totalAyahs) throw new EngineError(`global unit index out of range: ${g}`);
    return { surah: this.works[this.workIndexOfG[g]].no, ayah: this.unitNumberOfG[g] };
  }

  surahOf(g: number): number {
    if (g < 0 || g >= this.totalAyahs) throw new EngineError(`global unit index out of range: ${g}`);
    return this.works[this.workIndexOfG[g]].no;
  }

  /**
   * Every atomic unit weighs the same — unlike a Qurʾānic ayah, whose weight
   * varies with how many ayahs share its mushaf page.
   */
  weightOf(_g: number): number {
    return UNIT_MICROPAGES;
  }

  /**
   * `corpus_block` / `work_boundary`: for this stage both map to per-work
   * boundaries — one work is one boundary block. A poem corpus has no
   * juzʾ-style sub-work grouping.
   */
  get juzCount(): number {
    return this.works.length;
  }

  juzOf(g: number): number {
    if (g < 0 || g >= this.totalAyahs) throw new EngineError(`global unit index out of range: ${g}`);
    return this.workIndexOfG[g] + 1;
  }

  /** Half-open `[start, end)`, matching `QuranIndex.juzGlobalRange`. */
  juzGlobalRange(j: number): [number, number] {
    if (!Number.isInteger(j) || j < 1 || j > this.works.length) throw new EngineError(`invalid boundary block ${j}`);
    const start = this.workStartG[j - 1];
    return [start, start + this.works[j - 1].unitCount];
  }

  rangeToGlobal(r: CanonicalRange): [number, number] {
    const a = this.toGlobal(r.surah, r.ayah_start);
    const b = this.toGlobal(r.surah, r.ayah_end);
    if (b < a) throw new EngineError(`invalid range ${r.surah}:${r.ayah_start}-${r.ayah_end}`);
    return [a, b];
  }

  /** Coalesce contiguous runs, splitting at work boundaries. */
  globalsToRanges(sortedGlobals: readonly number[]): CanonicalRange[] {
    const out: CanonicalRange[] = [];
    let runStart = -1;
    let prev = -2;
    const flush = (endG: number) => {
      let s = runStart;
      while (s <= endG) {
        const i = this.workIndexOfG[s];
        const workEndG = this.workStartG[i] + this.works[i].unitCount - 1;
        const e = Math.min(endG, workEndG);
        out.push({
          surah: this.works[i].no,
          ayah_start: this.unitNumberOfG[s],
          ayah_end: this.unitNumberOfG[e],
        });
        s = e + 1;
      }
    };
    for (const g of sortedGlobals) {
      if (g === prev) continue;
      if (g !== prev + 1) {
        if (runStart >= 0) flush(prev);
        runStart = g;
      }
      prev = g;
    }
    if (runStart >= 0) flush(prev);
    return out;
  }

  /** Fixed-weight corpus: every atomic unit has exactly this µp size. */
  readonly uniformUnitMicropages = UNIT_MICROPAGES;

  /**
   * Deliberately narrower than `QuranIndex`: only the corpus-invariant `page`
   * unit and the count-based `ayah`/`custom` units resolve. `line`/`juz`/
   * `hizb`/`rub` have no corpus-ref-v1 analogue for a poem collection, so they
   * are an error rather than a silent Qurʾānic-sized fallback.
   */
  resolveAmount(amount: { unit: string; value: string | number }): ResolvedAmount {
    switch (amount.unit) {
      case "ayah":
      case "custom": {
        const count = decimalToInt(amount.value);
        if (count < 1) throw new EngineError("unit-count amount must be ≥ 1");
        return { kind: "ayah_count", count };
      }
      case "page": {
        const mp = decimalTimesUnit(amount.value, MICROPAGES_PER_PAGE);
        if (mp < 1) throw new EngineError("amount resolves to zero micropages");
        return { kind: "micropages", micropages: mp };
      }
      default:
        throw new EngineError(
          `amount unit "${amount.unit}" has no analogue in corpus "${this.corpusId}" ` +
            `(kind "${this.corpusKind}"); only page/ayah/custom resolve`,
        );
    }
  }

  /** The document's own provenance checksum; never re-derived here. */
  get refChecksum(): string {
    return this.sourceSha256;
  }
}

function parseWork(o: unknown): PoemWork {
  if (typeof o !== "object" || o === null) throw new PoemIndexError("bad entry in works[]");
  const w = o as Record<string, unknown>;
  const no = w["no"];
  const slug = w["slug"];
  const unitCount = w["unit_count"];
  const title = w["title"] as Record<string, unknown> | undefined;
  const titleAr = title?.["ar"];
  if (
    !Number.isInteger(no) || (no as number) < 1 ||
    typeof slug !== "string" || slug.length === 0 ||
    !Number.isInteger(unitCount) || (unitCount as number) < 1 ||
    typeof titleAr !== "string" || titleAr.length === 0
  ) {
    throw new PoemIndexError("bad entry in works[]");
  }
  const titleEn = title?.["en"];
  return {
    no: no as number,
    slug,
    unitCount: unitCount as number,
    titleAr,
    titleEn: typeof titleEn === "string" ? titleEn : undefined,
  };
}

/** A corpus-ref document that cannot be trusted as an index. */
export class PoemIndexError extends EngineError {
  constructor(message: string) {
    super(`corpus-ref error: ${message}`);
    this.name = "PoemIndexError";
  }
}

export function loadPoemIndex(json: unknown): PoemIndex {
  return new PoemIndex(json);
}
