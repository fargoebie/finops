import type {
  CloudCostResponse,
  CloudCostStatusResponse,
  ViewGraphResponse,
} from "../types/cloudCost";

export const BASE = "/model";

type ApiResponse = { code: number; message?: string };

async function fetchJson<T extends ApiResponse>(url: string): Promise<T> {
  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`HTTP ${res.status}: ${res.statusText}`);
  }

  const body = (await res.json()) as T;
  if (body.code >= 400) {
    throw new Error(`API error ${body.code}`);
  }

  return body;
}

export function fetchStatus(): Promise<CloudCostStatusResponse> {
  return fetchJson(`${BASE}/cloudCost/status`);
}

export function fetchCloudCost(
  window: string,
  aggregate: string,
): Promise<CloudCostResponse> {
  const params = new URLSearchParams({ window, aggregate });
  return fetchJson(`${BASE}/cloudCost?${params}`);
}

export function fetchViewGraph(
  window: string,
  aggregate: string,
): Promise<ViewGraphResponse> {
  const params = new URLSearchParams({ window, aggregate });
  return fetchJson(`${BASE}/cloudCost/view/graph?${params}`);
}
