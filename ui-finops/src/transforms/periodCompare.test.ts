import { describe, expect, it } from "vitest";
import { periodCompare } from "./periodCompare";

describe("periodCompare", () => {
  it("computes deltas and percentages for matching keys", () => {
    const current = new Map([
      ["Places API", { list: 120, net: 100 }],
      ["BigQuery", { list: 50, net: 40 }],
    ]);
    const prior = new Map([
      ["Places API", { list: 100, net: 80 }],
      ["BigQuery", { list: 40, net: 40 }],
    ]);

    expect(periodCompare(current, prior)).toEqual([
      {
        key: "Places API",
        current: { list: 120, net: 100 },
        prior: { list: 100, net: 80 },
        deltaList: 20,
        deltaNet: 20,
        pctList: 20,
        pctNet: 25,
      },
      {
        key: "BigQuery",
        current: { list: 50, net: 40 },
        prior: { list: 40, net: 40 },
        deltaList: 10,
        deltaNet: 0,
        pctList: 25,
        pctNet: 0,
      },
    ]);
  });

  it("treats missing prior keys as zero", () => {
    const current = new Map([["New Service", { list: 30, net: 25 }]]);
    const prior = new Map<string, { list: number; net: number }>();

    expect(periodCompare(current, prior)).toEqual([
      {
        key: "New Service",
        current: { list: 30, net: 25 },
        prior: { list: 0, net: 0 },
        deltaList: 30,
        deltaNet: 25,
        pctList: null,
        pctNet: null,
      },
    ]);
  });

  it("includes keys only present in prior with zero current", () => {
    const current = new Map<string, { list: number; net: number }>();
    const prior = new Map([["Retired Service", { list: 40, net: 35 }]]);

    expect(periodCompare(current, prior)).toEqual([
      {
        key: "Retired Service",
        current: { list: 0, net: 0 },
        prior: { list: 40, net: 35 },
        deltaList: -40,
        deltaNet: -35,
        pctList: -100,
        pctNet: -100,
      },
    ]);
  });

  it("returns null percentages when prior is zero", () => {
    const current = new Map([["Service", { list: 10, net: 8 }]]);
    const prior = new Map([["Service", { list: 0, net: 0 }]]);

    expect(periodCompare(current, prior)[0]).toMatchObject({
      deltaList: 10,
      deltaNet: 8,
      pctList: null,
      pctNet: null,
    });
  });

  it("sorts by absolute deltaList descending", () => {
    const current = new Map([
      ["Small", { list: 11, net: 11 }],
      ["Large", { list: 200, net: 200 }],
      ["Medium", { list: 50, net: 50 }],
    ]);
    const prior = new Map([
      ["Small", { list: 10, net: 10 }],
      ["Large", { list: 100, net: 100 }],
      ["Medium", { list: 80, net: 80 }],
    ]);

    expect(periodCompare(current, prior).map((row) => row.key)).toEqual([
      "Large",
      "Medium",
      "Small",
    ]);
  });
});
