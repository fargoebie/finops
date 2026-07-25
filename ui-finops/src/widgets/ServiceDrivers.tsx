import { useCallback, useEffect, useMemo, useState } from "react";
import {
  CartesianGrid,
  Legend,
  Line,
  LineChart,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import {
  fetchCloudCost as fetchCloudCostApi,
  fetchViewGraph,
} from "../api/cloudCost";
import { formatMoney } from "../format/money";
import { sumByKey } from "../transforms/aggregate";
import {
  bucketizeServices,
  loadCategoryMap,
  type CategoryMap,
} from "../transforms/bucketize";
import { resolveWindow } from "../transforms/windows";
import type { CloudCostResponse, ViewGraphResponse } from "../types/cloudCost";
import type { WindowPreset } from "../types/viewModels";

type FetchCloudCost = (
  window: string,
  aggregate: string,
) => Promise<CloudCostResponse>;

type FetchViewGraph = (
  window: string,
  aggregate: string,
) => Promise<ViewGraphResponse>;

type FetchServiceDriversOptions = {
  categoryMap?: CategoryMap;
  fetchCloudCost?: FetchCloudCost;
  fetchGraph?: FetchViewGraph;
  invoiceMonth: string;
  now: Date;
  preset: WindowPreset;
};

type ServiceDriversProps = {
  fetchCloudCost?: FetchCloudCost;
  fetchGraph?: FetchViewGraph;
  invoiceMonth: string;
  now: Date;
  preset: WindowPreset;
};

type ServiceDriversContentProps = {
  data: ServiceDriversViewModel | null;
  error: string | null;
  gmpOnly: boolean;
  loading: boolean;
  onGmpOnlyChange: (value: boolean) => void;
  onRetry: () => void;
};

export type ServiceDriverRow = {
  bucketId: string;
  bucketLabel: string;
  isGmp: boolean;
  list: number;
  net: number;
  service: string;
};

export type ServiceDriverGraphPoint = {
  end: string;
  items: Array<{ service: string; value: number }>;
  label: string;
  start: string;
};

export type ServiceDriversViewModel = {
  graph: ServiceDriverGraphPoint[];
  rows: ServiceDriverRow[];
  topN: number;
  windowLabel: string;
};

type ChartSeries = {
  color: string;
  key: string;
  service: string;
};

type ChartDatum = {
  label: string;
  [key: string]: number | string;
};

const defaultTopN = 15;
const maxChartSeries = 5;
const colors = ["#2563eb", "#059669", "#d97706", "#7c3aed", "#dc2626"];

function graphPointLabel(start: string): string {
  const date = new Date(start);
  if (Number.isNaN(date.getTime())) {
    return start;
  }

  return date.toLocaleDateString("en-US", {
    day: "numeric",
    month: "short",
    timeZone: "UTC",
  });
}

function tableRowsFor(
  data: ServiceDriversViewModel | null,
  gmpOnly: boolean,
): ServiceDriverRow[] {
  const rows = data?.rows ?? [];
  return gmpOnly ? rows.filter((row) => row.isGmp) : rows;
}

function chartModelFor(
  data: ServiceDriversViewModel,
  rows: ServiceDriverRow[],
): { points: ChartDatum[]; series: ChartSeries[] } {
  const series = rows.slice(0, maxChartSeries).map((row, index) => ({
    color: colors[index % colors.length],
    key: `service${index}`,
    service: row.service,
  }));

  const points = data.graph.map((point) => {
    const valuesByService = new Map(
      point.items.map((item) => [item.service, item.value] as const),
    );
    const datum: ChartDatum = { label: point.label };

    for (const item of series) {
      datum[item.key] = valuesByService.get(item.service) ?? 0;
    }

    return datum;
  });

  return { points, series };
}

function ServiceDriverTooltip({
  active,
  label,
  payload,
}: {
  active?: boolean;
  label?: string;
  payload?: Array<{ color?: string; name?: string; value?: number }>;
}) {
  if (!active || payload === undefined || payload.length === 0) {
    return null;
  }

  return (
    <div className="service-drivers-tooltip">
      <strong>{label}</strong>
      {payload.map((item) => (
        <span key={item.name} style={{ color: item.color }}>
          {item.name}: {formatMoney(item.value ?? 0)} list
        </span>
      ))}
      <small>Table includes net cost for the selected window.</small>
    </div>
  );
}

export async function fetchServiceDriversViewModel({
  categoryMap = loadCategoryMap(),
  fetchCloudCost = fetchCloudCostApi,
  fetchGraph = fetchViewGraph,
  invoiceMonth,
  now,
  preset,
}: FetchServiceDriversOptions): Promise<ServiceDriversViewModel> {
  const activeWindow = resolveWindow(preset, now, invoiceMonth);
  const [graphResponse, cloudCostResponse] = await Promise.all([
    fetchGraph(activeWindow.window, "service"),
    fetchCloudCost(activeWindow.window, "service"),
  ]);

  const byService = sumByKey(
    cloudCostResponse.data.sets,
    (name, item) => item.properties?.service ?? name,
  );
  const { services } = bucketizeServices(byService, categoryMap);
  const labelsByBucket = new Map(
    categoryMap.buckets.map((bucket) => [bucket.id, bucket.label] as const),
  );
  const rows = services
    .map((service) => ({
      bucketId: service.bucketId,
      bucketLabel: labelsByBucket.get(service.bucketId) ?? service.bucketId,
      isGmp: service.bucketId === "gmp",
      list: service.money.list,
      net: service.money.net,
      service: service.service,
    }))
    .sort((a, b) => b.list - a.list || a.service.localeCompare(b.service));
  const graph = graphResponse.data.map((point) => ({
    end: point.end,
    items: point.items.map((item) => ({
      service: item.name,
      value: item.value,
    })),
    label: graphPointLabel(point.start),
    start: point.start,
  }));

  return {
    graph,
    rows,
    topN: categoryMap.defaults.topN ?? defaultTopN,
    windowLabel: activeWindow.label,
  };
}

export function ServiceDriversContent({
  data,
  error,
  gmpOnly,
  loading,
  onGmpOnlyChange,
  onRetry,
}: ServiceDriversContentProps) {
  if (error !== null) {
    return (
      <section className="service-drivers-card" aria-label="Service drivers">
        <div className="service-drivers-heading">
          <div>
            <p className="eyebrow">Section 3</p>
            <h2>Service drivers</h2>
          </div>
        </div>
        <div className="exec-pulse-error" role="alert">
          <strong>Failed to load service drivers</strong>
          <span>{error}</span>
          <button onClick={onRetry} type="button">
            Retry
          </button>
        </div>
      </section>
    );
  }

  const filteredRows = tableRowsFor(data, gmpOnly);
  const visibleRows = filteredRows.slice(0, data?.topN ?? defaultTopN);
  const chartModel = data === null ? null : chartModelFor(data, filteredRows);

  return (
    <section className="service-drivers-card" aria-label="Service drivers">
      <div className="service-drivers-heading">
        <div>
          <p className="eyebrow">Section 3</p>
          <h2>Service drivers</h2>
          <span>{data?.windowLabel ?? "Selected window"}</span>
        </div>
        <div className="service-drivers-actions">
          {loading ? <span className="exec-pulse-loading">Loading...</span> : null}
          <label className="service-drivers-filter">
            <input
              checked={gmpOnly}
              onChange={(event) => onGmpOnlyChange(event.currentTarget.checked)}
              type="checkbox"
            />
            GMP only
          </label>
        </div>
      </div>

      <div className="service-drivers-chart-panel">
        <div className="service-drivers-chart-header">
          <div>
            <h3>Service list trend</h3>
            <p>Line chart uses list cost; table includes net cost.</p>
          </div>
          <span>Top {Math.min(maxChartSeries, filteredRows.length)} by list</span>
        </div>
        {data === null ? (
          <p className="category-empty">Loading service trends...</p>
        ) : chartModel === null ||
          chartModel.series.length === 0 ||
          chartModel.points.length === 0 ? (
          <p className="category-empty">No service graph data for this window.</p>
        ) : (
          <LineChart
            data={chartModel.points}
            height={300}
            margin={{ bottom: 8, left: 16, right: 24, top: 12 }}
            width={920}
          >
            <CartesianGrid stroke="#dfe7f1" strokeDasharray="3 3" />
            <XAxis dataKey="label" tick={{ fill: "#58667e", fontSize: 12 }} />
            <YAxis
              tick={{ fill: "#58667e", fontSize: 12 }}
              tickFormatter={(value) => formatMoney(Number(value))}
              width={88}
            />
            <Tooltip content={<ServiceDriverTooltip />} />
            <Legend />
            {chartModel.series.map((series) => (
              <Line
                dataKey={series.key}
                dot={false}
                key={series.key}
                name={series.service}
                stroke={series.color}
                strokeWidth={3}
                type="monotone"
              />
            ))}
          </LineChart>
        )}
      </div>

      <div className="service-drivers-table-panel">
        <div className="service-drivers-table-heading">
          <h3>Top {data?.topN ?? defaultTopN} services</h3>
          <span>{gmpOnly ? "GMP services only" : "All services"}</span>
        </div>
        {data === null ? (
          <p className="category-empty">Loading top services...</p>
        ) : visibleRows.length === 0 ? (
          <p className="category-empty">No matching service costs for this window.</p>
        ) : (
          <table className="service-drivers-table">
            <thead>
              <tr>
                <th scope="col">Service</th>
                <th scope="col">List</th>
                <th scope="col">Net</th>
                <th scope="col">Bucket label</th>
              </tr>
            </thead>
            <tbody>
              {visibleRows.map((row) => (
                <tr key={row.service}>
                  <th scope="row">{row.service}</th>
                  <td>{formatMoney(row.list)}</td>
                  <td>{formatMoney(row.net)}</td>
                  <td>{row.bucketLabel}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </section>
  );
}

export function ServiceDrivers({
  fetchCloudCost = fetchCloudCostApi,
  fetchGraph = fetchViewGraph,
  invoiceMonth,
  now,
  preset,
}: ServiceDriversProps) {
  const [data, setData] = useState<ServiceDriversViewModel | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [gmpOnly, setGmpOnly] = useState(false);
  const [loading, setLoading] = useState(true);
  const [refresh, setRefresh] = useState(0);
  const categoryMap = useMemo(() => loadCategoryMap(), []);

  const retry = useCallback(() => {
    setRefresh((current) => current + 1);
  }, []);

  useEffect(() => {
    let active = true;

    setLoading(true);
    setError(null);

    fetchServiceDriversViewModel({
      categoryMap,
      fetchCloudCost,
      fetchGraph,
      invoiceMonth,
      now,
      preset,
    })
      .then((viewModel) => {
        if (active) {
          setData(viewModel);
        }
      })
      .catch((caught: unknown) => {
        if (active) {
          setError(caught instanceof Error ? caught.message : String(caught));
          setData(null);
        }
      })
      .finally(() => {
        if (active) {
          setLoading(false);
        }
      });

    return () => {
      active = false;
    };
  }, [categoryMap, fetchCloudCost, fetchGraph, invoiceMonth, now, preset, refresh]);

  return (
    <ServiceDriversContent
      data={data}
      error={error}
      gmpOnly={gmpOnly}
      loading={loading}
      onGmpOnlyChange={setGmpOnly}
      onRetry={retry}
    />
  );
}
