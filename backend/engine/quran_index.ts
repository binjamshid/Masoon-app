// Quran reference index — loads supplied reference markers
// into per-ayah juz/rub/page projections and micropage weights.
//
// ENGINE_SEMANTICS §1: for ayah a on Madinah-15 page p, weight(a) = 1_000_000 / n_p
// (integer division), where n_p = count of ayahs whose projection page = p.
// Juz/hizb/rub/page boundaries come exclusively from this reference data; the
// engine never hardcodes boundary positions.

import { ContentIndex, ResolvedAmount, resolveQuranAmount } from "./content_index.ts";
import {
  CanonicalPosition,
  CanonicalRange,
  EngineError,
  idiv,
  MICROPAGES_PER_PAGE,
  QuranAmount,
} from "./types.ts";

type Marker = [number, number, number]; // [unit_no, surah, ayah]

export interface QuranRefData {
  surah_ayah_counts: number[]; // 114 ints
  juz_starts: Marker[]; // 30
  page_starts: Marker[]; // 604 (Madinah-15)
  rub_starts: Marker[]; // 240
  edition?: string;
  riwayah?: string;
  source?: string;
}

export class QuranIndex implements ContentIndex {
  readonly totalAyahs: number;
  readonly surahAyahCounts: readonly number[];
  /** global index of ayah 1 of each surah (0-based). */
  private readonly surahOffsets: Int32Array;
  private readonly pageOfG: Int32Array;
  private readonly juzOfG: Int32Array;
  private readonly rubOfG: Int32Array;
  /** micropage weight per ayah (integer). */
  private readonly weightOfG: Int32Array;
  readonly juzCount: number;
  readonly pageCount: number;
  /** global start index of each juz (juz are contiguous in canonical order). */
  private readonly juzStartG: Int32Array;

  constructor(data: QuranRefData) {
    const counts = data.surah_ayah_counts;
    if (!Array.isArray(counts) || counts.length !== 114) {
      throw new EngineError("quran-ref: surah_ayah_counts must have 114 entries");
    }
    this.surahAyahCounts = counts;
    this.surahOffsets = new Int32Array(114);
    let total = 0;
    for (let s = 0; s < 114; s++) {
      this.surahOffsets[s] = total;
      const c = counts[s];
      if (!Number.isInteger(c) || c < 1) throw new EngineError(`quran-ref: bad ayah count for surah ${s + 1}`);
      total += c;
    }
    this.totalAyahs = total;

    this.pageOfG = this.assignUnits(data.page_starts, "page_starts");
    this.juzOfG = this.assignUnits(data.juz_starts, "juz_starts");
    this.rubOfG = this.assignUnits(data.rub_starts, "rub_starts");
    this.juzCount = data.juz_starts.length;
    this.pageCount = data.page_starts.length;

    // Per-page ayah counts → weights.
    const perPage = new Int32Array(this.pageCount + 1);
    for (let g = 0; g < total; g++) perPage[this.pageOfG[g]]++;
    this.weightOfG = new Int32Array(total);
    for (let g = 0; g < total; g++) {
      this.weightOfG[g] = idiv(MICROPAGES_PER_PAGE, perPage[this.pageOfG[g]]);
    }

    this.juzStartG = new Int32Array(this.juzCount);
    for (let i = 0; i < data.juz_starts.length; i++) {
      const [no, surah, ayah] = data.juz_starts[i];
      this.juzStartG[no - 1] = this.toGlobal(surah, ayah);
    }
  }

