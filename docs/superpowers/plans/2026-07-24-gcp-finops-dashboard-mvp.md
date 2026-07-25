# GCP FinOps Dashboard MVP — Inform Layer Only

> **Superseded for implementation:** use [`2026-07-25-gcp-finops-dashboard.md`](./2026-07-25-gcp-finops-dashboard.md) (written from the approved design spec). This file is retained as historical context only.

> **For agentic workers:** Implement task-by-task. Steps use checkbox syntax.

**Goal:** Ship a realistic, GCP-only cost Inform dashboard pack (no Kubernetes allocation, no External/Custom Cost) on top of the existing Cloud Run OpenCost cloud-cost API.

**Architecture:** Thin read-only dashboard that consumes OpenCost `/model/cloudCost*` (proxied by the UI sidecar). Client-side (or small BFF) transforms apply expanded category bucketing (GMP split) and period-compare. Stock OpenCost Allocation / External UIs are out of scope and must not be linked from this pack.

**Tech stack (recommended):** Static or lightweight SPA (Vite + React) served as an additional Cloud Run ingress path **or** a separate Cloud Run service behind the same invokers; data from existing `opencost-cloudcost` API. No Prometheus. No OpenCost plugins.

**Live data plane (already deployed):**
- UI/API: `https://opencost-cloudcost-lhcstnm7cq-uc.a.run.app`
- Status: `/model/cloudCost/status`
- Queries: `/model/cloudCost`, `/model/cloudCost/view/graph`, `/model/cloudCost/view/table`
- Source: BigQuery `demogcp-terra2021.export_billing_demogcp_detailed.gcp_billing_export_resource_v1_01E5F4_66804E_8286B7`

**Spec sources:** FinOps Inform patterns (Ternary reports/dashboards, Finout Inform widgets), live demogcp service mix (Maps/Places-heavy), prior agent research on expanded category mix + GMP split.

---

## Global constraints

- **GCP bill only** — never call `/allocation*`, `/assets*` (except optional carbon later), or `/customCost*`
- Prefer **list cost** for mix / ranking charts; always show **net cost** beside list for finance trust
- Treat OpenCost native `category` (`Compute` / `Network` / `Storage` / `Other`) as insufficient — use **service → bucket** mapping
- **Invoice** line items are billing adjustments, not product spend — bucket separately
- Do not commit secrets, `terraform.tfvars`, or admin tokens
- Demo may remain `allUsers`; document that production should drop public invoker
- No budgets, anomaly ML, virtual tags, Slack scheduling, or CostGuard in MVP (post-MVP)

---

## Product scope — six Inform widgets

| # | Widget | User question | Primary API | Transform |
|---|--------|---------------|-------------|-----------|
| 1 | **Exec pulse** | What did we spend MTD / 7d / 30d? | `cloudCost?aggregate=provider` (or unaggregated sum) for windows `month-to-date` equiv via date math, `7d`, `30d` | Sum `listCost.cost` + `netCost.cost`; WoW/MoM deltas via second window |
| 2 | **Service drivers** | Which SKUs drive spend? | `view/graph?aggregate=service`, `view/table?aggregate=service` | Top-N (default 15); highlight GMP SKUs |
| 3 | **Project showback** | Which GCP projects pay? | `cloudCost?aggregate=accountID` + `accountID,service` drill | Rank projects; click-through to services |
| 4 | **Category mix (expanded)** | Where does money go by capability? | `cloudCost?aggregate=service` | Map services → expanded buckets; **GMP first-class** |
| 5 | **Credits & net vs list** | Where do discounts/credits matter? | Same as #1/#2 with both metrics | Flag rows where `abs(list-net)/list > threshold` (e.g. 5%) |
| 6 | **Top movers** | What changed vs last period? | Two windows (e.g. this `7d` vs prior `7d`) `aggregate=service` | Join on service; Δ$ and Δ%; Ternary-style compare |

### Non-goals (MVP)

- Kubernetes cost / idle / efficiency views
- External Cost / plugins / Datadog-style SaaS
- Budget CRUD, forecast ML, anomaly detection UI
- Unit economics (needs external business metrics)
- Replacing OpenCost upstream UI permanently (this pack can live beside it)

---

## Expanded category taxonomy (demogcp-tuned)

OpenCost’s native categories bury GMP under `Other`. MVP uses this **display taxonomy**:

