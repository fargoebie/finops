import { formatMoney } from "../format/money";
import type { ExecPulseTotals } from "../hooks/useInformData";
import type { Money } from "../types/viewModels";

type ExecPulseProps = {
  data: ExecPulseTotals | null;
  error: string | null;
  loading: boolean;
  onRetry: () => void;
};

type MoneyTileProps = {
  label: string;
  money: Money | null;
};

function MoneyTile({ label, money }: MoneyTileProps) {
  return (
    <article className="exec-pulse-tile">
      <h3>{label}</h3>
      <dl>
        <div>
          <dt>List</dt>
          <dd>{money === null ? "Loading..." : formatMoney(money.list)}</dd>
        </div>
        <div>
          <dt>Net</dt>
          <dd>{money === null ? "Loading..." : formatMoney(money.net)}</dd>
        </div>
      </dl>
    </article>
  );
}

function formatPercent(value: number | null): string {
  if (value === null) {
    return "\u2014";
  }

  return `${value >= 0 ? "+" : ""}${value.toFixed(1)}%`;
}

export function ExecPulse({ data, error, loading, onRetry }: ExecPulseProps) {
  if (error !== null) {
    return (
      <section className="exec-pulse-card" aria-label="Executive snapshot">
        <div className="exec-pulse-heading">
          <div>
            <p className="eyebrow">Section 1</p>
            <h2>Executive snapshot</h2>
          </div>
        </div>
        <div className="exec-pulse-error" role="alert">
          <strong>Failed to load exec pulse</strong>
          <span>{error}</span>
          <button onClick={onRetry} type="button">
            Retry
          </button>
        </div>
      </section>
    );
  }

  const tileData = loading ? null : data;

  return (
    <section className="exec-pulse-card" aria-label="Executive snapshot">
      <div className="exec-pulse-heading">
        <div>
          <p className="eyebrow">Section 1</p>
          <h2>Executive snapshot</h2>
        </div>
        {loading ? <span className="exec-pulse-loading">Loading...</span> : null}
      </div>

      <div className="exec-pulse-grid">
        <MoneyTile label="Month to date" money={tileData?.mtd ?? null} />
        <MoneyTile label="Last 7 days" money={tileData?.rollingSevenDay ?? null} />
        <MoneyTile label="Last 30 days" money={tileData?.rollingThirtyDay ?? null} />
        <article className="exec-pulse-tile">
          <h3>Week over week</h3>
          <dl>
            <div>
              <dt>List</dt>
              <dd>{formatPercent(tileData?.wow.list ?? null)}</dd>
            </div>
            <div>
              <dt>Net</dt>
              <dd>{formatPercent(tileData?.wow.net ?? null)}</dd>
            </div>
          </dl>
        </article>
      </div>
    </section>
  );
}
