# Change Log

This file tracks all modifications made to the codebase starting from February 19, 2026, 22:54.

## [2026-02-19 22:53] Highlight pins with orange color only
**Requirement**: Change pin color to orange when navigating between cities/countries, but do NOT increase the size and do NOT show the callout automatically.
**Files Modified**:
- `OfflineMapViewRepresentable.swift`:
    - Added `@Binding var selectedClusterId: String?`.
    - Added `updateAnnotationColors(in:)` to manually update `markerTintColor`.
    - Updated `updateUIView` to call `updateAnnotationColors`.
    - Updated `didSelect` and `didDeselect` to update the binding and call the color update.
- `MapScreen.swift`:
    - Passed `$selectedClusterId` to `OfflineMapViewRepresentable`.

## [2026-02-19 22:56] Zoom to city during navigation
**Requirement**: When navigating between cities, zoom in if the current view is too wide (to ensure smaller cities are actually visible).
**Files Modified**:
- `MapScreen.swift`:
    - Updated `navigatePins(step:)` to check if `precision == .city`.
    - If current `latitudeDelta > 1.0`, it now force-zooms to a span of `0.4` around the target city center.

## [2026-02-19 23:00] Precision levels dropdown
**Requirement**: Add a dropdown to manually switch between Country and City levels on the map.
**Files Modified**:
- `MapScreen.swift`:
    - Replaced the static precision label in the toolbar with a `Menu`.
    - Added `switchPrecision(to:)` method to handle manual switching.
    - Manual switch now automatically zooms to an appropriate span (`40.0` for Countries, `2.0` for Cities) to prevent immediate auto-reversion of the level.

## [2026-02-19 23:02] Dropdown style refinement
**Requirement**: Ensure the precision dropdown style is consistent with the rest of the app's UI.
**Files Modified**:
- `MapScreen.swift`:
    - Updated `Menu` label to use `.regularMaterial` background instead of a semi-transparent gray.
    - Standardized padding to `horizontal: 10, vertical: 6` to match the "Current Selection Label" and other capsule elements in the app.
    - Slightly reduced the chevron size for a more refined look.

## [2026-02-19 23:06] Simplify dropdown title
**Requirement**: Remove the "Pins:" prefix from the precision dropdown title.
**Files Modified**:
- `MapScreen.swift`:
    - Updated `labelForPrecision(_:)` to return "Countries" or "Cities" instead of "Pins: Countries" or "Pins: Cities".

## [2026-02-19 23:10] Add share icon to photo detail
**Requirement**: Add a share icon to the photo detail view to allow sharing/opening the image in other apps.
**Files Modified**:
- `PhotoDetailScreen.swift`:
    - Added a `ShareLink` to the navigation bar trailing toolbar items. This allows users to share the high-quality image using the standard system share sheet.

## [2026-02-19 23:13] Fix share sheet presentation
**Requirement**: Fix "already presenting" error when opening the share sheet from the photo detail view.
**Files Modified**:
- `PhotoDetailScreen.swift`:
    - Updated `shareAction` to walk the `presentedViewController` chain. This ensures the share sheet is presented from the top-most view (like the pager sheet) rather than the root view, fixing the presentation conflict.

---
