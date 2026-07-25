# GCP FinOps (Inform)

Planning and config for GCP-only cost dashboards on the demogcp Cloud Run OpenCost deploy.

| Doc | Purpose |
|-----|---------|
| [Dashboard MVP plan](../superpowers/plans/2026-07-24-gcp-finops-dashboard-mvp.md) | Six-widget Inform pack (exec pulse → top movers) |
| [gcp-category-map.json](../../ui-finops/config/gcp-category-map.json) | Expanded categories + GMP split for service bucketing (**source of truth:** `ui-finops/config/gcp-category-map.json`) |

**Data:** OpenCost `/model/cloudCost*` only — no Allocation, no External Cost.
