import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BASE, fetchCloudCost, fetchStatus, fetchViewGraph } from "./cloudCost";
import type {
  CloudCostResponse,
  CloudCostStatusResponse,
  ViewGraphResponse,
} from "../types/cloudCost";

describe("cloudCost API client", () => {
  beforeEach(() => {
    vi.stubGlobal("fetch", vi.fn());
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("fetchCloudCost requests /model/cloudCost with window and aggregate", async () => {
    const payload: CloudCostResponse = {
      code: 200,
      data: { sets: [] },
    };
    vi.mocked(fetch).mockResolvedValue({
      ok: true,
      json: async () => payload,
    } as Response);

    const result = await fetchCloudCost("7d", "service");

    expect(fetch).toHaveBeenCalledWith(
      `${BASE}/cloudCost?window=7d&aggregate=service`,
    );
    expect(result).toEqual(payload);
  });

  it("fetchStatus requests /model/cloudCost/status", async () => {
    const payload: CloudCostStatusResponse = {
      code: 200,
      data: [{ connectionStatus: "Connection Successful" }],
    };
    vi.mocked(fetch).mockResolvedValue({
      ok: true,
      json: async () => payload,
    } as Response);

    const result = await fetchStatus();

    expect(fetch).toHaveBeenCalledWith(`${BASE}/cloudCost/status`);
    expect(result).toEqual(payload);
  });

  it("fetchViewGraph requests /model/cloudCost/view/graph with params", async () => {
    const payload: ViewGraphResponse = {
      code: 200,
      data: [{ start: "2026-07-01", end: "2026-07-02", items: [] }],
    };
    vi.mocked(fetch).mockResolvedValue({
      ok: true,
      json: async () => payload,
    } as Response);

    const result = await fetchViewGraph("30d", "service");

    expect(fetch).toHaveBeenCalledWith(
      `${BASE}/cloudCost/view/graph?window=30d&aggregate=service`,
    );
    expect(result).toEqual(payload);
  });

  it("throws on non-OK HTTP", async () => {
    vi.mocked(fetch).mockResolvedValue({
      ok: false,
      status: 503,
      statusText: "Service Unavailable",
      json: async () => ({ code: 503, message: "down" }),
    } as Response);

    await expect(fetchCloudCost("7d", "service")).rejects.toThrow(
      "HTTP 503: Service Unavailable",
    );
  });

  it("throws when response code is >= 400", async () => {
    vi.mocked(fetch).mockResolvedValue({
      ok: true,
      json: async () => ({ code: 400, message: "bad window" }),
    } as Response);

    await expect(fetchCloudCost("bad", "service")).rejects.toThrow(
      "API error 400",
    );
  });
});
