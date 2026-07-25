import { useCallback, useEffect, useMemo, useState } from "react";
import { fetchCloudCost } from "../api/cloudCost";
import { formatMoney } from "../format/money";
import { loadCategoryMap, resolveBucket, type CategoryMap } from "../transforms/bucketize";
import { resolveWindow } from "../transforms/windows";
import type { CloudCostItem, CloudCostResponse } from "../types/cloudCost";
import type { Money, WindowPreset } from "../types/viewModels";

type FetchCloudCost = (
  window: string,
  aggregate: string,
) => Promise<CloudCostResponse>;

type FetchProjectShowbackOptions = {
  categoryMap?: CategoryMap;
  fetcher?: FetchCloudCost;
  invoiceMonth: string;
  now: Date;
  preset: WindowPreset;
};

type ProjectShowbackProps = {
  fetcher?: FetchCloudCost;
  invoiceMonth: string;
  now: Date;
  preset: WindowPreset;
};

type ProjectShowbackContentProps = {
  data: ProjectShowbackViewModel | null;
  error: string | null;
  loading: boolean;
  onRetry: () => void;
  onSelectedProjectIDChange: (projectID: string) => void;
  selectedProjectID: string | null;
};

export type ProjectShowbackProjectRow = {
  accountID: string;
  label: string;
  list: number;
  net: number;
};

export type ProjectShowbackServiceRow = {
  accountID: string;
  bucketId: string;
  bucketLabel: string;
  list: number;
  net: number;
  service: string;
};

export type ProjectShowbackViewModel = {
  hasBillingBucket: boolean;
  projects: ProjectShowbackProjectRow[];
  serviceRows: ProjectShowbackServiceRow[];
  topN: number;
  windowLabel: string;
};

const defaultTopN = 15;
const unallocatedAccountID = "__unallocated__";

function addMoney(a: Money, b: Money): Money {
  return { list: a.list + b.list, net: a.net + b.net };
}

function itemMoney(item: CloudCostItem): Money {
  return {
    list: item.listCost?.cost ?? 0,
    net: item.netCost?.cost ?? 0,
  };
}

function normalizedValue(value: string | undefined): string | null {
  const trimmed = value?.trim() ?? "";
  return trimmed === "" ? null : trimmed;
}

function accountIDFor(name: string, item: CloudCostItem): string {
  return normalizedValue(item.properties?.accountID) ?? normalizedValue(name) ?? unallocatedAccountID;
}

function serviceFor(name: string, item: CloudCostItem): string {
  return normalizedValue(item.properties?.service) ?? normalizedValue(name) ?? "Unknown service";
}

function projectSort(a: ProjectShowbackProjectRow, b: ProjectShowbackProjectRow): number {
  if (a.accountID === unallocatedAccountID && b.accountID !== unallocatedAccountID) {
    return 1;
  }
  if (b.accountID === unallocatedAccountID && a.accountID !== unallocatedAccountID) {
    return -1;
  }

  return b.list - a.list || a.accountID.localeCompare(b.accountID);
}

function firstSelectableProject(projects: ProjectShowbackProjectRow[]): ProjectShowbackProjectRow | null {
  return (
    projects.find((project) => project.accountID !== unallocatedAccountID) ??
    projects[0] ??
    null
  );
}

function visibleProjectsFor(data: ProjectShowbackViewModel | null): ProjectShowbackProjectRow[] {
  if (data === null) {
    return [];
  }

  const unallocated = data.projects.find((project) => project.accountID === unallocatedAccountID);
  const allocated = data.projects.filter((project) => project.accountID !== unallocatedAccountID);
  const allocatedLimit = unallocated === undefined ? data.topN : Math.max(0, data.topN - 1);

  return [
    ...allocated.slice(0, allocatedLimit),
    ...(unallocated === undefined ? [] : [unallocated]),
  ];
}

function activeProjectIDFor(
  data: ProjectShowbackViewModel | null,
  selectedProjectID: string | null,
): string | null {
  if (data === null || data.projects.length === 0) {
    return null;
  }
  if (selectedProjectID !== null && data.projects.some((project) => project.accountID === selectedProjectID)) {
    return selectedProjectID;
  }

  return firstSelectableProject(data.projects)?.accountID ?? null;
}

function serviceRowsFor(
  data: ProjectShowbackViewModel | null,
  activeProjectID: string | null,
): ProjectShowbackServiceRow[] {
  if (data === null || activeProjectID === null) {
    return [];
  }

  return data.serviceRows.filter((row) => row.accountID === activeProjectID);
}

function projectRowsFrom(response: CloudCostResponse): ProjectShowbackProjectRow[] {
  const totals = new Map<string, Money>();

  for (const set of response.data.sets) {
    for (const [name, item] of Object.entries(set.cloudCosts ?? {})) {
      const accountID = accountIDFor(name, item);
      totals.set(accountID, addMoney(totals.get(accountID) ?? { list: 0, net: 0 }, itemMoney(item)));
    }
  }

  return [...totals.entries()]
    .map(([accountID, money]) => ({
      accountID,
      label: accountID,
      list: money.list,
      net: money.net,
    }))
    .sort(projectSort);
}

