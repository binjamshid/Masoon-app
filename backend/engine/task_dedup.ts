import { TaskFlag, TaskInstance } from "./types.ts";
import { uuid5 } from "./uuid5.ts";

export interface TaskDeduplicationResult {
  output: TaskInstance[];
  /** One entry per pre-dedup task, with merged UIDs for state advancement. */
  state_tasks: TaskInstance[];
}

export function deduplicateExactExecution(tasks: TaskInstance[]): TaskDeduplicationResult {
  const groups = new Map<string, number[]>();
  for (let index = 0; index < tasks.length; index++) {
    const key = executionKey(tasks[index]);
    const indices = groups.get(key) ?? [];
    indices.push(index);
    groups.set(key, indices);
  }
  const output: TaskInstance[] = [];
  const state_tasks = tasks.slice();
  for (const [key, indices] of groups) {
    const first = tasks[indices[0]];
    if (indices.length === 1) {
      output.push(first);
      continue;
    }
    const group = indices.map((index) => tasks[index]);
    const origins = [...new Set(group.map((task) => task.origin_rule_id))].sort();
    const baseFlags = [...new Set(group.flatMap((task) => task.flags)
      .filter((flag) => !flag.startsWith("source_rule:")))];
    const flags: TaskFlag[] = [...new Set([
      ...baseFlags,
      ...origins.map((origin) => `source_rule:${origin}` as TaskFlag),
    ])].sort();
    const uid = uuid5(first.plan_id, `exact_execution|${first.date}|${key}`);
    output.push({
      ...first,
      task_uid: uid,
      origin_rule_id: origins.join("+"),
      estimated_minutes: Math.max(...group.map((task) => task.estimated_minutes)),
      flags,
    });
    for (const index of indices) state_tasks[index] = { ...tasks[index], task_uid: uid };
  }
  return { output, state_tasks };
}

function executionKey(task: TaskInstance): string {
  const values = [
    task.content.map((range) => `${range.surah}:${range.ayah_start}-${range.ayah_end}`).join(","),
    task.type,
    optional(task.target_repetitions), optional(task.spacing_minutes), optional(task.listen_count),
    canonicalJSON(task.evidence),
    task.window ? `${task.window.opens_on}..${task.window.closes_on}` : "nil",
    task.flags.filter((flag) => !flag.startsWith("source_rule:")).sort().join(","),
  ];
  return values.map((value) => `${new TextEncoder().encode(value).length}:${value}`).join("|");
}

function optional(value: number | undefined): string {
  return value === undefined ? "nil" : String(value);
}

function canonicalJSON(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  const object = value as Record<string, unknown>;
  return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${canonicalJSON(object[key])}`).join(",")}}`;
}
