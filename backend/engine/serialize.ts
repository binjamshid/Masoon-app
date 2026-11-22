// Normalized task-stream serializer (ENGINE_PARITY §3 — exact field order,
// separators, #STATE checkpoint line, single trailing newline).
//
//   date|day_class|session|ordering|type|origin_rule_id|content|reps|
//   spacing_min|listen_count|window|est_min|evidence|flags|task_uid
//
// Field values never contain `|` by construction; no escaping.

import { GenerationResult } from "./generator.ts";
import { EngineError, EvidenceSpec, TaskInstance } from "./types.ts";

export function serializeEvidence(spec: EvidenceSpec | null): string {
  if (spec === null) return "";
  switch (spec.kind) {
    case "self_check":
      return "self";
    case "timer":
      return `timer:${spec.min_seconds}`;
    case "counter":
      return `counter:${spec.target}`;
    case "teacher_verification":
      return "teacher";
    case "form":
      return `form:${spec.form_version_id}`;
    case "composite":
      return `composite(${spec.parts.map(serializeEvidence).join("+")})`;
    default:
      throw new EngineError(`unknown evidence kind: ${JSON.stringify(spec)}`);
  }
}

export function serializeContent(task: TaskInstance): string {
  return task.content.map((r) => `${r.surah}:${r.ayah_start}-${r.ayah_end}`).join("+");
}

export function serializeTaskLine(task: TaskInstance): string {
  const fields = [
    task.date,
    task.day_class,
    task.session,
    String(task.ordering),
    task.type,
    task.origin_rule_id,
    serializeContent(task),
    task.target_repetitions !== undefined ? String(task.target_repetitions) : "",
    task.spacing_minutes !== undefined ? String(task.spacing_minutes) : "",
    task.listen_count !== undefined ? String(task.listen_count) : "",
    task.window ? `${task.window.opens_on}..${task.window.closes_on}` : "",
    String(task.estimated_minutes),
    serializeEvidence(task.evidence),
    [...task.flags].sort().join(","),
    task.task_uid,
  ];
  for (const f of fields) {
    if (f.includes("|") || f.includes("\n")) throw new EngineError(`field contains reserved character: ${f}`);
  }
  return fields.join("|");
}

export function serializeStateLine(result: GenerationResult): string {
  const s = result.state;
  const cursor = s.cursor ? `${s.cursor.surah}:${s.cursor.ayah}` : "-";
  return `#STATE|cursor=${cursor}|juz_done=${s.juz_completed_count}|cycle_weeks=${s.cycle_weeks}|debt_new=${s.debt_new_ranges}|status=${s.status}`;
}

/** Full normalized stream: task lines, #STATE line, exactly one trailing \n. */
export function serializeStream(result: GenerationResult): string {
  const lines = result.tasks.map(serializeTaskLine);
  lines.push(serializeStateLine(result));
  return lines.join("\n") + "\n";
}
