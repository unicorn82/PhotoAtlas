# Benchmark Corpus (Scope Only) — DM + Social

Purpose: a compact, repeatable set of prompts to evaluate **Human-Style-Writing** where it’s intended to work:
- **daily chat (DM/text)**
- **social posts/captions** (platform-specific)

Design goals:
- mix **EN / 中文 / mixed**
- include **short + medium** length
- include realistic constraints (relationships, stakes, mild emotion)

## How to use
For each item:
- generate output with the skill
- optionally compare to a baseline output
- score in ZeroGPT (and/or other detectors) best-effort

---

## DMs / texts (daily_chat)
### D1 (EN) — reschedule
Text someone you know casually: you’re running late, ask to push 20 minutes, apologize once.

### D2 (EN) — follow-up without being pushy
DM a recruiter after an interview last week. Friendly, concise.

### D3 (EN) — say no
Reply to a friend inviting you to a trip you can’t afford. Warm, honest, no long explanation.

### D4 (ZH) — 道歉+解释一点点
给同事发微信：你今天没回消息不是故意的，简单解释一下原因，并说晚点补上。

### D5 (ZH) — 约时间
给朋友发：这周末想约吃饭，给两个时间选项，语气随意。

### D6 (mixed) — bilingual quick ask
Send a short DM mixing English + 中文 asking for a quick favor (review a doc), not too formal.

---

## X / Twitter (social_x)
### X1 (EN) — single tweet
A quick observation about learning something the hard way. 2–4 short lines, not inspirational.

### X2 (EN) — short thread
5-tweet thread: what you changed in your workflow that saved you time. Concrete details, no guru vibe.

### X3 (mixed) — bilingual
One tweet mixing English + 中文 reacting to a small everyday moment. Keep it natural.

---

## Reddit (social_reddit)
### R1 (EN) — helpful comment
Reply to someone asking “How do you stay consistent?” Be specific, include 1 personal constraint, end with a question.

### R2 (EN) — post
Write a short post: you tried a habit for 2 weeks, mixed results, ask for advice. Don’t sound like marketing.

---

## LinkedIn (social_linkedin)
### L1 (EN) — professional but human
A short post about a project that went sideways and what you learned. Concrete, no cliché closer.

---

## Instagram / TikTok captions
### I1 (EN) — IG caption
Caption for a photo of a quiet morning: short, vivid, not poetic.

### T1 (ZH) — TikTok 文案
一个很短的视频文案：展示你做饭翻车了。要像字幕一样短。

---

## 小红书 / 朋友圈
### XHS1 (ZH) — 小红书笔记
分享你最近用的一个小工具/方法（不提品牌），结构：一句背景 + 4条体验点 + 一句收尾。

### MOM1 (ZH) — 朋友圈
发朋友圈：今天心情不错但不想说太多，1–3句，带一个具体小细节。
