# GCP FinOps Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Cloud Run `opencost-ui` ingress with a pure GCP FinOps Inform SPA at `/` that reads only `/model/cloudCost*` and shows list+net KPIs, expanded category mix (GMP-first), service/project drill-downs, credits, and top movers.

**Architecture:** Vite + React + TypeScript app in `ui-finops/`. Nginx serves the SPA on `:9090` and reverse-proxies `/model/` to the OpenCost API sidecar at `127.0.0.1:9003`. All Inform shaping (windows, bucketize, period compare, list+net) lives in `ui-finops/src/transforms/`. Deploy builds this image and pushes it to the existing Artifact Registry `opencost-ui` image name so Cloud Run container name stays stable.

**Tech Stack:** Vite 6, React 19, TypeScript 5, Vitest, Recharts, nginx:alpine (runtime image). OpenCost API unchanged. OpenTofu/deploy scripts under `infra/`.

**Spec:** `docs/superpowers/specs/2026-07-24-gcp-finops-dashboard-design.md`  
**Supersedes product intent in:** `docs/superpowers/plans/2026-07-24-gcp-finops-dashboard-mvp.md`

## Global Constraints

- Call **only** `/model/cloudCost*` — never `/allocation*`, `/customCost*`, or stock OpenCost UI routes
- Every monetary view-model is `{ list: number; net: number }`
- Window presets only: `7d` | `30d` | `mtd` | `invoice` (calendar month UTC); movers use prior equal-length period
- Category map single source: `ui-finops/config/gcp-category-map.json`
- No BFF; no budgets/anomalies/virtual tags in v1
- Do not commit secrets, `terraform.tfvars`, or `.superpowers/` session noise
- Signed-off commits (`Signed-off-by`)
- TDD for all `transforms/*` modules before widgets consume them

## File structure (create unless noted)

```
ui-finops/
  package.json
  tsconfig.json
  tsconfig.node.json
  vite.config.ts
  index.html
  Dockerfile
  nginx.conf
  config/gcp-category-map.json
  src/main.tsx
  src/App.tsx
  src/App.css
  src/vite-env.d.ts
  src/types/cloudCost.ts
  src/types/viewModels.ts
  src/api/cloudCost.ts
  src/transforms/windows.ts
  src/transforms/aggregate.ts
  src/transforms/bucketize.ts
  src/transforms/periodCompare.ts
  src/transforms/discount.ts
  src/transforms/*.test.ts
  src/widgets/ExecPulse.tsx
  src/widgets/CategoryMix.tsx
  src/widgets/ServiceDrivers.tsx
  src/widgets/ProjectShowback.tsx
  src/widgets/CreditsNetVsList.tsx
  src/widgets/TopMovers.tsx
  src/widgets/StatusFooter.tsx
  src/format/money.ts
infra/scripts/deploy.sh          (modify — build ui-finops instead of pulling ghcr UI)
infra/cloud_run.tf               (modify — drop OpenCost UI env; keep port 9090 + health)
infra/locals.tf                  (modify comments if needed)
infra/README.md, AGENTS.md       (modify smoke / UI description)
docs/finops/README.md            (point at ui-finops config)
```

---

### Task 1: Scaffold `ui-finops` + category map + Vitest

**Files:**
- Create: `ui-finops/package.json`, `ui-finops/tsconfig.json`, `ui-finops/tsconfig.node.json`, `ui-finops/vite.config.ts`, `ui-finops/index.html`, `ui-finops/src/main.tsx`, `ui-finops/src/vite-env.d.ts`, `ui-finops/config/gcp-category-map.json`
- Modify: `docs/finops/README.md` (link to `ui-finops/config/…` as source of truth)
- Modify: root or `ui-finops/.gitignore` — ignore `node_modules`, `dist`

**Interfaces:**
- Produces: npm scripts `dev`, `build`, `test`; category JSON importable as `../config/gcp-category-map.json`

- [ ] **Step 1: Create package.json**

```json
{
  "name": "ui-finops",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc -b && vite build",
    "preview": "vite preview",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "dependencies": {
    "react": "^19.0.0",
    "react-dom": "^19.0.0",
    "recharts": "^2.15.0"
  },
  "devDependencies": {
    "@types/react": "^19.0.0",
    "@types/react-dom": "^19.0.0",
    "@vitejs/plugin-react": "^4.3.4",
    "typescript": "~5.7.2",
    "vite": "^6.0.0",
    "vitest": "^3.0.0"
  }
}
```

