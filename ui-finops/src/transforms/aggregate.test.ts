import { describe, expect, it } from "vitest";
import { sumSets, sumByKey } from "./aggregate";
import type { CloudCostSet } from "../types/cloudCost";

const sets: CloudCostSet[] = [
  {
    cloudCosts: {
      "Places API": { listCost: { cost: 10 }, netCost: { cost: 8 }, properties: { service: "Places API" } },
      "BigQuery": { listCost: { cost: 5 }, netCost: { cost: 5 }, properties: { service: "BigQuery" } },
    },
  },
  {
    cloudCosts: {
      "Places API": { listCost: { cost: 2 }, netCost: { cost: 1 }, properties: { service: "Places API" } },
    },
  },
];

describe("sumSets", () => {
  it("sums list and net across all items and days", () => {
    expect(sumSets(sets)).toEqual({ list: 17, net: 14 });
  });
});

describe("sumByKey", () => {
  it("groups by service property or map key", () => {
    const m = sumByKey(sets, (_n, item) => item.properties?.service ?? _n);
    expect(m.get("Places API")).toEqual({ list: 12, net: 9 });
    expect(m.get("BigQuery")).toEqual({ list: 5, net: 5 });
  });
});
