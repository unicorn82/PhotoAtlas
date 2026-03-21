# AI Detector Testing — Progress

## 2026-03-14
- Bootstrapped testing folder:
  - `corpus.md` (T1–T10)
  - `results.md` (table)
  - `screenshots/`
- Implemented `run_detectors_gptzero.js` using Playwright.
- Playwright bundled Chromium failed on Darwin 20.6 due to missing `LocalAuthenticationEmbeddedUI.framework` → switched to system Chrome via `executablePath`.
- Ran a full loop and captured screenshots.

### Known issue
- GPTZero result parsing is currently **not reliable** (grep of whole-page text can match site marketing copy). Need DOM-specific selectors for the result panel.

### Next
- Fix GPTZero parsing.
- Add a second detector with simpler DOM.
- Run baseline again and then iterate `human-style-writing` only for human-likeness improvements.