| Bucket ID | Label | Mapping rule (service name) |
|-----------|-------|-----------------------------|
| `gmp` | Google Maps Platform | Exact/prefix match: `Places API`, `Places API (New)`, `Geocoding API`, `Maps API`, `Directions API`, `Distance Matrix API`, `Roads API`, `Maps Static API`, `Street View Static API`, `Maps Elevation API`, `Geolocation API`, `Time Zone API`, future `Routes API`, `Map Tiles API`, `Address Validation API`, `Navigation SDK` |
| `compute` | Compute & runtime | `Compute Engine`, `App Engine`, `Cloud Run`, `Cloud Run Functions`, `Deep Learning VM`, `VM Manager` |
| `data` | Data platform | `BigQuery`, `Cloud Storage`, `Cloud SQL`, `Cloud Bigtable`, `Dataplex`, `Firebase Realtime Database` |
| `ai_ml` | AI / ML | `Gemini API`, `Vertex AI`, `Vertex AI Search`, `Cloud Vision API`, `Translate`, names matching `Claude *` |
| `network` | Networking | `Networking`, `API Gateway`, `Cloud Pub/Sub` |
| `ops` | Ops & platform | `Cloud Monitoring`, `Cloud Logging`, `Cloud Trace`, `Cloud Build`, `Cloud Scheduler`, `Cloud Tasks`, `Secret Manager`, `Artifact Registry`, `Source Repository`, `Google Service Control` |
| `app` | App / Firebase | `Firebase Hosting`, `Firebase Data Connect` |
| `analytics` | Analytics / BI | `Looker Studio` |
| `billing` | Billing adjustments | `Invoice` (+ future credit-only SKUs if named distinctly) |
| `other` | Unmapped | Everything else (log + surface in QA) |

### GMP sub-mix (widget 4 drill-down)

| Sub-bucket | Services |
|------------|----------|
| Places | `Places API`, `Places API (New)` |
| Geocoding | `Geocoding API` |
| Maps rendering | `Maps API`, `Maps Static API`, `Street View Static API` |
| Routes & mobility | `Directions API`, `Distance Matrix API`, `Roads API` |
| Location utilities | `Geolocation API`, `Time Zone API`, `Maps Elevation API` |

Config file (checked in): `ui-finops/config/gcp-category-map.json` (or `docs/finops/gcp-category-map.json` if UI deferred).

---

## UX composition (single pack, multi-section page)

One route, e.g. `/finops` or standalone origin — **not** a multi-card marketing layout; one FinOps analysis surface:

1. **Header:** window selector (7d / 30d / MTD), cost basis toggle (List default / Net / Both)
2. **Row A — Exec pulse:** 3–4 KPI tiles (MTD list, MTD net, 7d list, WoW Δ%)
3. **Row B — Category mix:** donut/stacked bar (expanded buckets) + GMP share KPI; click GMP → sub-mix
4. **Row C — Service drivers:** line/area from `view/graph` + top-N table from `view/table`
5. **Row D — Project showback:** horizontal bar by `accountID` + optional project→service table
6. **Row E — Credits & net vs list:** table sorted by `|list-net|` with % discount column
7. **Row F — Top movers:** compare table (service, prior, current, Δ$, Δ%), default WoW

Empty/error: if `/cloudCost/status` ≠ Connection Successful, show status panel only.

---

## API contract (use through UI proxy)

Base: `$OPENCOST_URL/model` (Cloud Run) or `http://127.0.0.1:9003` (API sidecar direct).

```bash
# Health
GET /cloudCost/status

# Exec totals (sum cloudCosts.*.listCost|netCost)
GET /cloudCost?window=7d&aggregate=provider
GET /cloudCost?window=30d&aggregate=provider
# MTD: window=YYYY-MM-DD,YYYY-MM-DD (month start → tomorrow UTC)

# Service drivers
GET /cloudCost/view/graph?window=30d&aggregate=service
GET /cloudCost/view/table?window=30d&aggregate=service

# Project showback
GET /cloudCost?window=30d&aggregate=accountID
GET /cloudCost?window=30d&aggregate=accountID,service

# Category mix + credits + movers: fetch service aggregates, transform client-side
GET /cloudCost?window=7d&aggregate=service
GET /cloudCost?window=30d&aggregate=service
# Prior week for movers: compute prior window timestamps client-side
```

**Notes from live demogcp:**
- `view/table` costs align with list-style ranking (Places/Geocoding dominate)
- `netCost` can be negative (credits) — never hide it; annotate
- `kubernetesPercent` is 0 — do not show K8s columns

---

## Delivery options (pick in Task 1)

| Option | Pros | Cons | Recommendation |
|--------|------|------|----------------|
| **A. Sibling static app on same Cloud Run** (extra nginx location or third container) | One URL, shared invokers | Image/deploy complexity | **Preferred** if we want productized UX |
| **B. Separate Cloud Run service** `opencost-finops-ui` | Clean lifecycle | Second URL / IAM | Good if A is painful |
| **C. Looker Studio on BQ** | Fast finance adoption | Not in-repo, weaker “pack” | Fallback for finance-only |
| **D. Scripts + markdown only** | Fastest | Not a real dashboard | Spike only |

**Decision for implementers:** Default to **Option A** (or B if sidecar slot is full). Keep mapping JSON + query helpers shareable for Option C later.

---

## Implementation tasks

### Task 1: Decide delivery + scaffold pack

**Files (expected):**
- `docs/superpowers/plans/2026-07-24-gcp-finops-dashboard-mvp.md` (this plan)
- `ui-finops/` (or `web/finops/`) package scaffold
- `ui-finops/config/gcp-category-map.json`

