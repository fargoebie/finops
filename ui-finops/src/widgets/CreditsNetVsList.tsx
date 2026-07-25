import { useCallback, useEffect, useMemo, useState } from "react";
import { fetchCloudCost } from "../api/cloudCost";
import { formatMoney } from "../format/money";
import { sumByKey } from "../transforms/aggregate";
import { loadCategoryMap, resolveBucket, type CategoryMap } from "../transforms/bucketize";
import { discountRows } from "../transforms/discount";
import { resolveWindow } from "../transforms/windows";
import type { CloudCostResponse } from "../types/cloudCost";
import type { DiscountRow } from "../transforms/discount";
import type { WindowPreset } from "../types/viewModels";

type FetchCloudCost = (
  window: string,
  aggregate: string,
) => Promise<CloudCostResponse>;

type FetchCreditsNetVsListOptions = {
  categoryMap?: CategoryMap;
  fetcher?: FetchCloudCost;
  invoiceMonth: string;
  now: Date;
  preset: WindowPreset;
};

type CreditsNetVsListProps = {
  fetcher?: FetchCloudCost;
  invoiceMonth: string;
  now: Date;
  preset: WindowPreset;
};

type CreditsNetVsListContentProps = {
  data: CreditsNetVsListViewModel | null;
  error: string | null;
  loading: boolean;
  onRetry: () => void;
};

export type CreditsNetVsListViewModel = {
  highlightPct: number;
  rows: DiscountRow[];
  windowLabel: string;
};

const defaultHighlightPct = 5;

function formatPercent(value: number | null): string {
  if (value === null) {
    return "n/a";
  }

  return `${value.toFixed(1)}%`;
}

export async function fetchCreditsNetVsListViewModel({
  categoryMap = loadCategoryMap(),
  fetcher = fetchCloudCost,
  invoiceMonth,
  now,
  preset,
}: FetchCreditsNetVsListOptions): Promise<CreditsNetVsListViewModel> {
  const activeWindow = resolveWindow(preset, now, invoiceMonth);
  const response = await fetcher(activeWindow.window, "service");
  const byService = sumByKey(
    response.data.sets,
    (name, item) => item.properties?.service ?? name,
  );
  const highlightPct = categoryMap.defaults.discountHighlightPct ?? defaultHighlightPct;
  const rows = discountRows(byService, highlightPct).map((row) => ({
    ...row,
    ...resolveBucket(row.service, categoryMap),
  }));

  return {
    highlightPct,
    rows,
    windowLabel: activeWindow.label,
  };
}

export function CreditsNetVsListContent({
  data,
  error,
  loading,
  onRetry,
}: CreditsNetVsListContentProps) {
  if (error !== null) {
    return (
      <section className="credits-card" aria-label="Credits and net vs list">
        <div className="credits-heading">
          <div>
            <p className="eyebrow">Section 5</p>
            <h2>Credits &amp; net vs list</h2>
          </div>
        </div>
        <div className="exec-pulse-error" role="alert">
          <strong>Failed to load credits</strong>
          <span>{error}</span>
          <button onClick={onRetry} type="button">
            Retry
          </button>
        </div>
      </section>
    );
  }

  return (
    <section className="credits-card" aria-label="Credits and net vs list">
      <div className="credits-heading">
        <div>
          <p className="eyebrow">Section 5</p>
          <h2>Credits &amp; net vs list</h2>
          <span>{data?.windowLabel ?? "Selected window"}</span>
        </div>
        {loading ? <span className="exec-pulse-loading">Loading...</span> : null}
      </div>

      <div className="credits-table-panel">
        <div className="credits-panel-heading">
          <div>
            <h3>Discounts and credits by service</h3>
            <p>Rows at or above {data?.highlightPct ?? defaultHighlightPct}% are highlighted.</p>
          </div>
        </div>
        {data === null ? (
          <p className="category-empty">Loading credits...</p>
        ) : data.rows.length === 0 ? (
          <p className="category-empty">No list-to-net deltas for this window.</p>
        ) : (
          <table className="credits-table">
            <thead>
              <tr>
                <th scope="col">Service</th>
                <th scope="col">List</th>
                <th scope="col">Net</th>
                <th scope="col">Delta</th>
                <th scope="col">Pct</th>
              </tr>
            </thead>
            <tbody>
              {data.rows.map((row) => (
                <tr
                  className={row.highlight ? "discount-highlight" : undefined}
                  key={row.service}
                >
                  <th scope="row">
                    {row.service}
                    <small>{row.bucketId}</small>
                  </th>
                  <td>{formatMoney(row.money.list)}</td>
                  <td>{formatMoney(row.money.net)}</td>
                  <td>{formatMoney(row.delta)}</td>
                  <td>{formatPercent(row.pct)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </section>
  );
}

export function CreditsNetVsList({
  fetcher = fetchCloudCost,
  invoiceMonth,
  now,
  preset,
}: CreditsNetVsListProps) {
  const [data, setData] = useState<CreditsNetVsListViewModel | null>(null);
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

    fetchCreditsNetVsListViewModel({
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
    <CreditsNetVsListContent
      data={data}
      error={error}
      loading={loading}
      onRetry={retry}
    />
  );
}