function serviceRowsFrom(
  response: CloudCostResponse,
  categoryMap: CategoryMap,
): { hasBillingBucket: boolean; rows: ProjectShowbackServiceRow[] } {
  const bucketLabels = new Map(
    categoryMap.buckets.map((bucket) => [bucket.id, bucket.label] as const),
  );
  const totals = new Map<
    string,
    {
      accountID: string;
      bucketId: string;
      bucketLabel: string;
      money: Money;
      service: string;
    }
  >();
  let hasBillingBucket = false;

  for (const set of response.data.sets) {
    for (const [name, item] of Object.entries(set.cloudCosts ?? {})) {
      const accountID = accountIDFor(name, item);
      const service = serviceFor(name, item);
      const bucket = resolveBucket(service, categoryMap);
      const key = `${accountID}\u0000${service}`;
      const current = totals.get(key);
      const nextMoney = addMoney(current?.money ?? { list: 0, net: 0 }, itemMoney(item));
      const bucketLabel = bucketLabels.get(bucket.bucketId) ?? bucket.bucketId;

      hasBillingBucket = hasBillingBucket || bucket.bucketId === "billing";
      totals.set(key, {
        accountID,
        bucketId: bucket.bucketId,
        bucketLabel,
        money: nextMoney,
        service,
      });
    }
  }

  const rows = [...totals.values()].map((row) => ({
    accountID: row.accountID,
    bucketId: row.bucketId,
    bucketLabel: row.bucketLabel,
    list: row.money.list,
    net: row.money.net,
    service: row.service,
  }));

  return {
    hasBillingBucket,
    rows,
  };
}

export async function fetchProjectShowbackViewModel({
  categoryMap = loadCategoryMap(),
  fetcher = fetchCloudCost,
  invoiceMonth,
  now,
  preset,
}: FetchProjectShowbackOptions): Promise<ProjectShowbackViewModel> {
  const activeWindow = resolveWindow(preset, now, invoiceMonth);
  const [projectResponse, accountServiceResponse] = await Promise.all([
    fetcher(activeWindow.window, "accountID"),
    fetcher(activeWindow.window, "accountID,service"),
  ]);
  const projects = projectRowsFrom(projectResponse);
  const projectOrder = new Map(projects.map((project, index) => [project.accountID, index] as const));
  const serviceModel = serviceRowsFrom(accountServiceResponse, categoryMap);
  const serviceRows = serviceModel.rows.sort((a, b) => {
    const accountOrder = (projectOrder.get(a.accountID) ?? projects.length) - (projectOrder.get(b.accountID) ?? projects.length);
    return accountOrder || b.list - a.list || a.service.localeCompare(b.service);
  });

  return {
    hasBillingBucket: serviceModel.hasBillingBucket,
    projects,
    serviceRows,
    topN: categoryMap.defaults.topN ?? defaultTopN,
    windowLabel: activeWindow.label,
  };
}

