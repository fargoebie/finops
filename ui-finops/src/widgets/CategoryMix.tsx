import { useCallback, useEffect, useMemo, useState } from "react";
import { Cell, Pie, PieChart, Tooltip } from "recharts";
import { fetchCloudCost } from "../api/cloudCost";
import { formatMoney } from "../format/money";
import { sumByKey } from "../transforms/aggregate";
import {
  bucketizeServices,
  gmpSubMix,
  loadCategoryMap,
  type CategoryMap,
} from "../transforms/bucketize";
import { resolveWindow } from "../transforms/windows";
import type { CloudCostResponse } from "../types/cloudCost";
import type { BucketCost, Money, WindowPreset } from "../types/viewModels";

type FetchCloudCost = (
  window: string,
  aggregate: string,
) => Promise<CloudCostResponse>;

export type CategoryMixViewModel = {
  buckets: BucketCost[];
  gmpListPercent: number | null;
  gmpSubBuckets: BucketCost[];
  total: Money;
  unmappedCount: number;
  windowLabel: string;
};

type FetchCategoryMixOptions = {
  categoryMap?: CategoryMap;
  fetcher?: FetchCloudCost;
  invoiceMonth: string;
  now: Date;
  preset: WindowPreset;
};

type CategoryMixProps = {
  fetcher?: FetchCloudCost;
  invoiceMonth: string;
  now: Date;
  preset: WindowPreset;
};

type CategoryMixContentProps = {
  data: CategoryMixViewModel | null;
  error: string | null;
  loading: boolean;
  onRetry: () => void;
};

type ChartDatum = {
  bucketId: string;
  fill: string;
  list: number;
  name: string;
  net: number;
  value: number;
};

const colors = [
  "#3b82f6",
  "#10b981",
  "#f59e0b",
  "#8b5cf6",
  "#ef4444",
  "#06b6d4",
  "#84cc16",
  "#ec4899",
  "#64748b",
  "#94a3b8",
];

function addMoney(a: Money, b: Money): Money {
  return { list: a.list + b.list, net: a.net + b.net };
}

function sortByListDesc(buckets: BucketCost[]): BucketCost[] {
  return [...buckets].sort((a, b) => b.money.list - a.money.list);
}

function formatPercent(value: number | null): string {
  if (value === null) {
    return "\u2014";
  }

  return `${value.toFixed(1)}%`;
}

function chartDataFor(buckets: BucketCost[]): ChartDatum[] {
  return buckets.map((bucket, index) => ({
    bucketId: bucket.bucketId,
    fill: colors[index % colors.length],
    list: bucket.money.list,
    name: bucket.label,
    net: bucket.money.net,
    value: bucket.money.list,
  }));
}

function CategoryTooltip({
  active,
  payload,
}: {
  active?: boolean;
  payload?: Array<{ payload: ChartDatum }>;
}) {
  const datum = payload?.[0]?.payload;
  if (!active || datum === undefined) {
    return null;
  }

  return (
    <div className="category-tooltip">
      <strong>{datum.name}</strong>
      <span>{formatMoney(datum.list)} list</span>
      <span>{formatMoney(datum.net)} net</span>
    </div>
  );
}

export async function fetchCategoryMixViewModel({
  categoryMap = loadCategoryMap(),
  fetcher = fetchCloudCost,
  invoiceMonth,
  now,
  preset,
}: FetchCategoryMixOptions): Promise<CategoryMixViewModel> {
  const activeWindow = resolveWindow(preset, now, invoiceMonth);
  const response = await fetcher(activeWindow.window, "service");
  const byService = sumByKey(
    response.data.sets,
    (name, item) => item.properties?.service ?? name,
  );
  const { buckets, services, unmappedCount } = bucketizeServices(byService, categoryMap);
  const sortedBuckets = sortByListDesc(buckets);
  const sortedGmpSubBuckets = sortByListDesc(gmpSubMix(services, categoryMap));
  const total = sortedBuckets.reduce(
    (sum, bucket) => addMoney(sum, bucket.money),
    { list: 0, net: 0 },
  );
  const gmpList = sortedBuckets.find((bucket) => bucket.bucketId === "gmp")?.money.list ?? 0;

  return {
    buckets: sortedBuckets,
    gmpListPercent: total.list === 0 ? null : (gmpList / total.list) * 100,
    gmpSubBuckets: sortedGmpSubBuckets,
    total,
    unmappedCount,
    windowLabel: activeWindow.label,
  };
}

