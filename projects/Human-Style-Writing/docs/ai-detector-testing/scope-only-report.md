# Human-Style-Writing — Scope-Only Decision + ZeroGPT Results Summary

Date: 2026-03-20 (MDT)

## Decision
We will keep **Human-Style-Writing** strictly **in-scope for daily chat (DM/text) + social posts/captions**.

If asked for other registers (academic, news/press, legal/compliance, marketing copy, customer-support macros, work emails/reports), the skill should **stop and ask one clarifying question** (DM/text vs social + platform), then rewrite into the chosen surface.

Rationale: our evaluation shows strong wins in conversational scenarios, but regressions in academic/news—optimizing across all registers is a different project.

---

## What we evaluated
Dataset:
- File: `human-style-writing-abtest-700-en-scored.complete668.csv`
- Rows scored: **668** paired samples
- Detector used for scoring: **ZeroGPT** (“AI GPT %”)

Each row includes:
- `baseline_result` vs `skill_result`
- ZeroGPT scores: `baseline_zerogpt_ai_gpt_percent` and `skill_zerogpt_ai_gpt_percent`

---

## Top-line results (ZeroGPT)
Overall (n=668):
- **Baseline mean:** 30.21%
- **Skill mean:** 18.43%
- **Mean delta (skill − baseline):** **−11.78 pts**
- **Median delta:** 0.0 pts
- Skill lower than baseline: **32%** of samples
- Skill higher than baseline: **16%** of samples

Score mass at 0%:
- Baseline exactly 0%: **58.4%**
- Skill exactly 0%: **71.6%**

Interpretation: the skill often moves texts into the “0% AI GPT” bucket on ZeroGPT, but improvements are concentrated in specific registers.

---

## Results by scenario (mean)
(Delta = skill − baseline; negative is “more human” per ZeroGPT.)

| Scenario | n | Baseline mean | Skill mean | Mean delta |
|---|---:|---:|---:|---:|
| Daily chat | 99 | 57.93% | 0.00% | **−57.93** |
| Customer support | 92 | 49.26% | 24.04% | **−25.22** |
| Workplace writing | 98 | 15.92% | 6.65% | **−9.28** |
| Marketing | 96 | 18.73% | 10.78% | **−7.95** |
| Legal/compliance | 97 | 10.81% | 11.64% | +0.83 |
| News/press | 96 | 43.93% | 50.38% | **+6.45** |
| Academic | 90 | 14.33% | 27.23% | **+12.90** |

Key takeaway:
- **Daily chat** is a massive win (which matches the intended scope).
- **News/press + Academic** regress under this skill’s approach.

---

## Product implication: keep the skill honest about scope
Given the regressions, the skill should:
1) **Refuse/redirect** off-scope requests (ask DM/social + platform)
2) Avoid emitting “academic/news/legal” templates under the hood

This avoids a common failure mode: forcing an LLM “humanization” recipe onto formal registers, which can introduce symmetry/over-structure that detectors and humans both notice.

---

## Next actions
1) **Skill guardrails**
   - Update `SKILL.md` and `references/scenario-router.md` to treat off-scope as a hard redirect.

2) **On-scope benchmark corpus** (new)
   - Create a smaller benchmark focused on the real goal:
     - DM/text: apologies, scheduling, follow-up, quick asks, declines
     - X: single tweet + short thread
     - Reddit: comment + post
     - LinkedIn: short post
     - 小红书/朋友圈: short captions/notes
   - Add CN + EN + mixed.

3) **Re-score with ZeroGPT harness**
   - Run the ZeroGPT script only on the on-scope benchmark.
   - Track before/after when we change recipes.

Notes:
- GPTZero automation exists but extraction is currently unreliable; keep ZeroGPT as the primary quantitative measure until GPTZero parsing is fixed.
