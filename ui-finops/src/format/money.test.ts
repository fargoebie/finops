import { describe, expect, it } from "vitest";
import { formatMoney } from "./money";

describe("formatMoney", () => {
  it("keeps cents for values under $1000", () => {
    expect(formatMoney(999.49)).toBe("$999.49");
  });

  it("rounds large values to whole dollars", () => {
    expect(formatMoney(12_345.67)).toBe("$12,346");
  });
});
