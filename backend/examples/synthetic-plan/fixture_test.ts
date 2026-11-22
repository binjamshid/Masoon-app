import { runFixture } from "../../engine/fixture_runner.ts";
import { assertEquals } from "../../engine/test_assertions.ts";
import poemRef from "./poem-ref.json" with { type: "json" };

const fixtureDir = new URL(".", import.meta.url);
const fixturePath = decodeURIComponent(fixtureDir.pathname);

Deno.test("the example schedules new lines and reviews, then completes", () => {
  const stream = runFixture(fixturePath);
  const lines = stream.trimEnd().split("\n");
  const state = lines.pop();
  assertEquals(
    lines.map((line) => {
      const [date, , , , type, , content] = line.split("|");
      return [date, type, content];
    }),
    [
      ["2028-05-01", "new_hifz", "1:1-2"],
      ["2028-05-02", "murajaah", "1:1-2"],
      ["2028-05-02", "new_hifz", "1:3-4"],
      ["2028-05-03", "murajaah", "1:3-4"],
      ["2028-05-03", "new_hifz", "1:5-6"],
    ],
  );
  assertEquals(
    state,
    "#STATE|cursor=-|juz_done=1|cycle_weeks=0|debt_new=0|status=completed",
  );
  assertEquals(runFixture(fixturePath), stream);
});

Deno.test("the synthetic index matches the sample poem", async () => {
  const bytes = await Deno.readFile(new URL("window-lamp.txt", fixtureDir));
  const text = new TextDecoder().decode(bytes);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  const hex = Array.from(digest, (byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  assertEquals(poemRef.works[0].unit_count, text.trimEnd().split("\n").length);
  assertEquals(poemRef.source_sha256, hex);
});