- [ ] **Step 2: Add Vite + TS config**

`ui-finops/vite.config.ts`:

```ts
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 9090,
    proxy: { "/model": { target: "http://127.0.0.1:9003", changeOrigin: true, rewrite: (p) => p.replace(/^\/model/, "") } },
  },
  test: { environment: "node" },
});
```

`ui-finops/tsconfig.json` — standard Vite React `strict` app + `"resolveJsonModule": true`.  
`ui-finops/index.html` — root div `#root`, script `/src/main.tsx`.  
`ui-finops/src/main.tsx` — `createRoot` render `<App />` placeholder “GCP FinOps”.

- [ ] **Step 3: Copy category map**

```bash
cp docs/finops/gcp-category-map.json ui-finops/config/gcp-category-map.json
```

Update `docs/finops/README.md` to state **source of truth is `ui-finops/config/gcp-category-map.json`**.

- [ ] **Step 4: Install and verify**

```bash
cd ui-finops && npm install && npm test -- --passWithNoTests && npm run build
```

Expected: install OK; tests pass (none yet); build emits `dist/`.

- [ ] **Step 5: Commit**

```bash
git add ui-finops docs/finops/README.md
git commit -s -m "chore(ui-finops): scaffold Vite React app and category map"
```

---

### Task 2: Shared types

**Files:**
- Create: `ui-finops/src/types/cloudCost.ts`, `ui-finops/src/types/viewModels.ts`
- Test: none (types only) — consumed by Task 3+

**Interfaces:**
- Produces: `Money`, `CloudCostItem`, `CloudCostSet`, `CloudCostResponse`, `WindowPreset`, `ServiceCost`, `BucketCost`, `MoverRow`

- [ ] **Step 1: Write types**

```ts
// ui-finops/src/types/viewModels.ts
export type Money = { list: number; net: number };

export type WindowPreset = "7d" | "30d" | "mtd" | "invoice";

export type ServiceCost = {
  service: string;
  money: Money;
  bucketId: string;
  gmpSubId?: string;
};

export type BucketCost = {
  bucketId: string;
  label: string;
  money: Money;
};

export type MoverRow = {
  key: string;
  current: Money;
  prior: Money;
  deltaList: number;
  deltaNet: number;
  pctList: number | null;
  pctNet: number | null;
};
```

```ts
// ui-finops/src/types/cloudCost.ts
export type CostMetric = { cost: number; kubernetesPercent?: number };

export type CloudCostItem = {
  properties?: {
    provider?: string;
    accountID?: string;
    service?: string;
    category?: string;
    regionID?: string;
  };
  listCost?: CostMetric;
  netCost?: CostMetric;
};

export type CloudCostSet = {
  cloudCosts?: Record<string, CloudCostItem>;
  window?: { start?: string; end?: string };
  aggregationProperties?: string[];
};

export type CloudCostResponse = {
  code: number;
  data: { sets: CloudCostSet[]; window?: { start?: string; end?: string } };
};

export type CloudCostStatusRow = {
  connectionStatus?: string;
  lastRun?: string;
  nextRun?: string;
  coverage?: string;
  provider?: string;
};

export type CloudCostStatusResponse = {
  code: number;
  data: CloudCostStatusRow[];
};

export type ViewGraphResponse = {
  code: number;
  data: Array<{
    start: string;
    end: string;
    items: Array<{ name: string; value: number }>;
  }>;
};
```

- [ ] **Step 2: Commit**

```bash
git add ui-finops/src/types
git commit -s -m "feat(ui-finops): add cloud cost and view-model types"
```

---

### Task 3: `windows.ts` (TDD)

**Files:**
- Create: `ui-finops/src/transforms/windows.ts`
- Test: `ui-finops/src/transforms/windows.test.ts`

**Interfaces:**
- Produces:
  - `resolveWindow(preset: WindowPreset, now: Date, invoiceMonth?: string): { window: string; label: string }`
  - `priorWindow(preset: WindowPreset, now: Date, invoiceMonth?: string): { window: string; label: string }`
  - `invoiceMonth` format `YYYY-MM`

- [ ] **Step 1: Write failing tests**

