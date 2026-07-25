# Task 5 Report: bucketize.ts

## Status

Implemented `ui-finops/src/transforms/bucketize.ts` with TDD coverage in
`ui-finops/src/transforms/bucketize.test.ts`.

## TDD Evidence

- Red: `npm test -- src/transforms/bucketize.test.ts`
  - Failed because `./bucketize` did not exist.
- Green: `npm test -- src/transforms/bucketize.test.ts`
  - Passed 5 bucketize tests.

## Implemented Behavior

- `loadCategoryMap()` imports the expanded GCP category map.
- `resolveBucket(service, map)` resolves exact `serviceToBucket` mappings first,
  then `serviceNamePatterns`, then `defaults.unmappedBucket`.
- GMP services resolve `gmpSubId` from `gmpSubBuckets[].services`.
- `bucketizeServices(byService, map)` returns bucket totals, per-service resolved
  costs, and `unmappedCount`.
- `gmpSubMix(services, map)` aggregates only GMP services by GMP sub-bucket.

## Coverage

- Places API -> `gmp` + `places`.
- Invoice -> `billing`.
- Claude Fable 5 -> `ai_ml` via pattern using a test map without the exact entry.
- Totally Unknown -> `other` and increments `unmappedCount`.
- GMP sub-mix sums Places and Geocoding separately.

## Verification

- `npm run build && npm test`
  - Build succeeded.
  - Vitest passed: 3 files, 12 tests.

## Concerns

- Workspace rules require `graphify`, but the command is not installed in this
  environment. Both `graphify query ...` and `graphify update .` failed with
  `graphify: command not found`.
- Existing unrelated change left untouched: `ui-finops/.gitignore`.
