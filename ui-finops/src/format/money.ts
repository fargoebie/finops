const wholeDollarFormatter = new Intl.NumberFormat("en-US", {
  currency: "USD",
  maximumFractionDigits: 0,
  style: "currency",
});

const centsFormatter = new Intl.NumberFormat("en-US", {
  currency: "USD",
  maximumFractionDigits: 2,
  minimumFractionDigits: 2,
  style: "currency",
});

export function formatMoney(n: number): string {
  return Math.abs(n) < 1000 ? centsFormatter.format(n) : wholeDollarFormatter.format(n);
}
