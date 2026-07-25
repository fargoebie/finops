import "./App.css";
import { useState } from "react";
import { formatMoney } from "./format/money";
import { useInformData } from "./hooks/useInformData";
import type { WindowPreset } from "./types/viewModels";
import { CategoryMix } from "./widgets/CategoryMix";
import { ExecPulse } from "./widgets/ExecPulse";
import { ServiceDrivers } from "./widgets/ServiceDrivers";
import { StatusFooter } from "./widgets/StatusFooter";

const presets: Array<{ label: string; value: WindowPreset }> = [
  { label: "7d", value: "7d" },
  { label: "30d", value: "30d" },
  { label: "MTD", value: "mtd" },
  { label: "Invoice", value: "invoice" },
];

const sections = [
  "4. Project showback",
  "5. Credits & net vs list",
  "6. Top movers",
] as const;

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

  if (informData.connectionStatus !== "Connection Successful") {
    return (
      <main className="status-panel-shell">
        <section className="status-panel" aria-live="polite">
          <p className="eyebrow">Cloud cost connection</p>
          <h1>
            {informData.statusLoading
              ? "Checking connection status"
              : "Cloud cost data is not ready"}
          </h1>
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

  return (
    <main className="app-shell">
      <header className="app-header">
        <div>
          <p className="eyebrow">GCP FinOps</p>
          <h1>OpenCost Inform</h1>
          <p>
            Focused cloud cost review for the selected window. Detailed data
            widgets will fill these regions as subsequent tasks land.
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
          <span className="summary-label">Starting total</span>
          <strong>{formatMoney(0)}</strong>
          <span>Awaiting data widgets</span>
        </div>
      </section>

      <div className="placeholder-grid">
        <ExecPulse
          data={informData.execPulse.data}
          error={informData.execPulse.error}
          loading={informData.execPulse.loading}
          onRetry={informData.execPulse.retry}
        />
        <CategoryMix invoiceMonth={invoiceMonth} now={appNow} preset={preset} />
        <ServiceDrivers invoiceMonth={invoiceMonth} now={appNow} preset={preset} />
        {sections.map((title) => (
          <section className="placeholder-card" key={title}>
            <p className="eyebrow">Placeholder</p>
            <h2>{title}</h2>
            <p>Reserved for the Task 9+ data widget implementation.</p>
          </section>
        ))}
      </div>

      <StatusFooter
        currentWindow={informData.currentWindow}
        priorWindow={informData.priorWindow}
        statusRow={informData.statusRow}
      />
    </main>
  );
}
