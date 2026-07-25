import type { Money, ServiceCost } from "../types/viewModels";

export type DiscountRow = ServiceCost & {
  delta: number;
  pct: number | null;
  highlight: boolean;
};

function discountPct(money: Money): number | null {
  if (money.list === 0) {
    return null;
  }
  return ((money.list - money.net) / money.list) * 100;
}

export function discountRows(
  byService: Map<string, Money>,
  highlightPct: number,
): DiscountRow[] {
  const rows: DiscountRow[] = [];

  for (const [service, money] of byService) {
    const delta = money.list - money.net;
    if (delta === 0) {
      continue;
    }

    const pct = discountPct(money);
    rows.push({
      service,
      money,
      bucketId: "other",
      delta,
      pct,
      highlight: pct !== null && pct >= highlightPct,
    });
  }

  return rows.sort((a, b) => Math.abs(b.delta) - Math.abs(a.delta));
}
