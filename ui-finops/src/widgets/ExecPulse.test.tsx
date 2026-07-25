import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { ExecPulse } from "./ExecPulse";

describe("ExecPulse", () => {
  it("renders list and net cost tiles with WoW deltas", () => {
    const html = renderToStaticMarkup(
      <ExecPulse
        data={{
          mtd: { list: 1000, net: 800 },
          priorSevenDay: { list: 350, net: 400 },
          rollingSevenDay: { list: 700, net: 500 },
          rollingThirtyDay: { list: 3000, net: 2400 },
          wow: { list: 100, net: 25 },
        }}
        error={null}
        loading={false}
        onRetry={() => undefined}
      />,
    );

    expect(html).toContain("Executive snapshot");
    expect(html).toContain("Month to date");
    expect(html).toContain("$1,000");
    expect(html).toContain("$800.00");
    expect(html).toContain("Last 7 days");
    expect(html).toContain("$700.00");
    expect(html).toContain("Last 30 days");
    expect(html).toContain("$3,000");
    expect(html).toContain("Week over week");
    expect(html).toContain("+100.0%");
    expect(html).toContain("+25.0%");
  });

  it("renders section error with retry action", () => {
    const html = renderToStaticMarkup(
      <ExecPulse
        data={null}
        error="HTTP 503"
        loading={false}
        onRetry={() => undefined}
      />,
    );

    expect(html).toContain("Failed to load exec pulse");
    expect(html).toContain("Retry");
  });
});
