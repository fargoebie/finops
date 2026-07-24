# Architecture Compliance Baseline

A project- and SKU-agnostic set of architectural compliance principles derived from the
AgentSpace GCP setup. Use it to verify that a **new** project follows the same patterns,
regardless of which SKUs, tiers, regions, or models it chooses.

For each item, confirm the new project satisfies the **principle** — not the specific
resource. A different DB engine/tier is fine as long as it is still private-IP + backups +
deletion protection; a different cache/model is fine as long as it is still private +
firewall-scoped with secrets injected by reference; a different compute product is fine as
long as it runs under a dedicated least-privilege SA and pulls from a private registry.

**Non-negotiables (security-critical):** A (dedicated least-privilege SAs), B (managed
secrets by reference), C (no public IP on data stores), D (IAP-only admin access),
E (app-layer auth on public services).

---

## A. Identity & least privilege
- **Dedicated service account per workload.** Every runtime component (backend, frontend,
  each VM, the scheduler) gets its own service account. No shared identities, no default
  compute SA.
- **No workload runs with project-level admin.** Roles are the minimum each SA needs to
  function.
- **Resource-scoped grants over project-scoped.** Storage and secret access are bound at the
  individual bucket/secret level, not granted project-wide. Only truly project-wide
  capabilities (AI platform use, SQL client, trace/metric writing, service-usage) are
  project-level bindings.
- **Human access is identity-based and auditable.** Developer access to infrastructure is
  granted per-user-email, never via shared keys or broad group grants baked into infra.

## B. Secrets management
- **All credentials live in a managed secret store**, never in env-var literals, images, or
  committed files.
- **Secrets are injected at runtime by reference** (secret ref → env var), so the value never
  appears in service config or Terraform state.
- **Secret read access is granted only to the SA that needs it**, per-secret.
- **Connection strings are composed from other managed resources** (e.g. DB URL built from the
  private IP + stored password) rather than hand-maintained.

## C. Network isolation
- **Custom VPC + explicit subnet** — no reliance on the default network.
- **Stateful data services have no public IP.** Databases and caches are reachable only over
  private networking.
- **Managed DB uses private connectivity** (Private Service Access / private IP), not public IP
  with allowlists.
- **Compute egress is restricted** to private ranges where the workload only needs internal
  resources.
- **Firewall rules are default-deny + narrowly scoped**: each rule opens a specific port to a
  specific source range, targeted by tag (e.g. cache port only from the app subnet).
- **Outbound internet for private hosts goes through managed NAT**, not a public IP on the
  instance.

## D. Remote administrative access
- **No direct public SSH/RDP.** Administrative access to VMs is brokered through an
  identity-aware proxy (IAP tunnel), with SSH allowed only from the proxy's IP range.
- **OS-level login is IAM-controlled** (OS Login), granted per user.

## E. Public surface & app-layer auth
- **Only the intended public entrypoints are internet-facing** (the web services). Everything
  else is private.
- **Public services still authenticate users at the application layer** (OAuth + session cookies
  with domain allow-listing), so "publicly reachable" ≠ "publicly usable."
- **Cross-origin, redirect URIs, and allowed domains are explicit allowlists**, configured per
  environment.

## F. Data durability & lifecycle
- **Managed databases have automated backups enabled** and deletion protection on.
- **Object storage uses uniform bucket-level access** (no per-object ACLs) and is not
  force-destroyable.
- **Data has a defined retention/cleanup policy** — a primary application-aware cleanup path
  plus a long backstop lifecycle rule, rather than an aggressive blanket TTL.

## G. Build, deploy & state
- **Infrastructure is fully declarative (IaC)** with remote, shared state in a dedicated bucket
  — no click-ops.
- **Container images are pulled from a private, project-owned registry**, built for a pinned
  platform and versioned by tag.
- **Schema migrations run as a separate, gated job** before the app is deployed, not on app
  startup.
- **Scheduled/background work runs as dedicated jobs** invoked by a dedicated SA with a
  narrowly-scoped invoker role — not on a public endpoint.

