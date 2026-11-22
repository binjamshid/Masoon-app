// Fixture runner CLI (ENGINE_PARITY §4/§5).
//
//   deno run --allow-read=<fixture-dir> backend/engine/fixture_runner.ts <fixture-dir>
//
// Reads <fixture-dir>/input.json (shape: ENGINE_PARITY §4.1), resolves the
// curriculum_definition and content-reference paths relative to the fixture
// dir, runs the generator, and prints the normalized task stream to stdout —
// nothing else.

import { ContentIndex } from "./content_index.ts";
import { loadExtraCurricula } from "./curriculum_set.ts";
import { loadCurriculum } from "./dsl.ts";
import { generate, PlanGenerationContext } from "./generator.ts";
import { loadPoemIndex } from "./poem_index.ts";
import { loadQuranIndex } from "./quran_index.ts";
import { serializeStream } from "./serialize.ts";
import { EngineError } from "./types.ts";

/**
 * ENGINE_PARITY §4.3: the corpus-KIND discriminator. Drawn from the same closed
 * vocabulary as `corpus-ref-v1.schema.json`'s `corpus_kind` and
 * `curriculum-v1.schema.json`'s `meta.corpora` (D-198) — the three are kept in
 * lockstep, so widening one without the others is exactly the drift this type
 * is here to make visible.
 */
type CorpusKind = "quran" | "poem";

interface CorpusRef {
  kind: CorpusKind;
  path: string; // relative to the fixture dir, like curriculum_definition
}

interface FixtureInput {
  fixture_id: string;
  plan_id: string;
  curriculum_definition: string; // path relative to the fixture dir
  /** ENGINE_PARITY §4.2 (optional): `[{slug, version, definition}]`, inline JSON. */
  extra_curricula?: unknown;
  /**
   * §4.3: `quran_ref` and `corpus_ref` are mutually exclusive and exactly one
   * is required. `"quran_ref": P` is precisely `{"kind":"quran","path":P}` —
   * retained, not deprecated, so every pre-§4.3 fixture keeps working untouched.
   */
  quran_ref?: string; // path relative to the fixture dir
  corpus_ref?: CorpusRef;
  today: string;
  window: { from: string; to: string };
  policy: PlanGenerationContext["policy"];
  starting_state: PlanGenerationContext["starting_state"];
  calendar: PlanGenerationContext["calendar"];
  event_log: PlanGenerationContext["event_log"];
}

function resolveRelative(baseDir: string, rel: string): string {
  if (rel.startsWith("/")) return rel;
  const parts = baseDir.replace(/\/+$/, "").split("/");
  for (const seg of rel.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") parts.pop();
    else parts.push(seg);
  }
  return parts.join("/");
}

/**
 * ENGINE_PARITY §4.1 says reference paths are relative to the fixture dir;
 * legacy inputs can also resolve from the fixture-family directory. Accept
 * both: fixture directory first, then its parent, subject to read permissions.
 */
function readRelative(fixtureDir: string, rel: string): string {
  const primary = resolveRelative(fixtureDir, rel);
  try {
    return Deno.readTextFileSync(primary);
  } catch (err) {
    if (err instanceof Deno.errors.NotFound) {
      return Deno.readTextFileSync(resolveRelative(resolveRelative(fixtureDir, ".."), rel));
    }
    throw err;
  }
}

/**
 * ENGINE_PARITY §4.3 — resolve the fixture's single content-index slot.
 *
 * Both spellings are normalized to `{kind, path}` first, so the mutual-exclusion
 * rule is enforced in one place and `quran_ref` is provably just the `quran`
 * kind rather than a parallel code path that could drift from it.
 *
 * Any kind with no index implementation fails LOUDLY and by name. It must never
 * fall back to `QuranIndex` — a non-Qurʾān corpus read through Qurʾānic
 * page-density weights would produce a plausible-looking stream that is wrong
 * in every µp, which is far worse than not running at all. The `switch` below
 * is exhaustive over `CorpusKind`, so widening that union without adding an
 * index here is a compile error rather than a silent fallthrough.
 */
function loadContentIndex(fixtureDir: string, input: FixtureInput): ContentIndex {
  const hasQuranRef = input.quran_ref !== undefined;
  const hasCorpusRef = input.corpus_ref !== undefined;
  if (hasQuranRef === hasCorpusRef) {
    throw new EngineError(
      "fixture input: exactly one of `quran_ref` / `corpus_ref` is required " +
        `(got ${hasQuranRef ? "both" : "neither"})`,
    );
  }
  const ref: CorpusRef = hasQuranRef
    ? { kind: "quran", path: input.quran_ref! }
    : input.corpus_ref!;
  const doc = JSON.parse(readRelative(fixtureDir, ref.path));

  if (ref.kind === "quran") return loadQuranIndex(doc);

  // Every non-Qurʾān kind reads a corpus-ref-v1 document, which carries its own
  // `corpus_kind`. Disagreement is a hard error rather than a preference for
  // either side: one of the two is wrong and the fixture must say which.
  const declared = (doc as { corpus_kind?: unknown })?.corpus_kind;
  if (declared !== ref.kind) {
    throw new EngineError(
      `fixture input: corpus_ref.kind "${ref.kind}" disagrees with the ` +
        `document's own corpus_kind ${JSON.stringify(declared)}`,
    );
  }
  switch (ref.kind) {
    case "poem":
      return loadPoemIndex(doc);
    default: {
      // Unreachable while `CorpusKind` is exhausted above; kept so a widened
      // union fails here by name instead of silently reaching for QuranIndex.
      const unhandled: never = ref.kind;
      throw new EngineError(
        `fixture input: corpus kind ${JSON.stringify(unhandled)} has no ` +
          "ContentIndex implementation in the TypeScript engine",
      );
    }
  }
}

export function runFixture(fixtureDir: string): string {
  const input = JSON.parse(readRelative(fixtureDir, "input.json")) as FixtureInput;
  const curriculum = loadCurriculum(JSON.parse(readRelative(fixtureDir, input.curriculum_definition)));
  const quran = loadContentIndex(fixtureDir, input);
  const ctx: PlanGenerationContext = {
    plan_id: input.plan_id,
    curriculum,
    curricula: loadExtraCurricula(input.extra_curricula),
    quran,
    policy: input.policy,
    starting_state: input.starting_state,
    calendar: input.calendar,
    event_log: input.event_log ?? [],
    today: input.today,
  };
  return serializeStream(generate(ctx, input.window));
}

if (import.meta.main) {
  const dir = Deno.args[0];
  if (!dir) {
    console.error("usage: fixture_runner.ts <fixture-dir>");
    Deno.exit(2);
  }
  try {
    const stream = runFixture(dir);
    // Stream already ends with exactly one \n; write raw to avoid an extra one.
    Deno.stdout.writeSync(new TextEncoder().encode(stream));
  } catch (err) {
    if (err instanceof EngineError) {
      console.error(`engine error: ${err.message}`);
      Deno.exit(1);
    }
    throw err;
  }
}
