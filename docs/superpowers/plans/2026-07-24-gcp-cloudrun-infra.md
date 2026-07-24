# GCP Cloud Run OpenCost Infra Implementation Plan

> **For agentic workers:** Implement task-by-task. Steps use checkbox syntax.

**Goal:** Scaffold compliance-aligned OpenTofu under `infra/` for cloud-cost-only OpenCost on Cloud Run.

**Architecture:** Flat `infra/*.tf` (one concern per file), GCS remote state, dedicated runtime SA, Secret Manager by reference, custom VPC + Cloud Run Direct VPC egress, private Artifact Registry, IAM invoker auth. No Cloud SQL/Redis/Scheduler in v1.

**Tech Stack:** OpenTofu ≥ 1.11.5, hashicorp/google ≥ 7.26.0, Cloud Run v2, Artifact Registry, Secret Manager.

**Spec sources:** `AGENTS.md` Plan B, `docs/architecture-compliance.md`.

## Global Constraints

- Never commit `terraform.tfvars`, state, or secret values
- Production images only from project Artifact Registry
- `authorizerType: GCPWorkloadIdentity` (no SA JSON keys in secrets)
- Cloud Run must not allow unauthenticated invocation
- Omit `cloud_sql.tf` / `redis_vm.tf` / `cloud_scheduler.tf` until needed

---

### Task 1: Scaffold `infra/` OpenTofu + deploy script

- [x] Create provider, variables, outputs, apis, iam, secrets, vpc, artifact_registry, cloud_run, monitoring
- [x] Add `.gitignore`, `terraform.tfvars.example`, `scripts/deploy.sh`
- [x] Generate `.terraform.lock.hcl` via `tofu init` (local backend override if no GCS)
- [x] Update `AGENTS.md` compliance status (`infra/` exists as scaffold)
- [ ] Commit and push; update PR
