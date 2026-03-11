# PhotoAtlas — Photos Library Change Observer Indexing (Design)

Date: 2026-03-10

## Goal
Make PhotoAtlas reliably index:
- **Newly added photos** even if they have **old `creationDate`** (e.g. imports, restores, AirDrop), and
- **Deletions** (remove DB rows/pins when photos are deleted).

Scope constraints (per discussion):
- Process changes **only while the app is running / foreground**.
- Prefer correctness while controlling reverse-geocoding load.

## Current Behavior (Baseline)
- On launch, `MapScreen` calls `AppModel.autoIndexIfPossible()` when Photos authorization is determined.
- `autoIndexIfPossible()` uses:
  - first run: `PhotosIndexer.fullReindex()` (currently does `store.resetAll()` then indexes)
  - later runs: `PhotosIndexer.incrementalIndex(since: db.latestCreationTs())`
- Incremental predicate: `creationDate > since`.

### Gaps
- **Old photos newly imported** are missed when their `creationDate` is earlier than the DB cursor.
- **Deletions** are not detected/removed.

## Recommended Approach
Use **`PHPhotoLibraryChangeObserver`** with a maintained `PHFetchResult<PHAsset>`.

Rationale:
- Public Photos API does not provide a reliable `dateAdded` field.
- Change observation provides explicit inserted/removed/changed sets, which map directly to DB upserts/deletes.
- Supports deletion requirement while avoiding over-broad periodic scans.

## Design Overview

### Components
1) **PhotoLibraryWatcher** (new)
- Owns a `PHFetchResult<PHAsset>` representing the asset universe we care about (images).
- Registers as a `PHPhotoLibraryChangeObserver`.
- On changes, computes deltas and forwards work to the model/indexer.

2) **AppModel** (existing)
- Owns indexing state (`isIndexing`, `indexProgress`, `indexProgressText`, `lastIndexSummary`).
- Exposes methods:
  - `bootstrapIndexIfNeeded()` (initial full scan after permission)
  - `applyPhotoLibraryChanges(...)` (process deltas)

3) **PhotosIndexer** (existing, extended)
- Keep `fullReindex` for initial bootstrap.
- Add change-driven entry points:
  - `indexAssets(withLocalIds: [String], onProgress: ...)`
  - `deleteAssets(withLocalIds: [String])`

4) **SQLiteStore** (existing, extended)
- Add deletion API:
  - `delete(localId: String)` / `delete(localIds: [String])`.

### Data Model Assumptions
- DB stores **only assets with GPS** (current code `guard asset.location != nil else { continue }`).
- Therefore:
  - If an asset loses location (changed asset, `location == nil`), we should **delete** its DB record.

## Change Processing Rules

### Inserted assets
For each inserted asset:
- If `asset.location != nil`: reverse-geocode + upsert
- Else: ignore (no DB row)

### Removed assets
For each removed asset:
- Delete DB row by `localIdentifier`.

### Changed assets
For each changed asset:
- If now has `location != nil`: upsert
- If now has `location == nil`: delete row (if it exists)

> Optional optimization: only re-geocode if lat/lon changed or if record is new.

## Progress UI Behavior
- Keep existing overlay behavior: show only when `isIndexing == true` and `indexProgressText != nil`.
- For change batches:
  - If batch GPS count is small, update silently.
  - If batch is large (configurable threshold), show overlay using the existing progress callback.

## Reverse-geocoding & Throttling
- Continue using `GeoIndex` actor:
  - rate limit (`maxRequestsPerMinute`)
  - cache (rounded key)
  - in-flight de-dup
- Additional safeguard: avoid geocoding when coordinates unchanged.

## Lifecycle

### On app start / view appear
1) Refresh Photos authorization.
2) If `.notDetermined`: show primer, request auth, then bootstrap index.
3) If authorized/limited:
   - Start watcher
   - Run bootstrap index if needed (first run)

### While app is running
- `photoLibraryDidChange(_:)` fires:
  - compute inserted/removed/changed deltas
  - apply to DB
  - refresh clusters / UI as needed

### When app is not running
- Changes are not processed in background (by requirement).
- On next launch, watcher + optional light “catch-up” scan may be used.

## Catch-up Strategy (Optional)
Because changes while the app is closed won’t be observed:
- Optionally run a bounded scan on launch (e.g., last N days by creationDate) to reduce misses.
- This is a pragmatic compromise; observer is primary.

## Testing Plan
1) **Old import**: add photos with old `creationDate` while app is running → verify inserted callback triggers and DB rows appear.
2) **Deletion**: delete a photo while app is running → verify DB row removed and pins update.
3) **Location removed**: edit photo to remove location (if feasible) → verify DB row removed.
4) **Throttling**: add many GPS photos → ensure rate limit + progress UI remains responsive.

## Open Questions
- Should bootstrap `fullReindex` keep doing `resetAll()` or switch to an upsert-only scan to preserve user-added DB fields (e.g. comments)?
- What threshold triggers progress overlay for change batches?