export function ProjectShowbackContent({
  data,
  error,
  loading,
  onRetry,
  onSelectedProjectIDChange,
  selectedProjectID,
}: ProjectShowbackContentProps) {
  if (error !== null) {
    return (
      <section className="project-showback-card" aria-label="Project showback">
        <div className="project-showback-heading">
          <div>
            <p className="eyebrow">Section 4</p>
            <h2>Project showback</h2>
          </div>
        </div>
        <div className="exec-pulse-error" role="alert">
          <strong>Failed to load project showback</strong>
          <span>{error}</span>
          <button onClick={onRetry} type="button">
            Retry
          </button>
        </div>
      </section>
    );
  }

  const activeProjectID = activeProjectIDFor(data, selectedProjectID);
  const visibleProjects = visibleProjectsFor(data);
  const drillRows = serviceRowsFor(data, activeProjectID);
  const maxProjectList = Math.max(1, ...visibleProjects.map((project) => project.list));

  return (
    <section className="project-showback-card" aria-label="Project showback">
      <div className="project-showback-heading">
        <div>
          <p className="eyebrow">Section 4</p>
          <h2>Project showback</h2>
          <span>{data?.windowLabel ?? "Selected window"}</span>
        </div>
        {loading ? <span className="exec-pulse-loading">Loading...</span> : null}
      </div>

      <div className="project-showback-layout">
        <div className="project-bars-panel">
          <div className="project-showback-panel-heading">
            <div>
              <h3>Top {data?.topN ?? defaultTopN} projects by list cost</h3>
              <p>Click a project to drill into services. Tooltips include net cost.</p>
            </div>
          </div>
          {data === null ? (
            <p className="category-empty">Loading project showback...</p>
          ) : visibleProjects.length === 0 ? (
            <p className="category-empty">No project costs for this window.</p>
          ) : (
            <ul aria-label="Project list cost bars" className="project-bars-list">
              {visibleProjects.map((project) => {
                const width = `${Math.max(4, (project.list / maxProjectList) * 100)}%`;
                return (
                  <li key={project.accountID}>
                    <button
                      aria-pressed={activeProjectID === project.accountID}
                      className={activeProjectID === project.accountID ? "active" : undefined}
                      onClick={() => onSelectedProjectIDChange(project.accountID)}
                      title={`${project.label}: ${formatMoney(project.list)} list / ${formatMoney(project.net)} net`}
                      type="button"
                    >
                      <span className="project-bar-row">
                        <strong>{project.label}</strong>
                        <span>
                          {formatMoney(project.list)} list / {formatMoney(project.net)} net
                        </span>
                      </span>
                      <span className="project-bar-track" aria-hidden="true">
                        <span style={{ width }} />
                      </span>
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </div>

        <div className="project-table-panel">
          <div className="project-showback-panel-heading">
            <h3>Project cost table</h3>
          </div>
          {data === null ? (
            <p className="category-empty">Loading project table...</p>
          ) : visibleProjects.length === 0 ? (
            <p className="category-empty">No project costs for this window.</p>
          ) : (
            <table className="project-showback-table">
              <thead>
                <tr>
                  <th scope="col">Project</th>
                  <th scope="col">List</th>
                  <th scope="col">Net</th>
                </tr>
              </thead>
              <tbody>
                {visibleProjects.map((project) => (
                  <tr key={project.accountID}>
                    <th scope="row">
                      <button
                        aria-pressed={activeProjectID === project.accountID}
                        onClick={() => onSelectedProjectIDChange(project.accountID)}
                        type="button"
                      >
                        {project.label}
                      </button>
                    </th>
                    <td>{formatMoney(project.list)}</td>
                    <td>{formatMoney(project.net)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {data?.hasBillingBucket ? (
            <p className="project-showback-footnote">
              Billing adjustments are present in the overall project mix; review invoice rows
              separately from operating service spend.
            </p>
          ) : null}
        </div>
      </div>

      <div className="project-drill-panel">
        <div className="project-showback-panel-heading">
          <div>
            <p className="eyebrow">Project drill</p>
            <h3>Services for {activeProjectID ?? "selected project"}</h3>
          </div>
        </div>
        {data === null ? (
          <p className="category-empty">Loading project services...</p>
        ) : activeProjectID === null ? (
          <p className="category-empty">Select a project to see services.</p>
        ) : drillRows.length === 0 ? (
          <p className="category-empty">No services found for this project.</p>
        ) : (
          <table className="project-showback-table">
            <thead>
              <tr>
                <th scope="col">Service</th>
                <th scope="col">List</th>
                <th scope="col">Net</th>
                <th scope="col">Bucket label</th>
              </tr>
            </thead>
            <tbody>
              {drillRows.map((row) => (
                <tr key={`${row.accountID}:${row.service}`}>
                  <th scope="row">{row.service}</th>
                  <td>{formatMoney(row.list)}</td>
                  <td>{formatMoney(row.net)}</td>
                  <td>{row.bucketLabel}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </section>
  );
}

export function ProjectShowback({
  fetcher = fetchCloudCost,
  invoiceMonth,
  now,
  preset,
}: ProjectShowbackProps) {
  const [data, setData] = useState<ProjectShowbackViewModel | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [refresh, setRefresh] = useState(0);
  const [selectedProjectID, setSelectedProjectID] = useState<string | null>(null);
  const categoryMap = useMemo(() => loadCategoryMap(), []);

  const retry = useCallback(() => {
    setRefresh((current) => current + 1);
  }, []);

  useEffect(() => {
    let active = true;

    setLoading(true);
    setError(null);

    fetchProjectShowbackViewModel({
      categoryMap,
      fetcher,
      invoiceMonth,
      now,
      preset,
    })
      .then((viewModel) => {
        if (active) {
          setData(viewModel);
          setSelectedProjectID((current) => {
            if (current !== null && viewModel.projects.some((project) => project.accountID === current)) {
              return current;
            }

            return firstSelectableProject(viewModel.projects)?.accountID ?? null;
          });
        }
      })
      .catch((caught: unknown) => {
        if (active) {
          setError(caught instanceof Error ? caught.message : String(caught));
          setData(null);
          setSelectedProjectID(null);
        }
      })
      .finally(() => {
        if (active) {
          setLoading(false);
        }
      });

    return () => {
      active = false;
    };
  }, [categoryMap, fetcher, invoiceMonth, now, preset, refresh]);

  return (
    <ProjectShowbackContent
      data={data}
      error={error}
      loading={loading}
      onRetry={retry}
      onSelectedProjectIDChange={setSelectedProjectID}
      selectedProjectID={selectedProjectID}
    />
  );
}
