import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { CloudCostResponse, ViewGraphResponse } from "../types/cloudCost";
import {
  ServiceDriversContent,
  fetchServiceDriversViewModel,
  type ServiceDriversViewModel,
} from "./ServiceDrivers";

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

function graphResponse(): ViewGraphResponse {
  return {
    code: 200,
    data: [
      {
        start: "2026-06-01T00:00:00Z",
        end: "2026-06-02T00:00:00Z",
        items: [
          { name: "Places API", value: 40 },
          { name: "Compute Engine", value: 12 },
          { name: "Geocoding API", value: 3 },
        ],
      },
      {
        start: "2026-06-02T00:00:00Z",
        end: "2026-06-03T00:00:00Z",
        items: [
          { name: "Places API", value: 35 },
          { name: "Compute Engine", value: 8 },
          { name: "Geocoding API", value: 2 },
        ],
      },
    ],
  };
}

describe("fetchServiceDriversViewModel", () => {
  it("fetches graph and cloud cost by service for the active window", async () => {
    const graphCalls: Array<{ aggregate: string; window: string }> = [];
    const cloudCostCalls: Array<{ aggregate: string; window: string }> = [];

    const viewModel = await fetchServiceDriversViewModel({
      fetchCloudCost: async (window, aggregate) => {
        cloudCostCalls.push({ aggregate, window });
        return serviceResponse();
      },
      fetchGraph: async (window, aggregate) => {
        graphCalls.push({ aggregate, window });
        return graphResponse();
      },
      invoiceMonth: "2026-06",
      now: new Date("2026-07-24T15:00:00Z"),
      preset: "invoice",
    });

    expect(graphCalls).toEqual([
      {
        aggregate: "service",
        window: "2026-06-01T00:00:00Z,2026-07-01T00:00:00Z",
      },
    ]);
    expect(cloudCostCalls).toEqual(graphCalls);
    expect(viewModel.rows.map((row) => [row.service, row.list, row.net, row.bucketLabel])).toEqual([
      ["Places API", 75, 60, "Google Maps Platform"],
      ["Compute Engine", 20, 16, "Compute & runtime"],
      ["Geocoding API", 5, 4, "Google Maps Platform"],
    ]);
    expect(viewModel.graph[0].items.map((item) => [item.service, item.value])).toEqual([
      ["Places API", 40],
      ["Compute Engine", 12],
      ["Geocoding API", 3],
    ]);
  });
});

describe("ServiceDriversContent", () => {
  const data: ServiceDriversViewModel = {
    graph: [
      {
        end: "2026-06-02T00:00:00Z",
        items: [
          { service: "Places API", value: 40 },
          { service: "Compute Engine", value: 12 },
        ],
        label: "Jun 1",
        start: "2026-06-01T00:00:00Z",
      },
    ],
    rows: [
      {
        bucketId: "gmp",
        bucketLabel: "Google Maps Platform",
        isGmp: true,
        list: 75,
        net: 60,
        service: "Places API",
      },
      {
        bucketId: "compute",
        bucketLabel: "Compute & runtime",
        isGmp: false,
        list: 20,
        net: 16,
        service: "Compute Engine",
      },
    ],
    topN: 15,
    windowLabel: "June 2026",
  };

  it("renders the line chart note and top service list/net table", () => {
    const html = renderToStaticMarkup(
      <ServiceDriversContent
        data={data}
        error={null}
        gmpOnly={false}
        loading={false}
        onGmpOnlyChange={() => undefined}
        onRetry={() => undefined}
      />,
    );

    expect(html).toContain("Service drivers");
    expect(html).toContain("Line chart uses list cost; table includes net cost.");
    expect(html).toContain("Places API");
    expect(html).toContain("$75.00");
    expect(html).toContain("$60.00");
    expect(html).toContain("Compute Engine");
    expect(html).toContain("Compute &amp; runtime");
  });

  it("filters the rendered table to GMP services when requested", () => {
    const html = renderToStaticMarkup(
      <ServiceDriversContent
        data={data}
        error={null}
        gmpOnly={true}
        loading={false}
        onGmpOnlyChange={() => undefined}
        onRetry={() => undefined}
      />,
    );

    expect(html).toContain("Places API");
    expect(html).not.toContain("Compute Engine");
  });
});