  private assignUnits(markers: Marker[], name: string): Int32Array {
    if (!Array.isArray(markers) || markers.length === 0) {
      throw new EngineError(`quran-ref: missing ${name}`);
    }
    const out = new Int32Array(this.totalAyahs);
    // Markers are in mushaf order with unit numbers 1..N.
    let prevG = -1;
    for (let i = 0; i < markers.length; i++) {
      const [no, surah, ayah] = markers[i];
      if (no !== i + 1) throw new EngineError(`quran-ref: ${name} unit numbers must be consecutive from 1`);
      const g = this.toGlobal(surah, ayah);
      if (g <= prevG) throw new EngineError(`quran-ref: ${name} markers not in mushaf order`);
      const end = i + 1 < markers.length
        ? this.toGlobal(markers[i + 1][1], markers[i + 1][2])
        : this.totalAyahs;
      for (let k = g; k < end; k++) out[k] = no;
      prevG = g;
    }
    if (this.toGlobal(markers[0][1], markers[0][2]) !== 0) {
      throw new EngineError(`quran-ref: ${name} must start at 1:1`);
    }
    return out;
  }

  toGlobal(surah: number, ayah: number): number {
    if (!Number.isInteger(surah) || surah < 1 || surah > 114) {
      throw new EngineError(`invalid surah ${surah}`);
    }
    const count = this.surahAyahCounts[surah - 1];
    if (!Number.isInteger(ayah) || ayah < 1 || ayah > count) {
      throw new EngineError(`invalid ayah ${surah}:${ayah}`);
    }
    return this.surahOffsets[surah - 1] + ayah - 1;
  }

  positionOf(g: number): CanonicalPosition {
    if (g < 0 || g >= this.totalAyahs) throw new EngineError(`global ayah index out of range: ${g}`);
    // Binary search over surahOffsets.
    let lo = 0, hi = 113;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (this.surahOffsets[mid] <= g) lo = mid;
      else hi = mid - 1;
    }
    return { surah: lo + 1, ayah: g - this.surahOffsets[lo] + 1 };
  }

  surahOf(g: number): number {
    return this.positionOf(g).surah;
  }

  pageOf(g: number): number {
    return this.pageOfG[g];
  }

  juzOf(g: number): number {
    return this.juzOfG[g];
  }

  rubOf(g: number): number {
    return this.rubOfG[g];
  }

  weightOf(g: number): number {
    return this.weightOfG[g];
  }

  /** [startG, endG) global range of juz j (1-based). */
  juzGlobalRange(j: number): [number, number] {
    if (j < 1 || j > this.juzCount) throw new EngineError(`invalid juz ${j}`);
    const start = this.juzStartG[j - 1];
    const end = j < this.juzCount ? this.juzStartG[j] : this.totalAyahs;
    return [start, end];
  }

  /** Qurʾān ayah weights vary by page density, so a count has no exact µp size. */
  readonly uniformUnitMicropages = null;

  /** ContentIndex: the Qurʾān resolves every unit the DSL can name. */
  resolveAmount(amount: QuranAmount): ResolvedAmount {
    return resolveQuranAmount(amount);
  }

  /** Expand a CanonicalRange into global indices [startG..endG]. */
  rangeToGlobal(r: CanonicalRange): [number, number] {
    const a = this.toGlobal(r.surah, r.ayah_start);
    const b = this.toGlobal(r.surah, r.ayah_end);
    if (b < a) throw new EngineError(`invalid range ${r.surah}:${r.ayah_start}-${r.ayah_end}`);
    return [a, b];
  }

  /**
   * Build canonical single-surah ranges from a sorted, deduplicated list of
   * global indices: coalesce contiguous runs, split at surah boundaries.
   */
  globalsToRanges(sortedGlobals: readonly number[]): CanonicalRange[] {
    const out: CanonicalRange[] = [];
    let runStart = -1;
    let prev = -2;
    const flush = (endG: number) => {
      // Split run [runStart..endG] at surah boundaries.
      let s = runStart;
      while (s <= endG) {
        const pos = this.positionOf(s);
        const surahEndG = this.surahOffsets[pos.surah - 1] + this.surahAyahCounts[pos.surah - 1] - 1;
        const e = Math.min(endG, surahEndG);
        out.push({ surah: pos.surah, ayah_start: pos.ayah, ayah_end: this.positionOf(e).ayah });
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
}

export function loadQuranIndex(json: unknown): QuranIndex {
  if (typeof json !== "object" || json === null) throw new EngineError("quran-ref: not an object");
  return new QuranIndex(json as QuranRefData);
}
