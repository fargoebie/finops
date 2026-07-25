import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { CloudCostResponse } from "../types/cloudCost";
import {
  CreditsNetVsListContent,
  fetchCreditsNetVsListViewModel,
  type CreditsNetVsListViewModel,
} from "./CreditsNetVsList";

function serviceResponse(): CloudCostResponse {
  return {
    code: 200,
    data: {
      sets: [
        {
          cloudCosts: {
            compute: {
              listCost: { cost: 50 },
              netCost: { cost: 49 },
              properties: { service: "Compute Engine" },
            },
            places: {
              listCost: { cost: 100 },
              netCost: { cost: 80 },
              properties: { service: "Places API" },
            },
            storage: {
              listCost: { cost: 30 },
              netCost: { cost: 30 },
              properties: { service: "Cloud Storage" },
            },
          },
        },
      ],
    },
  };
}

describe("fetchCreditsNetVsListViewModel", () => {
  it("fetches the active service window and resolves discount rows to real buckets", async () => {
    const calls: Array<{ aggregate: string; window: string }> = [];

    const viewModel = await fetchCreditsNetVsListViewModel({
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
    expect(viewModel.rows.map((row) => [row.service, row.bucketId, row.delta, row.pct, row.highlight])).toEqual([
      ["Places API", "gmp", 20, 20, true],
      ["Compute Engine", "compute", 1, 2, false],
    ]);
  });
});

describe("CreditsNetVsListContent", () => {
  it("renders service, list, net, delta, pct columns and marks highlighted credits", () => {
    const data: CreditsNetVsListViewModel = {
      highlightPct: 5,
      rows: [
        {
          bucketId: "gmp",
          delta: 20,
          highlight: true,
          money: { list: 100, net: 80 },
          pct: 20,
          service: "Places API",
        },
      ],
      windowLabel: "June 2026",
    };

    const html = renderToStaticMarkup(
      <CreditsNetVsListContent
        data={data}
        error={null}
        loading={false}
        onRetry={() => undefined}
      />,
    );

    expect(html).toContain("Credits &amp; net vs list");
    expect(html).toContain("Places API");
    expect(html).toContain("$100.00");
    expect(html).toContain("$80.00");
    expect(html).toContain("$20.00");
    expect(html).toContain("20.0%");
    expect(html).toContain("discount-highlight");
  });
});
