import { describe, expect, it } from "vitest";
import { previousCalendarMonth } from "./App";

describe("previousCalendarMonth", () => {
  it("returns the prior UTC calendar month as YYYY-MM", () => {
    expect(previousCalendarMonth(new Date("2026-07-24T15:00:00Z"))).toBe("2026-06");
  });

  it("rolls back across year boundaries", () => {
    expect(previousCalendarMonth(new Date("2026-01-03T00:00:00Z"))).toBe("2025-12");
  });
});
