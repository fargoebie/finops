# GCP FinOps Dashboard — Design Spec

**Status:** Approved / Implemented-in-progress  
**Date:** 2026-07-24  
**Branch context:** Pure GCP Inform dashboard replacing stock OpenCost UI on Cloud Run  
**Related:** `docs/finops/gcp-category-map.json`, implementation plan [`docs/superpowers/plans/2026-07-25-gcp-finops-dashboard.md`](../plans/2026-07-25-gcp-finops-dashboard.md)

---

## 1. Problem

demogcp Cloud Run already ingests GCP BigQuery billing into OpenCost `/cloudCost*`, but the stock OpenCost UI is Kubernetes-oriented (Allocation, External, idle/efficiency framing). Stakeholders need a **pure GCP FinOps Inform surface** — finance KPIs and analyst drill-downs — without kube or external-cost analysis.

## 2. Goals

- Single default experience at `/` for GCP bill analysis only
- Serve **both** finance/FP&A and FinOps practitioners on one page (exec pulse on top, drill-downs below)
- Mirror Inform patterns from premier tools (Ternary reports/dashboards, Finout Inform widgets) without Optimize/Allocate features in v1
- Show **list and net costs equally** on every monetary view
- Treat **Google Maps Platform (GMP)** as a first-class category with SKU sub-mix
- Keep maintenance simple: transforms in the SPA, one Cloud Run service

## 3. Non-goals (v1)

- Kubernetes allocation, idle, efficiency, or External/Custom Cost plugins
- Budgets, forecasting ML, anomaly detection, virtual tagging, Slack/email scheduling, unit economics
- Backend-for-frontend (BFF) service
- Free-form custom date picker (presets only)
- Keeping stock OpenCost UI routes as a fallback

## 4. Decisions (from brainstorming)

| Topic | Choice |
|-------|--------|
| Audience | Both personas, one page (exec + analyst) |
| Front door | Replace `/` — FinOps SPA is the only UI |
| Stock OpenCost UI | Hidden completely — no Allocation/External/classic links |
| Cost basis | List **and** net side-by-side everywhere |
| Time range | Presets: **7d**, **30d**, **MTD**, **invoice month** |
| Architecture | Custom SPA replaces `opencost-ui` ingress; API sidecar unchanged |
| Transforms | SPA TypeScript modules + checked-in category map JSON |

## 5. Architecture

```
Browser  →  /  (GCP FinOps SPA only)
         →  /model/*  (nginx reverse-proxy)

Cloud Run service opencost-cloudcost
  ├─ Ingress container: ui-finops (:9090)  — replaces opencost-ui
  └─ Sidecar: opencost API (:9003)        — CLOUD_COST_ENABLED, WI → BigQuery

BigQuery billing export (unchanged)
```

- No calls to `/allocation*`, `/customCost*`, or stock OpenCost page routes
- Images still pushed to Artifact Registry; `deploy.sh` updates both containers; OpenTofu continues to ignore image drift

## 6. Package layout

```
ui-finops/
├── config/gcp-category-map.json    # buckets + GMP sub-buckets + service map
├── src/
│   ├── api/cloudCost.ts            # status, query, viewGraph, viewTable
│   ├── transforms/
│   │   ├── windows.ts              # 7d, 30d, MTD, invoice month, prior period
│   │   ├── aggregate.ts            # sum list+net across sets[]
│   │   ├── bucketize.ts            # service → bucket / GMP sub
│   │   ├── periodCompare.ts        # movers Δ$ / Δ%
│   │   └── discount.ts             # |list-net| rows for credits widget
│   ├── widgets/                    # one folder or file per section
│   └── App.tsx                     # shell: preset state, fetch, layout
└── nginx.conf                      # / → SPA; /model/ → 127.0.0.1:9003
```

**Single source of truth:** `ui-finops/config/gcp-category-map.json`. `docs/finops/gcp-category-map.json` remains a copy or symlink/pointer for docs-only readers until the package exists; after scaffold, docs README links to the UI config path.

## 7. Page composition

One route `/`. Header holds window presets. Sections in order:

