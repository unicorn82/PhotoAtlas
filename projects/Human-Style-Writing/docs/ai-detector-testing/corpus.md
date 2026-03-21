# Test Corpus (CN/EN/mixed) — human-style-writing

Each item has: id, scenario_id, language, notes, text.

## T1 — S1_chat_short — zh
**Notes:** 微信式临时改时间

你明天上午那个会能不能往后挪半小时？我这边 9:30 可能还在路上。
如果不方便就算了，我也可以先把要点发你，你到时直接看。

## T2 — S1_chat_short — en
**Notes:** casual DM ask

Quick check—can you send me the latest deck when you get a sec? No rush, just trying to review it before tomorrow.

## T3 — S2_social_post — en
**Notes:** generic social post, mild personality

I used to roll my eyes at “morning routines,” but one tiny thing finally worked for me: I write down the next one task before I close my laptop at night.

Not a list. Not a plan. Just the next step.

It sounds dumb, but it cut out that first 10 minutes of scrolling and deciding. I still have messy days, but at least I start moving.

Curious what’s the smallest habit that actually changed your week?

## T4 — S2_social_post — zh
**Notes:** 通用社媒分享

以前我也不信“自律打卡”那一套，但最近真被一个小习惯救了：每天收工前写下“明天第一步要做什么”。
不是列清单，就是一句话。

第二天打开电脑不用先纠结半天，直接开始做。也不是每天都成功，但至少不那么容易空转。

你有没有那种看起来很小、但真的改变效率的习惯？

## T5 — S3_work_email — zh
Subject: 确认 Q2 需求范围（截止周二 12:00）

你好 [Name]，

我在整理 Q2 的交付计划，想跟你确认一下这次版本是否包含下面两点：
1) 登录页的文案与错误提示统一（按最新设计稿）
2) 新增导出 CSV 的入口（仅管理员可见）

如果没问题，我会按这个范围更新排期，并在周二下午把里程碑发出来。
方便的话请你在周二中午 12:00 前回复确认或指出需要调整的点。

谢谢，
[Your Name]

## T6 — S4_work_report — en
**Notes:** weekly status style

## This week
- Shipped the CSV export toggle behind admin permissions.
- Reduced report generation time from ~14s to ~6s by caching the most expensive query.

## Risks / blocks
- We still don’t have a clear owner for the data retention policy review.
- QA is blocked on a realistic dataset; current tests are too small to catch memory spikes.

## Next week
- Add a failure-mode test for timeouts and partial exports.
- Align with Legal on retention requirements and update the spec.

## Asks
- Can someone from Data share a sanitized dataset (or guidelines) by Wednesday?

## T7 — S6_news — en
Denver, March 13, 2026 — Acme Labs today announced an update to its desktop application that adds offline export for user activity reports.

The update allows users to generate reports without an internet connection and save them in CSV format. According to the company, the change is aimed at teams working in restricted network environments and field settings.

“We heard consistently that exporting data shouldn’t depend on connectivity,” said Jamie Chen, Product Lead at Acme Labs. “This release focuses on reliability and predictable workflows.”

The update is available starting today for Windows and macOS. The company said Linux support is planned for a later release.

## T8 — S5_academic — en
We evaluate the robustness of AI-generated text detectors under realistic editing conditions. Specifically, we compare detector outputs on (i) raw model-generated drafts, (ii) lightly edited drafts that preserve content while adjusting style, and (iii) human-written baselines. Our results suggest that detector confidence decreases substantially after superficial edits (e.g., sentence splitting, synonym substitution, and paragraph restructuring), even when no new factual content is introduced. This indicates that detector scores may be more sensitive to surface-level distributional cues than to underlying authorship. A limitation of our study is that it focuses on a small set of detectors and English-language text; performance may differ across languages and domains.

## T9 — S5_academic — zh
我们考察了文本生成检测器在“轻度编辑”条件下的鲁棒性。具体而言，我们比较了检测器对以下三类文本的输出：(i) 模型直接生成的初稿；(ii) 在不引入新事实的前提下，对句式与段落结构进行轻度改写后的文本；(iii) 人类撰写的基线文本。实验结果表明，许多检测器在面对表层改写时置信度会显著下降，这提示其判断可能更依赖分布特征而非真实作者身份。本文的局限在于：我们仅评估了有限数量的检测器，且主要关注中文与英文场景，跨语言与跨领域的泛化能力仍需进一步验证。

## T10 — mixed
**Notes:** bilingual workplace note

FYI 我刚把 export 的权限逻辑补上了（admin-only）。
If you have 10 minutes today, could you sanity-check the UI copy? 我担心现在的错误提示有点硬。

