# PhotoAtlas — Indexing progress bar (GPS photos) design

Date: 2026-02-24

## Goal
When PhotoAtlas automatically indexes photos on app launch (or immediately after Photos permission is granted), show a bottom UI progress indicator so the user can tell whether indexing is running and roughly when it will finish.

## Non-goals
- No manual “Menu” button or manual indexing UI.
- No progress UI for cluster refresh (pins refresh) alone.
- No attempt to re-display iOS system permission prompts after the user has decided (iOS does not allow that).

## UX requirements
- Progress UI appears only while *automatic* indexing is in progress.
- Display a percentage that reliably reaches **100%**.
- Percentage is based on **GPS-indexable photos** (assets with `asset.location != nil`).
- UI is a slim bottom bar on `MapScreen`, above the safe area.
- UI updates are throttled (avoid updating SwiftUI for every asset).
- When indexing completes, the bar disappears (optional brief “complete” state is allowed, but v1 can simply hide).

## Proposed UI
A bottom overlay on `MapScreen`:
- `Text`: "Indexing GPS photos… 37% (123/333)"
- `ProgressView(value: progress)` (linear)

Only visible when `model.isIndexing == true`.

## Data flow / architecture

### 1) PhotosIndexer emits progress
Add a progress callback API to `PhotosIndexer`:
- Pre-scan pass counts `totalGPS` across the `PHFetchResult`.
- Index pass processes assets as today.
- Each time a GPS photo is fully processed (reverse-geocode + DB upsert), increment `doneGPS` and report progress.

Progress callback signature (conceptual):
- `onProgress(doneGPS: Int, totalGPS: Int)`

Throttling:
- Update at most every ~200ms OR every N GPS photos (e.g. every 25/50), whichever is less frequent.

### 2) AppModel owns published progress state
Add to `AppModel`:
- `@Published var isIndexing: Bool`
- `@Published var indexProgress: Double` (0…1)
- `@Published var indexProgressText: String` ("123/333")

`autoIndexIfPossible()` sets `isIndexing = true` around the index call and resets on completion/failure.

### 3) MapScreen renders bottom bar
`MapScreen` reads `model.isIndexing/indexProgress/indexProgressText` and overlays the bottom progress bar.

## Edge cases
- **No GPS photos** (`totalGPS == 0`): don’t show progress UI; set summary to something like “No GPS photos found.”
- **Limited Photos access**: progress reflects only the accessible subset.
- **Index errors**: hide progress, show `lastIndexSummary = "Index failed: …"`.

## Success criteria
- On launch with Photos permission already granted, progress bar appears and increments until it hits 100% then disappears.
- Percentage is stable and reaches 100% even when many photos lack GPS.
- UI remains responsive (no per-asset UI churn).
