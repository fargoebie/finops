import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { CloudCostResponse } from "../types/cloudCost";
import {
  CategoryMixContent,
  fetchCategoryMixViewModel,
  type CategoryMixViewModel,
} from "./CategoryMix";

function serviceResponse(): CloudCostResponse {
  return {
    code: 200,
    data: {
      sets: [
        {
          cloudCosts: {
            compute: {
              listCost: { cost: 20 },
              netCost: { cost: 16 },
              properties: { service: "Compute Engine" },
            },
            geocoding: {
              listCost: { cost: 5 },
              netCost: { cost: 4 },
              properties: { service: "Geocoding API" },
            },
            places: {
              listCost: { cost: 75 },
              netCost: { cost: 60 },
              properties: { service: "Places API" },
            },
          },
        },
      ],
    },
  };
}

describe("fetchCategoryMixViewModel", () => {
  it("fetches the active invoice window by service and computes expanded bucket mix", async () => {
    const calls: Array<{ aggregate: string; window: string }> = [];

    const viewModel = await fetchCategoryMixViewModel({
      fetcher: async (window, aggregate) => {
        calls.push({ aggregate, window });
        return serviceResponse();
      },
      invoiceMonth: "2026-06",
      now: new Date("2026-07-24T15:00:00Z"),
      preset: "invoice",
    });

    expect(calls).toEqual([
      {
        aggregate: "service",
        window: "2026-06-01T00:00:00Z,2026-07-01T00:00:00Z",
      },
    ]);
    expect(viewModel.total).toEqual({ list: 100, net: 80 });
    expect(viewModel.gmpListPercent).toBe(80);
    expect(viewModel.buckets.map((bucket) => [bucket.label, bucket.money.list])).toEqual([
      ["Google Maps Platform", 80],
      ["Compute & runtime", 20],
    ]);
    expect(viewModel.gmpSubBuckets.map((bucket) => [bucket.label, bucket.money])).toEqual([
      ["Places", { list: 75, net: 60 }],
      ["Geocoding", { list: 5, net: 4 }],
    ]);
  });
});

describe("CategoryMixContent", () => {
  it("renders the GMP KPI, bucket legend values, and drill list/net values", () => {
    const data: CategoryMixViewModel = {
      buckets: [
        {
          bucketId: "gmp",
          label: "Google Maps Platform",
          money: { list: 80, net: 64 },
        },
        {
          bucketId: "compute",
          label: "Compute & runtime",
          money: { list: 20, net: 16 },
        },
      ],
      gmpListPercent: 80,
      gmpSubBuckets: [
        {
          bucketId: "places",
          label: "Places",
          money: { list: 75, net: 60 },
        },
        {
          bucketId: "geocoding",
          label: "Geocoding",
          money: { list: 5, net: 4 },
        },
      ],
      total: { list: 100, net: 80 },
      unmappedCount: 0,
      windowLabel: "June 2026",
    };

    const html = renderToStaticMarkup(
      <CategoryMixContent
        data={data}
        error={null}
        loading={false}
        onRetry={() => undefined}
      />,
    );

    expect(html).toContain("Category mix");
    expect(html).toContain("GMP list share");
    expect(html).toContain("80.0%");
    expect(html).toContain("Google Maps Platform");
    expect(html).toContain("$80.00 list");
    expect(html).toContain("$64.00 net");
    expect(html).toContain("GMP drill");
    expect(html).toContain("Places");
    expect(html).toContain("$75.00");
    expect(html).toContain("$60.00 net");
  });
});