export function CategoryMixContent({
  data,
  error,
  loading,
  onRetry,
}: CategoryMixContentProps) {
  if (error !== null) {
    return (
      <section className="category-mix-card" aria-label="Category mix">
        <div className="category-mix-heading">
          <div>
            <p className="eyebrow">Section 2</p>
            <h2>Category mix</h2>
          </div>
        </div>
        <div className="exec-pulse-error" role="alert">
          <strong>Failed to load category mix</strong>
          <span>{error}</span>
          <button onClick={onRetry} type="button">
            Retry
          </button>
        </div>
      </section>
    );
  }

  const chartData = data === null ? [] : chartDataFor(data.buckets);
  const maxSubBucketList = Math.max(
    1,
    ...(data?.gmpSubBuckets.map((bucket) => bucket.money.list) ?? []),
  );

  return (
    <section className="category-mix-card" aria-label="Category mix">
      <div className="category-mix-heading">
        <div>
          <p className="eyebrow">Section 2</p>
          <h2>Category mix</h2>
          <span>{data?.windowLabel ?? "Selected window"}</span>
        </div>
        {loading ? <span className="exec-pulse-loading">Loading...</span> : null}
      </div>

      <div className="category-mix-layout">
        <div className="category-chart-panel">
          <div className="category-kpi">
            <span>GMP list share</span>
            <strong>{formatPercent(data?.gmpListPercent ?? null)}</strong>
            <small>GMP list % of total list</small>
          </div>

          {data === null ? (
            <p className="category-empty">Loading category mix...</p>
          ) : chartData.length === 0 ? (
            <p className="category-empty">No service cost data for this window.</p>
          ) : (
            <PieChart height={260} width={320}>
              <Pie
                cx="50%"
                cy="50%"
                data={chartData}
                dataKey="value"
                innerRadius={70}
                nameKey="name"
                outerRadius={110}
                paddingAngle={2}
              >
                {chartData.map((entry) => (
                  <Cell fill={entry.fill} key={entry.bucketId} />
                ))}
              </Pie>
              <Tooltip content={<CategoryTooltip />} />
            </PieChart>
          )}
        </div>

        <div className="category-legend-panel">
          <div className="category-total">
            <span>Total list</span>
            <strong>{data === null ? "Loading..." : formatMoney(data.total.list)}</strong>
            <small>{data === null ? "" : `${formatMoney(data.total.net)} net`}</small>
          </div>
          <ul aria-label="Category mix legend" className="category-legend-list">
            {chartData.map((entry) => (
              <li key={entry.bucketId}>
                <span aria-hidden="true" style={{ backgroundColor: entry.fill }} />
                <div>
                  <strong>{entry.name}</strong>
                  <small>
                    {formatMoney(entry.list)} list / {formatMoney(entry.net)} net
                  </small>
                </div>
              </li>
            ))}
          </ul>
          {data !== null && data.unmappedCount > 0 ? (
            <p className="category-unmapped">
              {data.unmappedCount} unmapped service
              {data.unmappedCount === 1 ? "" : "s"} included.
            </p>
          ) : null}
        </div>
      </div>

      <div className="gmp-drill-panel">
        <div>
          <p className="eyebrow">GMP drill</p>
          <h3>Google Maps Platform sub-mix</h3>
        </div>
        {data === null ? (
          <p className="category-empty">Loading GMP sub-mix...</p>
        ) : data.gmpSubBuckets.length === 0 ? (
          <p className="category-empty">No mapped GMP services in this window.</p>
        ) : (
          <ul className="gmp-drill-list">
            {data.gmpSubBuckets.map((bucket) => {
              const width = `${Math.max(4, (bucket.money.list / maxSubBucketList) * 100)}%`;
              return (
                <li key={bucket.bucketId}>
                  <div className="gmp-drill-row">
                    <strong>{bucket.label}</strong>
                    <span>
                      {formatMoney(bucket.money.list)} list / {formatMoney(bucket.money.net)} net
                    </span>
                  </div>
                  <div className="gmp-drill-track" aria-hidden="true">
                    <span style={{ width }} />
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </div>
    </section>
  );
}

export function CategoryMix({
  fetcher = fetchCloudCost,
  invoiceMonth,
  now,
  preset,
}: CategoryMixProps) {
  const [data, setData] = useState<CategoryMixViewModel | null>(null);
  const [error, setError] = useState<string | null>(null);
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

    fetchCategoryMixViewModel({
      categoryMap,
      fetcher,
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
  }, [categoryMap, fetcher, invoiceMonth, now, preset, refresh]);

  return (
    <CategoryMixContent
      data={data}
      error={error}
      loading={loading}
      onRetry={retry}
    />
  );
}
