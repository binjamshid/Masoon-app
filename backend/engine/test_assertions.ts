// Dependency-free assertions for the focused engine tests.

export function assert(cond: boolean, msg = "assertion failed"): void {
  if (!cond) throw new Error(msg);
}

export function assertEquals<T>(actual: T, expected: T, msg = ""): void {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) {
    throw new Error(`${msg ? msg + ": " : ""}expected ${b}, got ${a}`);
  }
}

export function assertThrows(fn: () => unknown, msgIncludes = ""): void {
  try {
    fn();
  } catch (err) {
    const m = err instanceof Error ? err.message : String(err);
    if (msgIncludes && !m.includes(msgIncludes)) {
      throw new Error(`thrown message ${JSON.stringify(m)} does not include ${JSON.stringify(msgIncludes)}`);
    }
    return;
  }
  throw new Error("expected function to throw");
}
