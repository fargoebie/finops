# Task 8 Report: App shell — presets, status gate, layout chrome

## Status

Implemented.

## Changes

- Added `formatMoney` with whole-dollar formatting for large values and cents under $1000.
- Added `useInformData` to fetch cloud cost status and resolve current/prior windows from presets.
- Added `StatusFooter` for connection and window metadata.
- Replaced the App stub with:
  - window preset buttons: `7d`, `30d`, `MTD`, `Invoice`
  - invoice month input when the invoice preset is selected
  - previous calendar month default for invoice month
  - full-page status gate unless the first status row is `Connection Successful`
  - six section placeholders and footer when connected
- Added App shell styling.
- Confirmed there are no Allocation or External links/labels in `ui-finops/src`.

## Verification

- `npm test` passed: 8 files, 30 tests.
- `npm run build` passed: TypeScript build and Vite production build completed.
- `graphify update .` was attempted but failed because `graphify` is not installed in the environment.

## Concerns

- Manual `npm run dev` verification was not run because the task requires non-terminating dev server behavior; automated test/build verification passed.
- App component rendering is covered by TypeScript/build verification; unit tests cover the new pure money formatter and invoice default helper.