```ts
import { describe, expect, it } from "vitest";
import { resolveWindow, priorWindow } from "./windows";

describe("resolveWindow", () => {
  const now = new Date("2026-07-24T15:00:00Z");

  it("maps 7d and 30d to OpenCost rolling windows", () => {
    expect(resolveWindow("7d", now).window).toBe("7d");
    expect(resolveWindow("30d", now).window).toBe("30d");
  });

  it("maps mtd to exclusive UTC month range", () => {
    expect(resolveWindow("mtd", now).window).toBe("2026-07-01T00:00:00Z,2026-07-25T00:00:00Z");
  });

  it("maps invoice month YYYY-MM to calendar month range", () => {
    expect(resolveWindow("invoice", now, "2026-06").window).toBe(
      "2026-06-01T00:00:00Z,2026-07-01T00:00:00Z",
    );
  });
});

describe("priorWindow", () => {
  const now = new Date("2026-07-24T15:00:00Z");

  it("prior 7d is the previous 7 days as an absolute range", () => {
    // 2026-07-10 → 2026-07-17 (day before current 7d start)
    const w = priorWindow("7d", now).window;
    expect(w).toBe("2026-07-10T00:00:00Z,2026-07-17T00:00:00Z");
  });

  it("prior invoice is previous calendar month", () => {
    expect(priorWindow("invoice", now, "2026-06").window).toBe(
      "2026-05-01T00:00:00Z,2026-06-01T00:00:00Z",
    );
  });
});
```

- [ ] **Step 2: Run tests — expect FAIL**

```bash
cd ui-finops && npm test -- src/transforms/windows.test.ts
```

Expected: FAIL cannot find module / resolveWindow not defined.

- [ ] **Step 3: Implement `windows.ts`**

Implement using UTC `Date.UTC` / `toISOString().replace(/\.\d{3}Z$/, "Z")`.  
For rolling `7d`/`30d` **current**: pass through `"7d"` / `"30d"`.  
For rolling **prior**: compute absolute ranges ending at start of current rolling window (today 00:00 UTC minus N days → today 00:00 UTC for current implied range; prior ends where current starts).  
Document the assumed current-range start in comments to match tests.

- [ ] **Step 4: Run tests — expect PASS**

```bash
cd ui-finops && npm test -- src/transforms/windows.test.ts
```

- [ ] **Step 5: Commit**

```bash
git add ui-finops/src/transforms/windows.ts ui-finops/src/transforms/windows.test.ts
git commit -s -m "feat(ui-finops): window presets and prior-period helpers"
```

---

### Task 4: `aggregate.ts` (TDD)

**Files:**
- Create: `ui-finops/src/transforms/aggregate.ts`
- Test: `ui-finops/src/transforms/aggregate.test.ts`

**Interfaces:**
- Consumes: `CloudCostSet[]`, `Money`
- Produces:
  - `sumSets(sets: CloudCostSet[]): Money`
  - `sumByKey(sets: CloudCostSet[], keyFn: (name: string, item: CloudCostItem) => string): Map<string, Money>`

- [ ] **Step 1: Write failing tests**

```ts
import { describe, expect, it } from "vitest";
import { sumSets, sumByKey } from "./aggregate";
import type { CloudCostSet } from "../types/cloudCost";

const sets: CloudCostSet[] = [
  {
    cloudCosts: {
      "Places API": { listCost: { cost: 10 }, netCost: { cost: 8 }, properties: { service: "Places API" } },
      "BigQuery": { listCost: { cost: 5 }, netCost: { cost: 5 }, properties: { service: "BigQuery" } },
    },
  },
  {
    cloudCosts: {
      "Places API": { listCost: { cost: 2 }, netCost: { cost: 1 }, properties: { service: "Places API" } },
    },
  },
];

describe("sumSets", () => {
  it("sums list and net across all items and days", () => {
    expect(sumSets(sets)).toEqual({ list: 17, net: 14 });
  });
});

describe("sumByKey", () => {
  it("groups by service property or map key", () => {
    const m = sumByKey(sets, (_n, item) => item.properties?.service ?? _n);
    expect(m.get("Places API")).toEqual({ list: 12, net: 9 });
    expect(m.get("BigQuery")).toEqual({ list: 5, net: 5 });
  });
});
```

- [ ] **Step 2: Run — expect FAIL**  
`npm test -- src/transforms/aggregate.test.ts`

- [ ] **Step 3: Implement** — treat missing `listCost`/`netCost` as `0`.

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit** — `feat(ui-finops): aggregate list+net across cloudCost sets`

