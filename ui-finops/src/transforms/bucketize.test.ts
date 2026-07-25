import { describe, expect, it } from "vitest";
import {
  bucketizeServices,
  gmpSubMix,
  loadCategoryMap,
  resolveBucket,
  type CategoryMap,
} from "./bucketize";

function mapWithoutService(service: string): CategoryMap {
  const map = loadCategoryMap();
  const { [service]: _removed, ...serviceToBucket } = map.serviceToBucket;
  return { ...map, serviceToBucket };
}

describe("resolveBucket", () => {
  it("maps Places API to the GMP places sub-bucket", () => {
    expect(resolveBucket("Places API", loadCategoryMap())).toEqual({
      bucketId: "gmp",
      gmpSubId: "places",
    });
  });

  it("maps Invoice to billing", () => {
    expect(resolveBucket("Invoice", loadCategoryMap())).toEqual({ bucketId: "billing" });
  });

  it("maps Claude Fable 5 to AI / ML via service name pattern", () => {
    expect(resolveBucket("Claude Fable 5", mapWithoutService("Claude Fable 5"))).toEqual({
      bucketId: "ai_ml",
    });
  });
});

describe("bucketizeServices", () => {
  it("maps unknown services to other and counts them as unmapped", () => {
    const result = bucketizeServices(
      new Map([
        ["Totally Unknown", { list: 11, net: 9 }],
        ["Invoice", { list: -3, net: -3 }],
      ]),
      loadCategoryMap(),
    );

    expect(result.unmappedCount).toBe(1);
    expect(result.services).toContainEqual({
      service: "Totally Unknown",
      money: { list: 11, net: 9 },
      bucketId: "other",
    });
    expect(result.buckets).toContainEqual({
      bucketId: "other",
      label: "Unmapped",
      money: { list: 11, net: 9 },
    });
    expect(result.buckets).toContainEqual({
      bucketId: "billing",
      label: "Billing adjustments",
      money: { list: -3, net: -3 },
    });
  });
});

describe("gmpSubMix", () => {
  it("sums GMP services by Places and Geocoding sub-buckets", () => {
    const map = loadCategoryMap();
    const result = bucketizeServices(
      new Map([
        ["Places API", { list: 10, net: 8 }],
        ["Places API (New)", { list: 4, net: 3 }],
        ["Geocoding API", { list: 6, net: 5 }],
        ["Invoice", { list: -2, net: -2 }],
      ]),
      map,
    );

    expect(gmpSubMix(result.services, map)).toEqual([
      { bucketId: "places", label: "Places", money: { list: 14, net: 11 } },
      { bucketId: "geocoding", label: "Geocoding", money: { list: 6, net: 5 } },
    ]);
  });
});
