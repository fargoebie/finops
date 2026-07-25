import { describe, expect, it } from "vitest";
import { resolveWindow, priorWindow } from "./windows";

describe("resolveWindow", () => {
  const now = new Date("2026-07-24T15:00:00Z");

  it("maps 7d and 30d to OpenCost rolling windows", () => {
    expect(resolveWindow("7d", now).window).toBe("7d");
    expect(resolveWindow("30d", now).window).toBe("30d");
  });

  it("maps mtd to exclusive UTC month range", () => {
    expect(resolveWindow("mtd", now).window).toBe("2026-07-01T00:00:00Z,2026-07-25T00:00:00Z");
  });

  it("maps invoice month YYYY-MM to calendar month range", () => {
    expect(resolveWindow("invoice", now, "2026-06").window).toBe(
      "2026-06-01T00:00:00Z,2026-07-01T00:00:00Z",
    );
  });
});

describe("priorWindow", () => {
  const now = new Date("2026-07-24T15:00:00Z");

  it("prior 7d is the previous 7 days as an absolute range", () => {
    // 2026-07-10 → 2026-07-17 (day before current 7d start)
    const w = priorWindow("7d", now).window;
    expect(w).toBe("2026-07-10T00:00:00Z,2026-07-17T00:00:00Z");
  });

  it("prior invoice is previous calendar month", () => {
    expect(priorWindow("invoice", now, "2026-06").window).toBe(
      "2026-05-01T00:00:00Z,2026-06-01T00:00:00Z",
    );
  });
});
