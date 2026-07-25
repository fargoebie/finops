import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";

const mockedInformData = vi.hoisted(() => ({
  value: {
    activeWindow: {
      error: null,
      loading: false,
      total: { list: 1250000, net: 980000 },
      unmappedCount: 3,
    },
    connectionStatus: "Connection Successful",
    currentWindow: {
      label: "June 2026",
      window: "2026-06-01T00:00:00Z,2026-07-01T00:00:00Z",
    },
    execPulse: {
      data: null,
      error: null,
      loading: false,
      retry: () => undefined,
    },
    priorWindow: {
      label: "May 2026",
      window: "2026-05-01T00:00:00Z,2026-06-01T00:00:00Z",
    },
    status: null,
    statusError: null,
    statusLoading: false,
    statusRow: {
      connectionStatus: "Connection Successful",
      lastRun: "2026-07-24T00:00:00Z",
      nextRun: "2026-07-25T00:00:00Z",
    },
    unmappedCount: 3,
  },
}));

vi.mock("./hooks/useInformData", () => ({
  useInformData: () => mockedInformData.value,
}));

import App, { previousCalendarMonth } from "./App";

describe("previousCalendarMonth", () => {
  it("returns the prior UTC calendar month as YYYY-MM", () => {
    expect(previousCalendarMonth(new Date("2026-07-24T15:00:00Z"))).toBe("2026-06");
  });

  it("rolls back across year boundaries", () => {
    expect(previousCalendarMonth(new Date("2026-01-03T00:00:00Z"))).toBe("2025-12");
  });
});

describe("App", () => {
  it("wires the credits and top movers widgets plus footer unmapped count", () => {
    const html = renderToStaticMarkup(
      <App
        initialInvoiceMonth="2026-06"
        initialPreset="invoice"
        now={new Date("2026-07-24T15:00:00Z")}
      />,
    );

    expect(html).toContain("Credits &amp; net vs list");
    expect(html).toContain("Top movers");
    expect(html).not.toContain("Awaiting data widgets");
    expect(html).not.toContain("$0.00");
    expect(html).toContain("$1,250,000 list");
    expect(html).toContain("$980,000 net");
    expect(html).toContain("Unmapped services");
    expect(html).toContain(">3</strong>");
  });
});