1. **Exec pulse** — tiles for MTD, 7d, 30d (each list + net); WoW Δ% for list and net  
2. **Category mix (expanded)** — donut/stacked from service→bucket map; **GMP drill** (Places, Geocoding, Maps rendering, Routes & mobility, Location utilities)  
3. **Service drivers** — time series (`view/graph?aggregate=service`) + top-N table (`view/table`); list + net columns  
4. **Project showback** — by `accountID` (GCP project); optional drill to services  
5. **Credits & net vs list** — table sorted by `|list-net|`; highlight discount % ≥ 5%  
6. **Top movers** — current preset vs prior equal-length period; top risers and fallers  
7. **Status footer** — `connectionStatus`, `lastRun`, `coverage`, unmapped service count  

No marketing cards, no OpenCost nav, no kube columns (`kubernetesPercent` omitted).

## 8. Data & transforms

### API (via `/model`)

| Need | Endpoint |
|------|----------|
| Health | `GET /cloudCost/status` |
| Totals / bucketing / credits / movers | `GET /cloudCost?window=…&aggregate=service` (and `provider` for coarse totals if useful) |
| Project showback | `GET /cloudCost?window=…&aggregate=accountID` (+ `accountID,service` for drill) |
| Service series | `GET /cloudCost/view/graph?aggregate=service` (series values; pair with dual-metric table below) |
| Service top-N (list+net) | `GET /cloudCost?aggregate=service` summed client-side — do **not** rely on `view/table` alone (it exposes a single cost field) |

### Window semantics

- **7d / 30d:** rolling windows as accepted by OpenCost `window` param  
- **MTD:** `[UTC month start, tomorrow 00:00 UTC)` exclusive end, consistent with OpenCost date-pair windows  
- **Invoice month:** selected calendar month `[first day, first day of next month)` UTC  
- **Prior period (movers):** immediately preceding window of equal length  

### View-model rule

Every monetary structure exposes `{ list: number, net: number }`. Widgets must not present list-only rankings without net alongside. If a chart series is single-valued, default the plotted series to **list** and show **net** in the legend/tooltip and in the companion table.

### Category taxonomy

Use expanded buckets (not OpenCost native `category`):

`gmp` · `compute` · `data` · `ai_ml` · `network` · `ops` · `app` · `analytics` · `billing` · `other`

- **Invoice** → `billing` (not product spend)  
- Unmapped → `other`, counted in footer  
- Pattern rules (e.g. `^Claude `, `^Places API`, `^Maps `) supplement exact service names  

## 9. Error handling

| Condition | Behavior |
|-----------|----------|
| Status not Connection Successful | Full-page status panel; do not render zeroed KPIs |
| One widget fetch fails | Section error + retry; other sections keep data |
| Empty cloudCosts | Honest empty state in that section |
| Unmapped services | Bucket Other + footer “N unmapped” |

Never deep-link to stock OpenCost UI as recovery.

## 10. Deploy

1. Build/push `ui-finops` image to Artifact Registry (git sha tag)  
2. Cloud Run ingress container image = FinOps SPA (port 9090, `/model` proxy)  
3. API sidecar unchanged  
4. Update `infra/scripts/deploy.sh`, `infra/cloud_run.tf` env/comments, `infra/README.md`, `AGENTS.md`  
5. Smoke: `GET /` → 200; `GET /model/cloudCost/status` → Connection Successful  

## 11. Testing

- Unit tests: `bucketize`, `periodCompare`, `windows`, `aggregate`, `discount` with fixtures shaped like live API responses  
- Mapper cases: Places → gmp, Invoice → billing, Claude* → ai_ml, unknown → other  
- Manual on demogcp: all six sections populate; Credits shows rows where list ≠ net; GMP share reflects Places/Geocoding dominance  

## 12. Success criteria

- Visiting the Cloud Run URL shows only the GCP FinOps Inform page  
- No path to Allocation or External Cost analysis  
- Finance can read MTD/7d/30d list+net and credits; FinOps can drill service, project, GMP, movers  
- Category mix uses expanded taxonomy with GMP first-class  

## 13. Post-v1 (explicit backlog)

Budgets, anomalies, virtual tags, scheduled delivery, unit economics (e.g. $/Places request), optional Looker Studio on the same BQ export, BFF only if a second client needs the same shaped API.

## 14. References

- Ternary: system/custom dashboards, reports, period compare, budgets (Inform subset only for v1)  
- Finout: Inform widgets (cost, usage tables, distribution patterns) — not CostGuard/virtual tags in v1  
- Live API: `https://opencost-cloudcost-lhcstnm7cq-uc.a.run.app/model/cloudCost*`  