---

### Task 5: `bucketize.ts` (TDD)

**Files:**
- Create: `ui-finops/src/transforms/bucketize.ts`
- Test: `ui-finops/src/transforms/bucketize.test.ts`
- Read: `ui-finops/config/gcp-category-map.json`

**Interfaces:**
- Consumes: `Map<string, Money>` from `sumByKey`, category map JSON
- Produces:
  - `loadCategoryMap(): CategoryMap` (import JSON)
  - `resolveBucket(service: string, map: CategoryMap): { bucketId: string; gmpSubId?: string }`
  - `bucketizeServices(byService: Map<string, Money>, map: CategoryMap): { buckets: BucketCost[]; services: ServiceCost[]; unmappedCount: number }`
  - `gmpSubMix(services: ServiceCost[], map: CategoryMap): BucketCost[]` (only GMP services, keyed by sub-bucket)

- [ ] **Step 1: Failing tests** covering Places→`gmp`+places, Invoice→`billing`, `Claude Fable 5`→`ai_ml` via pattern, `Totally Unknown`→`other` + unmappedCount, GMP sub-mix sums Places vs Geocoding.

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement** — exact `serviceToBucket` first, then `serviceNamePatterns` regex, else `defaults.unmappedBucket`. GMP sub from `gmpSubBuckets[].services` membership.

- [ ] **Step 4: Run — PASS**

- [ ] **Step 5: Commit** — `feat(ui-finops): expanded category bucketize with GMP sub-mix`

---

### Task 6: `periodCompare.ts` + `discount.ts` (TDD)

**Files:**
- Create: `ui-finops/src/transforms/periodCompare.ts`, `discount.ts`, matching `*.test.ts`

**Interfaces:**
- Produces:
  - `periodCompare(current: Map<string, Money>, prior: Map<string, Money>): MoverRow[]` sorted by `|deltaList|` desc
  - `discountRows(byService: Map<string, Money>, highlightPct: number): Array<ServiceCost & { delta: number; pct: number | null }>` where `delta = list - net`, `pct = list === 0 ? null : (delta/list)*100`, filter/sort by `|delta|`

- [ ] **Step 1–4:** TDD both modules (include divide-by-zero → `pct: null`; prior missing key → prior zeros).

- [ ] **Step 5: Commit** — `feat(ui-finops): period compare and net-vs-list discount rows`

---

### Task 7: API client

**Files:**
- Create: `ui-finops/src/api/cloudCost.ts`
- Test: `ui-finops/src/api/cloudCost.test.ts` (mock `fetch`)

**Interfaces:**
- Produces:
  - `const BASE = "/model"`
  - `fetchStatus(): Promise<CloudCostStatusResponse>`
  - `fetchCloudCost(window: string, aggregate: string): Promise<CloudCostResponse>`
  - `fetchViewGraph(window: string, aggregate: string): Promise<ViewGraphResponse>`

- [ ] **Step 1: Failing test** — mock fetch, assert URL `/model/cloudCost?window=7d&aggregate=service` and JSON parse.

- [ ] **Step 2: Implement** with `URLSearchParams`; throw on non-OK HTTP or `code >= 400`.

- [ ] **Step 3: Commit** — `feat(ui-finops): cloudCost API client`

---

### Task 8: App shell — presets, status gate, layout chrome

**Files:**
- Create: `ui-finops/src/App.tsx`, `ui-finops/src/App.css`, `ui-finops/src/format/money.ts`, `ui-finops/src/widgets/StatusFooter.tsx`
- Modify: `ui-finops/src/main.tsx` if needed

**Interfaces:**
- Produces: React state `preset`, `invoiceMonth` (`YYYY-MM`, default previous calendar month), `status`, parallel data loading hooks later widgets use via props or a thin `useInformData` hook in `src/hooks/useInformData.ts`

- [ ] **Step 1: Add `formatMoney(n: number): string`** using `Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 })` for large demogcp magnitudes (optional `maximumFractionDigits: 2` under $1000).

- [ ] **Step 2: Implement `App` header** with buttons `7d | 30d | MTD | Invoice` + `<input type="month">` visible when invoice selected.

- [ ] **Step 3: On mount, `fetchStatus`**. If first row `connectionStatus !== "Connection Successful"`, render full-page status panel only (show raw status JSON fields). Else render section placeholders 1–6 + `StatusFooter`.

