// LocalDate civil arithmetic + integer/decimal helper laws.

import {
  addDays,
  dayOfWeek,
  daysInMonth,
  decimalTimesUnit,
  decimalToInt,
  formatLocalDate,
  fromEpochDay,
  isLeapYear,
  parseLocalDate,
  roundHalfUp,
  toEpochDay,
  weekStart,
} from "./types.ts";
import { assert, assertEquals, assertThrows } from "./test_assertions.ts";

Deno.test("LocalDate: 2026-07-12 is a Sunday", () => {
  assertEquals(dayOfWeek(parseLocalDate("2026-07-12")), "sun");
});

Deno.test("LocalDate: known weekdays", () => {
  assertEquals(dayOfWeek(toEpochDay(1970, 1, 1)), "thu");
  assertEquals(dayOfWeek(toEpochDay(2000, 1, 1)), "sat");
  assertEquals(dayOfWeek(toEpochDay(2024, 2, 29)), "thu");
  assertEquals(dayOfWeek(parseLocalDate("2026-08-15")), "sat");
});

Deno.test("LocalDate: leap year rules", () => {
  assert(isLeapYear(2024) && isLeapYear(2000) && isLeapYear(1600));
  assert(!isLeapYear(2100) && !isLeapYear(1900) && !isLeapYear(2026));
  assertEquals(daysInMonth(2024, 2), 29);
  assertEquals(daysInMonth(2026, 2), 28);
  assertThrows(() => toEpochDay(2100, 2, 29), "invalid civil date");
  assertThrows(() => parseLocalDate("2026-13-01"), "invalid");
});

Deno.test("LocalDate: leap-day arithmetic crosses correctly", () => {
  const feb28 = parseLocalDate("2024-02-28");
  assertEquals(formatLocalDate(addDays(feb28, 1)), "2024-02-29");
  assertEquals(formatLocalDate(addDays(feb28, 2)), "2024-03-01");
  const feb28ny = parseLocalDate("2026-02-28");
  assertEquals(formatLocalDate(addDays(feb28ny, 1)), "2026-03-01");
});

Deno.test("LocalDate: roundtrip over a broad range", () => {
  for (let e = parseLocalDate("1999-12-25"); e <= parseLocalDate("2001-01-05"); e++) {
    const { year, month, day } = fromEpochDay(e);
    assertEquals(toEpochDay(year, month, day), e);
  }
  assertEquals(formatLocalDate(parseLocalDate("2026-07-12")), "2026-07-12");
  // 400-year cycle length
  assertEquals(toEpochDay(2400, 3, 1) - toEpochDay(2000, 3, 1), 146097);
});

Deno.test("LocalDate: weekStart returns the Sunday at/before the date", () => {
  assertEquals(formatLocalDate(weekStart(parseLocalDate("2026-07-15"))), "2026-07-12");
  assertEquals(formatLocalDate(weekStart(parseLocalDate("2026-07-12"))), "2026-07-12");
  assertEquals(formatLocalDate(weekStart(parseLocalDate("2026-07-18"))), "2026-07-12");
});

Deno.test("roundHalfUp: exact half rounds up, integer-only", () => {
  assertEquals(roundHalfUp(5, 2), 3);
  assertEquals(roundHalfUp(4, 2), 2);
  assertEquals(roundHalfUp(0, 7), 0);
  assertEquals(roundHalfUp(6_999_999, 1_000_000), 7);
  assertEquals(roundHalfUp(6_499_999, 1_000_000), 6);
  assertEquals(roundHalfUp(6_500_000, 1_000_000), 7);
});

Deno.test("decimalTimesUnit: decimal strings, no float influence", () => {
  assertEquals(decimalTimesUnit("1", 1_000_000), 1_000_000);
  assertEquals(decimalTimesUnit("0.5", 1_000_000), 500_000);
  assertEquals(decimalTimesUnit("2", 20_000_000), 40_000_000);
  assertEquals(decimalTimesUnit("0.1", 1_000_000), 100_000);
  assertEquals(decimalTimesUnit("1.25", 2_500_000), 3_125_000);
  assertEquals(decimalTimesUnit(5, 1_000_000), 5_000_000); // numeric compiled values
  assertEquals(decimalTimesUnit("0.333333", 1_000_000), 333_333);
  assertThrows(() => decimalTimesUnit("-1", 1_000_000), "invalid decimal");
  assertThrows(() => decimalTimesUnit("1.2345678", 1_000_000), "fraction digits");
});

Deno.test("decimalToInt: ayah counts", () => {
  assertEquals(decimalToInt("3"), 3);
  assertEquals(decimalToInt(7), 7);
});
