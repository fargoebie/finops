import { describe, expect, it, vi } from "vitest";
import type { CloudCostResponse } from "../types/cloudCost";
import { fetchExecPulseTotals, fetchUnmappedCount, percentChange } from "./useInformData";

function response(list: number, net: number): CloudCostResponse {
  return {
    code: 200,
    data: {
      sets: [
        {
          cloudCosts: {
            gcp: {
              listCost: { cost: list },
              netCost: { cost: net },
              properties: { provider: "gcp" },
            },
          },
        },
      ],
    },
  };
}

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
            custom: {
              listCost: { cost: 10 },
              netCost: { cost: 8 },
              properties: { service: "Custom Service" },
            },
          },
        },
      ],
    },
  };
}

describe("fetchExecPulseTotals", () => {
  it("fetches provider totals for MTD, 7d, 30d, and prior 7d windows", async () => {
    const fetcher = vi
      .fn()
      .mockResolvedValueOnce(response(1000, 900))
      .mockResolvedValueOnce(response(700, 600))
      .mockResolvedValueOnce(response(3000, 2700))
      .mockResolvedValueOnce(response(350, 500));

    const totals = await fetchExecPulseTotals(
      new Date("2026-07-24T15:00:00Z"),
      "2026-06",
      fetcher,
    );

    expect(fetcher).toHaveBeenCalledTimes(4);
    expect(fetcher).toHaveBeenNthCalledWith(
      1,
      "2026-07-01T00:00:00Z,2026-07-25T00:00:00Z",
      "provider",
    );
    expect(fetcher).toHaveBeenNthCalledWith(2, "7d", "provider");
    expect(fetcher).toHaveBeenNthCalledWith(3, "30d", "provider");
    expect(fetcher).toHaveBeenNthCalledWith(
      4,
      "2026-07-10T00:00:00Z,2026-07-17T00:00:00Z",
      "provider",
    );
    expect(totals).toEqual({
      mtd: { list: 1000, net: 900 },
      priorSevenDay: { list: 350, net: 500 },
      rollingSevenDay: { list: 700, net: 600 },
      rollingThirtyDay: { list: 3000, net: 2700 },
      wow: { list: 100, net: 20 },
    });
  });
});

describe("fetchUnmappedCount", () => {
  it("fetches the selected service window and returns bucketize unmappedCount", async () => {
    const fetcher = vi.fn().mockResolvedValue(serviceResponse());

    const count = await fetchUnmappedCount(
      new Date("2026-07-24T15:00:00Z"),
      "2026-06",
      "invoice",
      fetcher,
    );

    expect(fetcher).toHaveBeenCalledWith(
      "2026-06-01T00:00:00Z,2026-07-01T00:00:00Z",
      "service",
    );
    expect(count).toBe(1);
  });
});

describe("percentChange", () => {
  it("returns null when prior cost is zero", () => {
    expect(percentChange(25, 0)).toBeNull();
  });
});
