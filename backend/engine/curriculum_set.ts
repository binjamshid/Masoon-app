// Curriculum set & per-date resolution (D-054, ENGINE_PARITY §4.2).
//
// A plan normally runs one curriculum for its whole life. A plan that has been
// upgraded (`plan.curriculum_upgraded`) runs a DIFFERENT compiled curriculum
// from the switch's `effective_from` onward, so generation must resolve the
// curriculum per date rather than once per run. This mirrors Swift's
// `CurriculumSet` (GenerationContext.swift) exactly.

import { CompiledCurriculum, loadCurriculum } from "./dsl.ts";
import { CurriculumChange, FoldResult } from "./fold.ts";
import { EngineError, EpochDay } from "./types.ts";

/** `"{slug}@{version}"` — the key `FoldedEvents.curriculumTimeline` resolves against. */
export function curriculumKey(slug: string, version: string): string {
  return `${slug}@${version}`;
}

export interface CurriculumSet {
  base: CompiledCurriculum;
  /** Keyed by `"{slug}@{version}"`. Empty for every plan that never upgraded. */
  byKey: Record<string, CompiledCurriculum>;
}

/**
 * PC-4: the curriculum active on `day` — the greatest `effectiveFrom ≤ day`
 * (ties broken by fold order, later wins), else `base`. A timeline entry naming
 * a `slug@version` this run was never given falls back to `base` rather than
 * throwing: a plan's event log may reference a curriculum the caller did not
 * load, and a hard failure there would take down the whole generation.
 */
export function resolveCurriculum(
  set: CurriculumSet,
  change: CurriculumChange | null,
): CompiledCurriculum {
  if (change === null) return set.base;
  return set.byKey[curriculumKey(change.slug, change.version)] ?? set.base;
}

/** Convenience: fold + day → curriculum, for callers holding a `FoldResult`. */
export function curriculumOn(set: CurriculumSet, fold: FoldResult, day: EpochDay): CompiledCurriculum {
  let best: CurriculumChange | null = null;
  for (const entry of fold.curriculumTimeline) {
    if (entry.effectiveFrom <= day && (best === null || entry.effectiveFrom >= best.effectiveFrom)) best = entry;
  }
  return resolveCurriculum(set, best);
}

/**
 * ENGINE_PARITY §4.2: an optional `extra_curricula` array on a fixture's
 * `input.json`, each entry `{slug, version, definition}` where `definition` is
 * full inline curriculum-v1 JSON (not a path). Omitting it is identical to `[]`.
 */
export function loadExtraCurricula(extras: unknown): Record<string, CompiledCurriculum> {
  const byKey: Record<string, CompiledCurriculum> = {};
  if (extras === undefined || extras === null) return byKey;
  if (!Array.isArray(extras)) throw new EngineError("extra_curricula must be an array");
  for (const item of extras) {
    if (typeof item !== "object" || item === null) throw new EngineError("extra_curricula item is not an object");
    const e = item as { slug?: unknown; version?: unknown; definition?: unknown };
    if (typeof e.slug !== "string" || typeof e.version !== "string" || e.definition === undefined) {
      throw new EngineError("extra_curricula item missing slug/version/definition");
    }
    byKey[curriculumKey(e.slug, e.version)] = loadCurriculum(e.definition);
  }
  return byKey;
}