- [ ] Confirm Option A vs B with stakeholder (default A)
- [ ] Scaffold app (Vite/React or vanilla) with env `VITE_OPENCOST_BASE=/model`
- [ ] Add `gcp-category-map.json` with buckets + GMP sub-buckets from taxonomy above
- [ ] Unit-test mapper: sample service list → bucket IDs (include Places, Invoice, Claude *, unknown)
- [ ] Commit on feature branch

### Task 2: Data client + window helpers

- [ ] `fetchCloudCostStatus()`, `fetchCloudCost({ window, aggregate })`, `fetchViewGraph`, `fetchViewTable`
- [ ] Window helpers: `last7d`, `last30d`, `mtd`, `previousPeriod(window)` for WoW/MoM
- [ ] Aggregators: `sumListNet(sets)`, `topN(table, n)`, `bucketize(services, map)`, `periodCompare(current, prior)`
- [ ] Handle multi-day `sets[]` by summing costs per key
- [ ] Tests with fixtures captured from live API (redact if needed)

### Task 3: Widget — Exec pulse

- [ ] KPI tiles: MTD list, MTD net, 7d list, 30d list
- [ ] WoW Δ% on 7d list (and optional MoM on MTD)
- [ ] Loading / error / stale status from `/cloudCost/status` (`lastRun`, `coverage`)

### Task 4: Widget — Service drivers

- [ ] Time series chart from `view/graph` (`aggregate=service`)
- [ ] Top-N table (N=15 default) from `view/table`
- [ ] Badge/filter: “GMP only” toggle using category map

### Task 5: Widget — Project showback

- [ ] Bar/table by `accountID` (label = project id; show `__unallocated__` last)
- [ ] Drill: selected project → `aggregate=accountID,service` filtered client-side
- [ ] Exclude or separately flag `billing` bucket totals in project rollup footnotes

### Task 6: Widget — Expanded category mix (+ GMP split)

- [ ] Donut/stacked: expanded buckets from Task 1 map
- [ ] KPI: GMP % of list spend
- [ ] Drill panel: GMP sub-mix (Places / Geocoding / Maps / Routes / Utilities)
- [ ] Ensure `Invoice` is under Billing adjustments, not Other

### Task 7: Widget — Credits & net vs list

- [ ] Table: service, list, net, delta, delta%
- [ ] Default sort by `|delta|` desc; highlight delta% ≥ 5%
- [ ] Short note explaining credits/discounts (net can be &lt; 0)

### Task 8: Widget — Top movers (period compare)

- [ ] Fetch current 7d + prior 7d service aggregates
- [ ] Join keys; compute Δ$ and Δ%
- [ ] Show top 10 increases and top 10 decreases
- [ ] Optional toggle: 30d vs prior 30d

### Task 9: Integrate with Cloud Run deploy

- [ ] Build image → push to Artifact Registry (`opencost-finops` or static files into UI image)
- [ ] Wire route (`/finops` rewrite) **or** new Cloud Run service in `infra/cloud_run.tf`
- [ ] Update `infra/scripts/deploy.sh` for the new artifact
- [ ] Update `infra/README.md` + `AGENTS.md` smoke URLs
- [ ] Smoke: status OK + each widget returns non-empty for demogcp

### Task 10: Docs + handoff

- [ ] `docs/finops/gcp-dashboard-mvp.md` — user-facing widget guide + taxonomy
- [ ] Screenshot or short clip under `/opt/cursor/artifacts` if UI shipped
- [ ] Note post-MVP backlog: budgets, anomalies, Slack delivery, unit economics, Looker export

---

## Verification

```bash
BASE=https://opencost-cloudcost-lhcstnm7cq-uc.a.run.app/model

curl -sS "$BASE/cloudCost/status" | jq '.data[0].connectionStatus'
curl -sSG "$BASE/cloudCost/view/table" -d window=7d -d aggregate=service | jq '.[0:5]'
curl -sSG "$BASE/cloudCost" -d window=7d -d aggregate=accountID | jq '.data.sets|length'

# After UI deploy
curl -sS -o /dev/null -w '%{http_code}\n' https://opencost-cloudcost-lhcstnm7cq-uc.a.run.app/finops
```

Manual checklist:
- [ ] No Allocation / External navigation in the pack
- [ ] GMP is a first-class category and Places/Geocoding dominate as expected
- [ ] List and net both visible on exec pulse and credits table
- [ ] Top movers shows both risers and fallers
- [ ] Unmapped services appear under Other (and are logged)

---

## Suggested sequencing

```
Task 1 (scaffold + map) 
  → Task 2 (client/helpers)
    → Tasks 3–8 in parallel-ish (widgets)
      → Task 9 (deploy)
        → Task 10 (docs)
```

---

## Post-MVP (explicitly out of this plan)

- Budget widgets (Ternary/Finout Financial Plans)
- Anomaly detection alerts
- Virtual tagging / shared cost reallocation
- Scheduled Slack/email distribution
- Unit economics (cost / API call using Maps usage metrics)
- FOCUS export parity beyond OpenCost’s cloud cost model
