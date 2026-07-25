import type { WindowPreset } from "../types/viewModels";

export type ResolvedWindow = {
  window: string;
  label: string;
};

const rollingDays = {
  "7d": 7,
  "30d": 30,
} as const;

export function resolveWindow(
  preset: WindowPreset,
  now: Date,
  invoiceMonth?: string,
): ResolvedWindow {
  switch (preset) {
    case "7d":
    case "30d":
      return { window: preset, label: rollingLabel(preset) };
    case "mtd":
      return {
        window: range(
          utcMonthStart(now.getUTCFullYear(), now.getUTCMonth()),
          addUtcDays(startOfUtcDay(now), 1),
        ),
        label: "Month to date",
      };
    case "invoice": {
      const month = parseInvoiceMonth(invoiceMonth, now);
      return {
        window: monthRange(month.year, month.monthIndex),
        label: monthLabel(month.year, month.monthIndex),
      };
    }
  }
}

export function priorWindow(
  preset: WindowPreset,
  now: Date,
  invoiceMonth?: string,
): ResolvedWindow {
  switch (preset) {
    case "7d":
    case "30d": {
      const days = rollingDays[preset];
      const currentEnd = startOfUtcDay(now);
      // OpenCost rolling windows are pass-through for current queries, but the
      // implied current range starts at today 00:00 UTC minus the preset days.
      const currentStart = addUtcDays(currentEnd, -days);
      return {
        window: range(addUtcDays(currentStart, -days), currentStart),
        label: `Prior ${days} days`,
      };
    }
    case "mtd": {
      const currentStart = utcMonthStart(now.getUTCFullYear(), now.getUTCMonth());
      const currentEnd = addUtcDays(startOfUtcDay(now), 1);
      const elapsedDays = daysBetween(currentStart, currentEnd);
      const previousStart = utcMonthStart(now.getUTCFullYear(), now.getUTCMonth() - 1);
      return {
        window: range(previousStart, addUtcDays(previousStart, elapsedDays)),
        label: "Prior month to date",
      };
    }
    case "invoice": {
      const month = parseInvoiceMonth(invoiceMonth, now);
      const prior = shiftMonth(month.year, month.monthIndex, -1);
      return {
        window: monthRange(prior.year, prior.monthIndex),
        label: monthLabel(prior.year, prior.monthIndex),
      };
    }
  }
}

function rollingLabel(preset: "7d" | "30d"): string {
  return preset === "7d" ? "Last 7 days" : "Last 30 days";
}

function monthRange(year: number, monthIndex: number): string {
  return range(utcMonthStart(year, monthIndex), utcMonthStart(year, monthIndex + 1));
}

function range(start: Date, end: Date): string {
  return `${utcTimestamp(start)},${utcTimestamp(end)}`;
}

function utcTimestamp(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

function utcMonthStart(year: number, monthIndex: number): Date {
  return new Date(Date.UTC(year, monthIndex, 1, 0, 0, 0));
}

function startOfUtcDay(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
}

function addUtcDays(date: Date, days: number): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate() + days));
}

function daysBetween(start: Date, end: Date): number {
  return Math.round((end.getTime() - start.getTime()) / 86_400_000);
}

function parseInvoiceMonth(
  invoiceMonth: string | undefined,
  now: Date,
): { year: number; monthIndex: number } {
  if (invoiceMonth === undefined) {
    return { year: now.getUTCFullYear(), monthIndex: now.getUTCMonth() };
  }

  const match = /^(\d{4})-(\d{2})$/.exec(invoiceMonth);
  if (match === null) {
    throw new Error(`Invalid invoiceMonth "${invoiceMonth}"; expected YYYY-MM`);
  }

  const year = Number(match[1]);
  const month = Number(match[2]);
  if (month < 1 || month > 12) {
    throw new Error(`Invalid invoiceMonth "${invoiceMonth}"; expected YYYY-MM`);
  }

  return { year, monthIndex: month - 1 };
}

function shiftMonth(year: number, monthIndex: number, offset: number): { year: number; monthIndex: number } {
  const shifted = utcMonthStart(year, monthIndex + offset);
  return { year: shifted.getUTCFullYear(), monthIndex: shifted.getUTCMonth() };
}

function monthLabel(year: number, monthIndex: number): string {
  return utcMonthStart(year, monthIndex).toLocaleString("en-US", {
    month: "long",
    timeZone: "UTC",
    year: "numeric",
  });
}
