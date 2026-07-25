# Task 15 Report: Wire Cloud Run + deploy.sh

## Status

Implemented and deployed.

## Changes

- Added `ui-finops/.dockerignore` with `node_modules`, `dist`, and `.git`.
- Updated `infra/scripts/deploy.sh` so `push-image` builds `ui-finops` locally and pushes it as the stable `opencost-ui` Artifact Registry image.
- Simplified the `opencost-ui` Cloud Run ingress container in `infra/cloud_run.tf`:
  - Keeps name `opencost-ui`
  - Keeps port `9090`
  - Keeps `/healthz` startup probe
  - Keeps `depends_on = ["opencost"]`
  - Removes OpenCost UI env (`API_SERVER`, `API_PORT`, `UI_PORT`, `BASE_URL`, `UI_PATH`, `LEGACY_MODE`)
- Updated `infra/README.md` and `AGENTS.md` for the FinOps SPA home and smoke URLs.
- Updated `infra/outputs.tf` to remove legacy `/cloud` wording.

## Verification

- `bash -n infra/scripts/deploy.sh` passed.
- `tofu fmt -check -recursive` in `infra/` passed.
- `npm --prefix ui-finops test -- --run` passed: 16 files, 49 tests.
- `./infra/scripts/auth-from-secret.sh` passed using `GCP_SA_KEY_B64`.
- `./infra/scripts/deploy.sh push-image` passed:
  - API image: `us-central1-docker.pkg.dev/demogcp-terra2021/opencost/opencost:fd1dc654`
  - UI image built from `ui-finops`: `us-central1-docker.pkg.dev/demogcp-terra2021/opencost/opencost-ui:fd1dc654`
- `./infra/scripts/deploy.sh deploy-revision` passed:
  - Revision: `opencost-cloudcost-00009-cmw`
  - URL: `https://opencost-cloudcost-lhcstnm7cq-uc.a.run.app`
- Smoke passed:
  - `GET /` -> `200`
  - `GET /model/cloudCost/status` -> `Connection Successful`

## Concerns

- `graphify` is unavailable in this environment (`graphify: command not found`), so graph update could not be performed.
- The working tree had a pre-existing unstaged `ui-finops/.gitignore` change; it was not modified or staged.
