# Release-Safe Bugfix Checklist (PhotoAtlas)

Use this checklist for every production bug fix to minimize regression risk.

## 1) Scope and risk
- [ ] Bug is clearly reproducible (steps + expected vs actual).
- [ ] Root cause identified (not just symptom patch).
- [ ] Change scope is minimal and isolated to the bug path.
- [ ] Risk level noted (Low / Medium / High) with rationale.

## 2) Implementation guardrails
- [ ] Avoid broad refactors in the same PR.
- [ ] No unrelated formatting / cleanup changes.
- [ ] Preserve existing behavior outside bug scope.
- [ ] Feature flags / toggles considered if risk is medium/high.

## 3) Verification
- [ ] Clean build on simulator succeeds.
- [ ] Bug repro steps now pass.
- [ ] At least one negative/edge case verified.
- [ ] Core smoke checks pass:
  - [ ] App launch
  - [ ] Map screen load and basic interaction
  - [ ] Photos permission flow still sane
  - [ ] Primary navigation paths open/close correctly

## 4) Tests (when practical)
- [ ] Add or update targeted unit/integration test for the bug path.
- [ ] Existing related tests still pass.
- [ ] If test not added, reason documented in PR.

## 5) Release safety notes (required in PR)
- [ ] "What changed" (1-3 bullets)
- [ ] "What did NOT change" (explicit non-goals)
- [ ] "Regression risk" section
- [ ] "Rollback plan" (how to revert safely)

## 6) Final gate
- [ ] Diff reviewed for accidental config or plist changes.
- [ ] No debug logs / temporary code left behind.
- [ ] Commit message is clear and bug-focused.
- [ ] Ready for merge.

---

## PR template snippet (copy/paste)

### Release-safe bugfix summary
- **Bug:** 
- **Root cause:** 
- **Fix scope:** 
- **Risk level:** Low / Medium / High

### Verification
- Repro before: 
- Repro after: 
- Smoke checks run: 
- Tests added/updated: 

### Non-goals (what did not change)
- 

### Rollback plan
- 