- [ ] **Step 4: Manual** — `npm run dev`; with API down, status panel; with proxy to live, chrome renders.

- [ ] **Step 5: Commit** — `feat(ui-finops): app shell with window presets and status gate`

---

### Task 9: Widget — Exec pulse

**Files:**
- Create: `ui-finops/src/widgets/ExecPulse.tsx`
- Modify: `ui-finops/src/hooks/useInformData.ts` (create) to fetch MTD/7d/30d totals + prior 7d for WoW

**Interfaces:**
- Consumes: `sumSets`, `resolveWindow`, `priorWindow`, `fetchCloudCost`
- Props: `{ now: Date; invoiceMonth: string }` or data from hook

- [ ] **Step 1: Hook fetches** `aggregate=provider` (or `service` summed) for windows: mtd, 7d, 30d, prior 7d.

- [ ] **Step 2: Render 4 tiles** — MTD list+net, 7d list+net, 30d list+net, WoW Δ% list and net: `((cur-prior)/prior)*100` or `—` if prior list/net is 0.

- [ ] **Step 3: Section error boundary** — if fetch fails, show “Failed to load exec pulse” + Retry button.

- [ ] **Step 4: Commit** — `feat(ui-finops): ExecPulse list+net KPIs and WoW delta`

---

### Task 10: Widget — Category mix + GMP drill

**Files:**
- Create: `ui-finops/src/widgets/CategoryMix.tsx`

**Interfaces:**
- Consumes: `sumByKey`, `bucketizeServices`, `gmpSubMix`, `fetchCloudCost` for active preset window

- [ ] **Step 1: Fetch** `aggregate=service` for active window; bucketize.

- [ ] **Step 2: Recharts** `PieChart` (or stacked bar) of bucket **list** costs; legend/tooltip includes net; KPI text `GMP list % of total list`.

- [ ] **Step 3: GMP drill panel** — `gmpSubMix` bars for Places / Geocoding / etc. with list+net.

- [ ] **Step 4: Commit** — `feat(ui-finops): expanded category mix with GMP drill`

---

### Task 11: Widget — Service drivers

**Files:**
- Create: `ui-finops/src/widgets/ServiceDrivers.tsx`

**Interfaces:**
- Consumes: `fetchViewGraph`, `sumByKey`+`fetchCloudCost` for top-N table with list+net (not `view/table` alone)

- [ ] **Step 1: Line chart** from `view/graph` (values = list-oriented series); tooltip note that table has net.

- [ ] **Step 2: Top-15 table** columns: service, list, net, bucket label; sort by list desc; optional “GMP only” filter checkbox.

- [ ] **Step 3: Commit** — `feat(ui-finops): service drivers chart and top-N table`

---

### Task 12: Widget — Project showback

**Files:**
- Create: `ui-finops/src/widgets/ProjectShowback.tsx`

- [ ] **Step 1: Fetch** `aggregate=accountID`; horizontal bar of top projects by list; show net in tooltip/table.

- [ ] **Step 2: Click project** → client filter of `aggregate=accountID,service` response (second fetch) for that project’s services.

- [ ] **Step 3: Put `__unallocated__` last.** Footnote if billing bucket present in overall mix.

- [ ] **Step 4: Commit** — `feat(ui-finops): project showback by accountID`

---

### Task 13: Widget — Credits & top movers

**Files:**
- Create: `ui-finops/src/widgets/CreditsNetVsList.tsx`, `ui-finops/src/widgets/TopMovers.tsx`

- [ ] **Step 1: Credits** — `discountRows` on active window service map; highlight `pct >= 5`; columns service, list, net, delta, pct.

- [ ] **Step 2: Top movers** — fetch current + `priorWindow` service maps; `periodCompare`; show top 10 risers and top 10 fallers by `deltaList`.

- [ ] **Step 3: Wire StatusFooter** — status fields + `unmappedCount` from bucketize.

- [ ] **Step 4: Commit** — `feat(ui-finops): credits net-vs-list and top movers`

---

### Task 14: nginx + Dockerfile

**Files:**
- Create: `ui-finops/nginx.conf`, `ui-finops/Dockerfile`

- [ ] **Step 1: nginx.conf**