## H. Observability
- **Every workload can emit traces and metrics** (trace agent + metric writer roles on the
  runtime SA) so the system is monitorable by default.

## I. IaC tooling & repository layout

**Tool: OpenTofu** (Terraform-compatible; use the `tofu` CLI). Provider: `hashicorp/google`.
Pin both:

```hcl
terraform {
  required_version = ">= 1.11.5"
  required_providers {
    google = { source = "hashicorp/google", version = ">= 7.26.0" }
  }
  # Use an app-isolated prefix. Never share tofu/state across stacks in one bucket.
  backend "gcs" { bucket = "<project>-tofu-state", prefix = "tofu/<app>" }
}
```

### Where to store it

All infrastructure lives in a single top-level `infra/` directory in the app repo (IaC lives
beside the code it provisions, not in a separate repo). Within it, use **one file per concern**
— a flat layout, no premature module nesting — so compliance reviewers can find each domain
quickly:

```
infra/
├── provider.tf              # tofu + provider versions, GCS remote backend
├── variables.tf             # input vars (project_id, region, zone, secrets-in, user lists)
├── outputs.tf               # exported values (URLs, SA emails, private IPs, bucket names)
├── apis.tf                  # google_project_service — all enabled APIs in one set
├── iam.tf                   # service accounts + role bindings (identity/least-privilege)
├── secret_manager.tf        # secret definitions + per-secret accessor bindings
├── vpc.tf                   # network, subnet, PSA range, firewall, NAT/router
├── cloud_sql.tf             # managed DB instance, database, users
├── redis_vm.tf              # cache VM + IAP/OS-Login access grants
├── gcs.tf                   # object storage buckets + lifecycle rules
├── artifact_registry.tf     # private container registry
├── cloud_run.tf             # runtime services + jobs (migrate, sweep) + invoker bindings
├── cloud_scheduler.tf       # scheduled jobs + dedicated invoker SA
├── monitoring_dashboard.tf  # observability dashboards
├── scripts/
│   └── deploy.sh            # build → push → migrate → deploy orchestration
├── terraform.tfvars.example # committed template of required tfvars
├── .terraform.lock.hcl      # committed provider lock (reproducible builds)
└── .gitignore
```

### Layout / storage rules for compliance

- **One file per resource domain**, named after the concern (`iam.tf`, `vpc.tf`, …). IAM and
  secret-access bindings live next to the resources they protect, so access is reviewable
  in-place.
- **State is remote and shared**, in a dedicated GCS bucket (`backend "gcs"`), never local.
  Create the state bucket out-of-band before the first `tofu init`. Enable versioning on it.
- **Never commit state or secrets.** The `infra/.gitignore` must exclude:

```
terraform.tfvars
.terraform/
*.tfstate
*.tfstate.backup
```

- **Commit `terraform.tfvars.example`** (a documented template) and **commit
  `.terraform.lock.hcl`** (pins provider hashes for reproducibility).
- **Real secret values never go in `.tf` or `.tfvars`.** Sensitive inputs are marked
  `sensitive = true`, default to `null`, and are passed at apply time (`-var`) or written
  directly to the secret store by the deploy script — not persisted in the repo.
- **Deploy orchestration is a script under `infra/scripts/`**, kept in sync with the resources
  (e.g. bucket-name convention) via comments, so image build/push/migrate/deploy is one
  auditable, repeatable command.

### Bootstrap order (new project)
1. Create the remote-state GCS bucket manually; enable versioning.
2. `cp backend.hcl.example backend.hcl` and set an **app-isolated** `prefix` (e.g. `tofu/<app>` — never share `tofu/state` across stacks).
3. `cp terraform.tfvars.example terraform.tfvars`, fill in project-specific values.
4. `cd infra && tofu init -backend-config=backend.hcl && tofu apply` — secret shells must get an enabled version before Cloud Run mounts `latest` (seed-if-empty in IaC, or sync secrets before the service is healthy).
5. Run the deploy script to push images and update secret versions (day-2). Prefer script-owned image tags over baking mutable digests into tfvars.
