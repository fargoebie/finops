import { useCallback, useEffect, useState } from "react";
import { fetchCloudCost } from "../api/cloudCost";
import { formatMoney } from "../format/money";
import { sumByKey } from "../transforms/aggregate";
import { periodCompare } from "../transforms/periodCompare";
import { priorWindow, resolveWindow } from "../transforms/windows";
import type { CloudCostResponse } from "../types/cloudCost";
import type { MoverRow, WindowPreset } from "../types/viewModels";

type FetchCloudCost = (
  window: string,
  aggregate: string,
) => Promise<CloudCostResponse>;

type FetchTopMoversOptions = {
  fetcher?: FetchCloudCost;
  invoiceMonth: string;
  now: Date;
  preset: WindowPreset;
};

type TopMoversProps = {
  fetcher?: FetchCloudCost;
  invoiceMonth: string;
  now: Date;
  preset: WindowPreset;
};

type TopMoversContentProps = {
  data: TopMoversViewModel | null;
  error: string | null;
  loading: boolean;
  onRetry: () => void;
};

export type TopMoversViewModel = {
  currentWindowLabel: string;
  fallers: MoverRow[];
  priorWindowLabel: string;
  risers: MoverRow[];
};

const topMoverLimit = 10;

function formatPercent(value: number | null): string {
  if (value === null) {
    return "n/a";
  }

  return `${value >= 0 ? "+" : ""}${value.toFixed(1)}%`;
}

function formatSignedMoney(value: number): string {
  return `${value >= 0 ? "+" : ""}${formatMoney(value)}`;
}

function topRisers(rows: MoverRow[]): MoverRow[] {
  return rows
    .filter((row) => row.deltaList > 0)
    .sort((a, b) => b.deltaList - a.deltaList || a.key.localeCompare(b.key))
    .slice(0, topMoverLimit);
}

function topFallers(rows: MoverRow[]): MoverRow[] {
  return rows
    .filter((row) => row.deltaList < 0)
    .sort((a, b) => a.deltaList - b.deltaList || a.key.localeCompare(b.key))
    .slice(0, topMoverLimit);
}

export async function fetchTopMoversViewModel({
  fetcher = fetchCloudCost,
  invoiceMonth,
  now,
  preset,
}: FetchTopMoversOptions): Promise<TopMoversViewModel> {
  const activeWindow = resolveWindow(preset, now, invoiceMonth);
  const comparisonWindow = priorWindow(preset, now, invoiceMonth);
  const [currentResponse, priorResponse] = await Promise.all([
    fetcher(activeWindow.window, "service"),
    fetcher(comparisonWindow.window, "service"),
  ]);
  const current = sumByKey(
    currentResponse.data.sets,
    (name, item) => item.properties?.service ?? name,
  );
  const prior = sumByKey(
    priorResponse.data.sets,
    (name, item) => item.properties?.service ?? name,
  );
  const rows = periodCompare(current, prior);

  return {
    currentWindowLabel: activeWindow.label,
    fallers: topFallers(rows),
    priorWindowLabel: comparisonWindow.label,
    risers: topRisers(rows),
  };
}

function MoversTable({
  emptyMessage,
  rows,
  title,
}: {
  emptyMessage: string;
  rows: MoverRow[];
  title: string;
}) {
  return (
    <div className="top-movers-table-panel">
      <div className="top-movers-panel-heading">
        <h3>{title}</h3>
      </div>
      {rows.length === 0 ? (
        <p className="category-empty">{emptyMessage}</p>
      ) : (
        <table className="top-movers-table">
          <thead>
            <tr>
              <th scope="col">Service</th>
              <th scope="col">Current</th>
              <th scope="col">Prior</th>
              <th scope="col">Delta</th>
              <th scope="col">Pct</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.key}>
                <th scope="row">{row.key}</th>
                <td>{formatMoney(row.current.list)}</td>
                <td>{formatMoney(row.prior.list)}</td>
                <td>{formatSignedMoney(row.deltaList)}</td>
                <td>{formatPercent(row.pctList)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

export function TopMoversContent({
  data,
  error,
  loading,
  onRetry,
}: TopMoversContentProps) {
  if (error !== null) {
    return (
      <section className="top-movers-card" aria-label="Top movers">
        <div className="top-movers-heading">
          <div>
            <p className="eyebrow">Section 6</p>
            <h2>Top movers</h2>
          </div>
        </div>
        <div className="exec-pulse-error" role="alert">
          <strong>Failed to load top movers</strong>
          <span>{error}</span>
          <button onClick={onRetry} type="button">
            Retry
          </button>
        </div>
      </section>
    );
  }

  return (
    <section className="top-movers-card" aria-label="Top movers">
      <div className="top-movers-heading">
        <div>
          <p className="eyebrow">Section 6</p>
          <h2>Top movers</h2>
          <span>
            {data === null
              ? "Selected window"
              : `${data.currentWindowLabel} vs ${data.priorWindowLabel}`}
          </span>
        </div>
        {loading ? <span className="exec-pulse-loading">Loading...</span> : null}
      </div>

      {data === null ? (
        <p className="category-empty">Loading top movers...</p>
      ) : (
        <div className="top-movers-layout">
          <MoversTable
            emptyMessage="No rising service list costs for this comparison."
            rows={data.risers}
            title="Risers"
          />
          <MoversTable
            emptyMessage="No falling service list costs for this comparison."
            rows={data.fallers}
            title="Fallers"
          />
        </div>
      )}
    </section>
  );
}

export function TopMovers({
  fetcher = fetchCloudCost,
  invoiceMonth,
  now,
  preset,
}: TopMoversProps) {
  const [data, setData] = useState<TopMoversViewModel | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [refresh, setRefresh] = useState(0);

  const retry = useCallback(() => {
    setRefresh((current) => current + 1);
  }, []);

  useEffect(() => {
    let active = true;

    setLoading(true);
    setError(null);

    fetchTopMoversViewModel({
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
  }, [fetcher, invoiceMonth, now, preset, refresh]);

  return (
    <TopMoversContent
      data={data}
      error={error}
      loading={loading}
      onRetry={retry}
    />
  );
}
