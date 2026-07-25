import "./App.css";
import { useState } from "react";
import { formatMoney } from "./format/money";
import { useInformData } from "./hooks/useInformData";
import type { WindowPreset } from "./types/viewModels";
import { CategoryMix } from "./widgets/CategoryMix";
import { CreditsNetVsList } from "./widgets/CreditsNetVsList";
import { ExecPulse } from "./widgets/ExecPulse";
import { ProjectShowback } from "./widgets/ProjectShowback";
import { ServiceDrivers } from "./widgets/ServiceDrivers";
import { StatusFooter } from "./widgets/StatusFooter";
import { TopMovers } from "./widgets/TopMovers";

const presets: Array<{ label: string; value: WindowPreset }> = [
  { label: "7d", value: "7d" },
  { label: "30d", value: "30d" },
  { label: "MTD", value: "mtd" },
  { label: "Invoice", value: "invoice" },
];

type AppProps = {
  initialInvoiceMonth?: string;
  initialPreset?: WindowPreset;
  now?: Date;
};

export function previousCalendarMonth(now = new Date()): string {
  const previous = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1));
  const year = previous.getUTCFullYear();
  const month = String(previous.getUTCMonth() + 1).padStart(2, "0");
  return `${year}-${month}`;
}

export default function App({
  initialInvoiceMonth,
  initialPreset = "7d",
  now,
}: AppProps = {}) {
  const [appNow] = useState(() => now ?? new Date());
  const [preset, setPreset] = useState<WindowPreset>(initialPreset);
  const [invoiceMonth, setInvoiceMonth] = useState(
    () => initialInvoiceMonth ?? previousCalendarMonth(appNow),
  );
  const informData = useInformData({ invoiceMonth, now: appNow, preset });

  if (
    !informData.statusLoading &&
    informData.connectionStatus !== "Connection Successful"
  ) {
    return (
      <main className="status-panel-shell">
        <section className="status-panel" aria-live="polite">
          <p className="eyebrow">Cloud cost connection</p>
          <h1>Cloud cost data is not ready</h1>
          <p>
            OpenCost reports cloud cost data only after the provider connection
            is healthy. The raw status payload is shown below for setup
            diagnostics.
          </p>
          {informData.statusError ? (
            <p className="status-error">Status fetch failed: {informData.statusError}</p>
          ) : null}
          <pre className="status-json">
            {JSON.stringify(informData.status?.data[0] ?? informData.status ?? {}, null, 2)}
          </pre>
        </section>
      </main>
    );
  }

  const windowTotal = informData.activeWindow.total;
  const windowTotalEmpty =
    !informData.activeWindow.loading &&
    windowTotal !== null &&
    windowTotal.list === 0 &&
    windowTotal.net === 0;

  return (
    <main className="app-shell">
      <header className="app-header">
        <div>
          <p className="eyebrow">GCP FinOps</p>
          <h1>OpenCost Inform</h1>
          <p>
            GCP billing costs for the selected window — list and net side by
            side, with GMP split out of the category mix.
          </p>
        </div>
        <div className="window-controls" aria-label="Window presets">
          <div className="preset-buttons">
            {presets.map((item) => (
              <button
                aria-pressed={preset === item.value}
                className={preset === item.value ? "active" : undefined}
                key={item.value}
                onClick={() => setPreset(item.value)}
                type="button"
              >
                {item.label}
              </button>
            ))}
          </div>
          {preset === "invoice" ? (
            <label className="month-picker">
              Invoice month
              <input
                onChange={(event) => setInvoiceMonth(event.target.value)}
                type="month"
                value={invoiceMonth}
              />
            </label>
          ) : null}
        </div>
      </header>

      <section className="window-summary" aria-label="Selected window">
        <div>
          <span className="summary-label">Current</span>
          <strong>{informData.currentWindow.label}</strong>
          <code>{informData.currentWindow.window}</code>
        </div>
        <div>
          <span className="summary-label">Window total</span>
          <strong>
            {informData.statusLoading || informData.activeWindow.loading
              ? "Loading…"
              : windowTotal
                ? `${formatMoney(windowTotal.list)} list`
                : "—"}
          </strong>
          <span>
            {informData.activeWindow.error
              ? `Failed to load total: ${informData.activeWindow.error}`
              : windowTotal
                ? `${formatMoney(windowTotal.net)} net`
                : informData.statusLoading
                  ? "Checking cloud cost connection…"
                  : "No total yet"}
          </span>
        </div>
      </section>

      {windowTotalEmpty ? (
        <section className="status-panel" aria-live="polite">
          <p className="eyebrow">Ingestion</p>
          <h2>No cost rows in this window yet</h2>
          <p>
            The connection is healthy, but OpenCost has not returned spend for
            the selected range. Redeploying the API sidecar clears the
            in-memory store until the next refresh (or an admin{" "}
            <code>/cloudCost/rebuild</code>). Prefer{" "}
            <code>DEPLOY_TARGET=ui</code> for SPA-only deploys, or run{" "}
            <code>./infra/scripts/deploy.sh rebuild-cloudcost</code>.
          </p>
        </section>
      ) : null}

      <div className="placeholder-grid">
        <ExecPulse
          data={informData.execPulse.data}
          error={informData.execPulse.error}
          loading={informData.execPulse.loading}
          onRetry={informData.execPulse.retry}
        />
        <CategoryMix invoiceMonth={invoiceMonth} now={appNow} preset={preset} />
        <ServiceDrivers invoiceMonth={invoiceMonth} now={appNow} preset={preset} />
        <ProjectShowback invoiceMonth={invoiceMonth} now={appNow} preset={preset} />
        <CreditsNetVsList invoiceMonth={invoiceMonth} now={appNow} preset={preset} />
        <TopMovers invoiceMonth={invoiceMonth} now={appNow} preset={preset} />
      </div>

      <StatusFooter
        currentWindow={informData.currentWindow}
        priorWindow={informData.priorWindow}
        statusRow={informData.statusRow}
        unmappedCount={informData.unmappedCount}
      />
    </main>
  );
}
