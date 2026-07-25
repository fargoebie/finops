import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { CloudCostResponse } from "../types/cloudCost";
import {
  ProjectShowbackContent,
  fetchProjectShowbackViewModel,
  type ProjectShowbackViewModel,
} from "./ProjectShowback";

function accountResponse(): CloudCostResponse {
  return {
    code: 200,
    data: {
      sets: [
        {
          cloudCosts: {
            alpha: {
              listCost: { cost: 100 },
              netCost: { cost: 80 },
              properties: { accountID: "alpha-project" },
            },
            unallocated: {
              listCost: { cost: 1000 },
              netCost: { cost: 1000 },
              properties: { accountID: "__unallocated__" },
            },
            zeta: {
              listCost: { cost: 25 },
              netCost: { cost: 20 },
              properties: { accountID: "zeta-project" },
            },
          },
        },
      ],
    },
  };
}

function accountServiceResponse(): CloudCostResponse {
  return {
    code: 200,
    data: {
      sets: [
        {
          cloudCosts: {
            alphaCompute: {
              listCost: { cost: 60 },
              netCost: { cost: 48 },
              properties: { accountID: "alpha-project", service: "Compute Engine" },
            },
            alphaInvoice: {
              listCost: { cost: 40 },
              netCost: { cost: 32 },
              properties: { accountID: "alpha-project", service: "Invoice" },
            },
            zetaCompute: {
              listCost: { cost: 25 },
              netCost: { cost: 20 },
              properties: { accountID: "zeta-project", service: "Compute Engine" },
            },
          },
        },
      ],
    },
  };
}

describe("fetchProjectShowbackViewModel", () => {
  it("fetches project and project-service costs for the active window", async () => {
    const calls: Array<{ aggregate: string; window: string }> = [];

    const viewModel = await fetchProjectShowbackViewModel({
      fetcher: async (window, aggregate) => {
        calls.push({ aggregate, window });
        return aggregate === "accountID" ? accountResponse() : accountServiceResponse();
      },
      invoiceMonth: "2026-06",
      now: new Date("2026-07-24T15:00:00Z"),
      preset: "invoice",
    });

    expect(calls).toEqual([
      {
        aggregate: "accountID",
        window: "2026-06-01T00:00:00Z,2026-07-01T00:00:00Z",
      },
      {
        aggregate: "accountID,service",
        window: "2026-06-01T00:00:00Z,2026-07-01T00:00:00Z",
      },
    ]);
    expect(viewModel.projects.map((project) => [project.accountID, project.list, project.net])).toEqual([
      ["alpha-project", 100, 80],
      ["zeta-project", 25, 20],
      ["__unallocated__", 1000, 1000],
    ]);
    expect(viewModel.serviceRows.map((row) => [row.accountID, row.service, row.list, row.net])).toEqual([
      ["alpha-project", "Compute Engine", 60, 48],
      ["alpha-project", "Invoice", 40, 32],
      ["zeta-project", "Compute Engine", 25, 20],
    ]);
    expect(viewModel.hasBillingBucket).toBe(true);
  });
});

describe("ProjectShowbackContent", () => {
  const data: ProjectShowbackViewModel = {
    hasBillingBucket: true,
    projects: [
      { accountID: "alpha-project", label: "alpha-project", list: 100, net: 80 },
      { accountID: "zeta-project", label: "zeta-project", list: 25, net: 20 },
      { accountID: "__unallocated__", label: "__unallocated__", list: 1000, net: 1000 },
    ],
    serviceRows: [
      {
        accountID: "alpha-project",
        bucketId: "compute",
        bucketLabel: "Compute & runtime",
        list: 60,
        net: 48,
        service: "Compute Engine",
      },
      {
        accountID: "zeta-project",
        bucketId: "compute",
        bucketLabel: "Compute & runtime",
        list: 25,
        net: 20,
        service: "Compute Engine",
      },
    ],
    topN: 15,
    windowLabel: "June 2026",
  };

  it("renders project bars, list/net table values, and billing footnote", () => {
    const html = renderToStaticMarkup(
      <ProjectShowbackContent
        data={data}
        error={null}
        loading={false}
        onRetry={() => undefined}
        onSelectedProjectIDChange={() => undefined}
        selectedProjectID="alpha-project"
      />,
    );

    expect(html).toContain("Project showback");
    expect(html).toContain("Top 15 projects by list cost");
    expect(html).toContain("alpha-project");
    expect(html).toContain("$100.00");
    expect(html).toContain("$80.00");
    expect(html).toContain("__unallocated__");
    expect(html).toContain("Billing adjustments are present");
  });

  it("drills the selected project to its service rows", () => {
    const html = renderToStaticMarkup(
      <ProjectShowbackContent
        data={data}
        error={null}
        loading={false}
        onRetry={() => undefined}
        onSelectedProjectIDChange={() => undefined}
        selectedProjectID="zeta-project"
      />,
    );

    expect(html).toContain("Services for zeta-project");
    expect(html).toContain("Compute Engine");
    expect(html).toContain("$25.00");
    expect(html).not.toContain("$60.00");
  });
});
