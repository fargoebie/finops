import { describe, expect, it } from "vitest";
import { discountRows } from "./discount";

describe("discountRows", () => {
  it("computes delta and percentage from list and net", () => {
    const byService = new Map([
      ["Places API", { list: 100, net: 80 }],
      ["BigQuery", { list: 50, net: 50 }],
    ]);

    expect(discountRows(byService, 5)).toEqual([
      {
        service: "Places API",
        money: { list: 100, net: 80 },
        bucketId: "other",
        delta: 20,
        pct: 20,
        highlight: true,
      },
    ]);
  });

  it("returns null pct when list is zero", () => {
    const byService = new Map([["Credit", { list: 0, net: -10 }]]);

    expect(discountRows(byService, 5)).toEqual([
      {
        service: "Credit",
        money: { list: 0, net: -10 },
        bucketId: "other",
        delta: 10,
        pct: null,
        highlight: false,
      },
    ]);
  });

  it("sorts by absolute delta descending", () => {
    const byService = new Map([
      ["Small", { list: 11, net: 10 }],
      ["Large", { list: 200, net: 150 }],
      ["Medium", { list: 50, net: 40 }],
    ]);

    expect(discountRows(byService, 5).map((row) => row.service)).toEqual([
      "Large",
      "Medium",
      "Small",
    ]);
  });

  it("marks highlight when pct meets threshold", () => {
    const byService = new Map([
      ["Below", { list: 100, net: 96 }],
      ["At", { list: 100, net: 95 }],
      ["Above", { list: 100, net: 90 }],
    ]);

    const rows = discountRows(byService, 5);
    expect(rows.find((row) => row.service === "Below")?.highlight).toBe(false);
    expect(rows.find((row) => row.service === "At")?.highlight).toBe(true);
    expect(rows.find((row) => row.service === "Above")?.highlight).toBe(true);
  });
});