```nginx
server {
  listen 9090;
  server_name _;
  root /usr/share/nginx/html;
  index index.html;

  location /model/ {
    proxy_pass http://127.0.0.1:9003/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }

  location /healthz {
    access_log off;
    return 200 'ok';
    add_header Content-Type text/plain;
  }

  location / {
    try_files $uri $uri/ /index.html;
  }
}
```

- [ ] **Step 2: Multi-stage Dockerfile** — `node:22-alpine` build `npm ci && npm run build`; `nginx:1.27-alpine` copy `dist/` + `nginx.conf`; `EXPOSE 9090`.

- [ ] **Step 3: Local image smoke**

```bash
cd ui-finops && docker build -t ui-finops:local .
docker run --rm -p 9090:9090 ui-finops:local
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9090/healthz
```

Expected: `200`

- [ ] **Step 4: Commit** — `feat(ui-finops): nginx proxy and container image`

---

### Task 15: Wire Cloud Run + deploy.sh

**Files:**
- Modify: `infra/scripts/deploy.sh` — build `ui-finops` instead of `docker pull` SOURCE_UI_IMAGE
- Modify: `infra/cloud_run.tf` — remove OpenCost UI env (`API_SERVER`, `LEGACY_MODE`, etc.); keep container name `opencost-ui`, port `9090`, startup probe `/healthz`
- Modify: `infra/README.md`, `AGENTS.md` — describe FinOps SPA home; smoke `/` + `/model/cloudCost/status`
- Modify: `infra/outputs.tf` if it still mentions `/cloud` legacy

**Interfaces:**
- `UI_IMAGE` still `${AR}/opencost-ui:${IMAGE_TAG}` (name stable)
- `cmd_push_image` builds from `${ROOT_DIR}/ui-finops`

- [ ] **Step 1: Update deploy.sh `cmd_push_image`**

```bash
  docker build --platform "${PLATFORM}" -t "${UI_IMAGE}" "${ROOT_DIR}/ui-finops"
  docker push "${UI_IMAGE}"
  echo "Pushed ${UI_IMAGE}"
```

Remove `SOURCE_UI_IMAGE` pull/tag for UI (keep API pull from ghcr or existing SOURCE_IMAGE flow).

- [ ] **Step 2: Simplify ingress container env in `cloud_run.tf`** to none required (or `NGINX` defaults only). Keep `depends_on = ["opencost"]` and probes.

- [ ] **Step 3: Auth + deploy**

```bash
./infra/scripts/auth-from-secret.sh
./infra/scripts/deploy.sh push-image
./infra/scripts/deploy.sh deploy-revision
```

- [ ] **Step 4: Smoke**

```bash
BASE=https://opencost-cloudcost-lhcstnm7cq-uc.a.run.app
curl -sS -o /dev/null -w '%{http_code}\n' "$BASE/"
curl -sS "$BASE/model/cloudCost/status" | jq '.data[0].connectionStatus'
```

Expected: `200` and `Connection Successful`. Browser: six sections, no OpenCost nav.

- [ ] **Step 5: Commit** — `feat(infra): deploy ui-finops as Cloud Run ingress`

---

### Task 16: Docs polish + plan checkbox sync

**Files:**
- Modify: `docs/superpowers/specs/2026-07-24-gcp-finops-dashboard-design.md` status → Approved / Implemented-in-progress
- Modify: `docs/superpowers/plans/2026-07-24-gcp-finops-dashboard-mvp.md` — add banner pointing to this plan
- Modify: `docs/NEXT_AGENT_RUN.md` — FinOps SPA is home

- [ ] **Step 1: Update docs** as above  
- [ ] **Step 2: Commit** — `docs: point handoff at GCP FinOps SPA home`  
- [ ] **Step 3: Push branch / update PR**

---

## Spec coverage checklist (self-review)

| Spec requirement | Task |
|------------------|------|
| Replace `/`, hide stock OpenCost | 8, 14, 15 |
| List+net equal | 2, 4, 9–13 |
| Presets 7d/30d/MTD/invoice | 3, 8 |
| SPA transforms, no BFF | 3–6 |
| GMP-first category mix | 1, 5, 10 |
| Exec / services / projects / credits / movers | 9–13 |
| Status gate + unmapped count | 8, 13 |
| Deploy AR + Cloud Run | 14–15 |
| Unit tests transforms | 3–6 |

## Placeholder scan

None intentional. If OpenCost rejects absolute timestamp `window` pairs, fix in Task 3 against live API and adjust tests to the working format (same exclusive UTC bounds).
