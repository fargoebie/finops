## Task 10 Report: Widget — Category mix + GMP drill

### Status
- Implemented `ui-finops/src/widgets/CategoryMix.tsx`.
- Wired CategoryMix into `App` after ExecPulse, replacing the category placeholder.
- Plumbed a shared `now` value from `App` into `useInformData` and CategoryMix so active preset windows resolve consistently.

### Implementation
- Fetches `/model/cloudCost` with `aggregate=service` for the active preset window via `fetchCloudCost`.
- Uses `sumByKey`, `loadCategoryMap`, `bucketizeServices`, and `gmpSubMix` to build category and GMP sub-mix view data.
- Renders a Recharts donut using list cost as the series value.
- Shows GMP list percent KPI, list/net legend values, tooltip list/net values, and GMP drill bars with list/net values.
- Adds retry/error/loading states and focused component/loader tests.

### Verification
- `npm test` — 11 files passed, 36 tests passed.
- `npm run build` — TypeScript and Vite build completed.

### Concerns
- `graphify` is not installed in this environment, so `graphify update .` could not run.
- Vite emitted a chunk-size warning after bundling Recharts: `Some chunks are larger than 500 kB after minification`.
