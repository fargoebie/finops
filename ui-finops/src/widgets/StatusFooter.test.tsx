import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { StatusFooter } from "./StatusFooter";

describe("StatusFooter", () => {
  it("renders cloud cost status fields and unmapped service count", () => {
    const html = renderToStaticMarkup(
      <StatusFooter
        currentWindow={{
          label: "June 2026",
          window: "2026-06-01T00:00:00Z,2026-07-01T00:00:00Z",
        }}
        priorWindow={{
          label: "May 2026",
          window: "2026-05-01T00:00:00Z,2026-06-01T00:00:00Z",
        }}
        statusRow={{
          connectionStatus: "Connection Successful",
          lastRun: "2026-07-24T00:00:00Z",
          nextRun: "2026-07-25T00:00:00Z",
        }}
        unmappedCount={2}
      />,
    );

    expect(html).toContain("Connection Successful");
    expect(html).toContain("June 2026");
    expect(html).toContain("May 2026");
    expect(html).toContain("2026-07-24T00:00:00Z");
    expect(html).toContain("2026-07-25T00:00:00Z");
    expect(html).toContain("Unmapped services");
    expect(html).toContain(">2</strong>");
  });
});
