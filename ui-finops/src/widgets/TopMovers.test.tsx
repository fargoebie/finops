import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { CloudCostResponse } from "../types/cloudCost";
import {
  TopMoversContent,
  fetchTopMoversViewModel,
  type TopMoversViewModel,
} from "./TopMovers";

function responseFor(entries: Array<[string, number]>): CloudCostResponse {
  return {
    code: 200,
    data: {
      sets: [
        {
          cloudCosts: Object.fromEntries(
            entries.map(([service, list]) => [
              service,
              {
                listCost: { cost: list },
                netCost: { cost: list * 0.8 },
                properties: { service },
              },
            ]),
          ),
        },
      ],
    },
  };
}

describe("fetchTopMoversViewModel", () => {
  it("fetches current and prior service windows and returns top 10 risers and fallers by deltaList", async () => {
    const calls: Array<{ aggregate: string; window: string }> = [];
    const current = [
      ...Array.from({ length: 11 }, (_, index) => [`Riser ${index}`, 100 + index] as [string, number]),
      ...Array.from({ length: 11 }, (_, index) => [`Faller ${index}`, 100 - index] as [string, number]),
    ];
    const prior = [
      ...Array.from({ length: 11 }, (_, index) => [`Riser ${index}`, 50] as [string, number]),
      ...Array.from({ length: 11 }, (_, index) => [`Faller ${index}`, 150] as [string, number]),
    ];

    const viewModel = await fetchTopMoversViewModel({
      fetcher: async (window, aggregate) => {
        calls.push({ aggregate, window });
        return calls.length === 1 ? responseFor(current) : responseFor(prior);
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
      {
        aggregate: "service",
        window: "2026-05-01T00:00:00Z,2026-06-01T00:00:00Z",
      },
    ]);
    expect(viewModel.risers).toHaveLength(10);
    expect(viewModel.fallers).toHaveLength(10);
    expect(viewModel.risers.map((row) => row.key)).toEqual([
      "Riser 10",
      "Riser 9",
      "Riser 8",
      "Riser 7",
      "Riser 6",
      "Riser 5",
      "Riser 4",
      "Riser 3",
      "Riser 2",
      "Riser 1",
    ]);
    expect(viewModel.fallers.map((row) => row.key)).toEqual([
      "Faller 10",
      "Faller 9",
      "Faller 8",
      "Faller 7",
      "Faller 6",
      "Faller 5",
      "Faller 4",
      "Faller 3",
      "Faller 2",
      "Faller 1",
    ]);
  });
});

describe("TopMoversContent", () => {
  it("renders riser and faller tables with current, prior, delta, and percentage", () => {
    const data: TopMoversViewModel = {
      currentWindowLabel: "June 2026",
      fallers: [
        {
          current: { list: 25, net: 20 },
          deltaList: -75,
          deltaNet: -60,
          key: "Compute Engine",
          pctList: -75,
          pctNet: -75,
          prior: { list: 100, net: 80 },
        },
      ],
      priorWindowLabel: "May 2026",
      risers: [
        {
          current: { list: 150, net: 120 },
          deltaList: 50,
          deltaNet: 40,
          key: "Places API",
          pctList: 50,
          pctNet: 50,
          prior: { list: 100, net: 80 },
        },
      ],
    };

    const html = renderToStaticMarkup(
      <TopMoversContent
        data={data}
        error={null}
        loading={false}
        onRetry={() => undefined}
      />,
    );

    expect(html).toContain("Top movers");
    expect(html).toContain("Risers");
    expect(html).toContain("Fallers");
    expect(html).toContain("Places API");
    expect(html).toContain("Compute Engine");
    expect(html).toContain("$150.00");
    expect(html).toContain("$100.00");
    expect(html).toContain("+$50.00");
    expect(html).toContain("-$75.00");
    expect(html).toContain("+50.0%");
    expect(html).toContain("-75.0%");
  });
});
