#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Score baseline/skill texts from a CSV using ZeroGPT web UI via an existing CDP Chrome instance.

Inputs:
  - CSV with columns: scenario,prompt,baseline_result,skill_result
Outputs:
  - CSV with added columns:
      baseline_zerogpt_ai_gpt_percent, skill_zerogpt_ai_gpt_percent
      baseline_word_count, skill_word_count
      baseline_length_pass, skill_length_pass, length_range
  - Writes progress incrementally so it can resume.

Usage:
  python3 scripts/zerogpt_score_csv.py \
    --in /path/in.csv \
    --out /path/out.csv \
    --sleep 1.2

Resume behavior:
  - If --out exists, it will load it and skip already-scored rows (by row index).

Notes:
  - Requires ZeroGPT tab open in the OpenClaw CDP browser (127.0.0.1:18800).
  - ZeroGPT is flaky; this script is best-effort.
"""

import argparse, csv, json, os, random, re, sys, time
import urllib.request
from typing import Dict, List, Tuple, Optional

try:
    from playwright.sync_api import sync_playwright
except Exception as e:
    print("Playwright not installed in this python env. Try: python3 -m pip install playwright==1.49.0", file=sys.stderr)
    raise

WORD_RE = re.compile(r"\b\w+[’']?\w*\b")


def wc(s: str) -> int:
    return len(WORD_RE.findall(s or ""))


def extract_range(prompt: str) -> Optional[Tuple[int, int]]:
    if not prompt:
        return None
    m = re.search(r"(\d{2,4})\s*[–\-]\s*(\d{2,4})\s*words", prompt)
    if m:
        return int(m.group(1)), int(m.group(2))
    return None


def length_pass(n: int, rng: Optional[Tuple[int, int]]) -> str:
    if not rng:
        return ""
    lo, hi = rng
    return "PASS" if lo <= n <= hi else "FAIL"


def get_cdp_ws() -> str:
    ver = json.load(urllib.request.urlopen("http://127.0.0.1:18800/json/version"))
    return ver["webSocketDebuggerUrl"]


def find_zerogpt_page(browser):
    for ctx in browser.contexts:
        for pg in ctx.pages:
            if "zerogpt.com" in (pg.url or ""):
                return pg
    return None


def score_text(page, text: str, timeout_ms: int = 60000) -> str:
    # Ensure app is loaded
    page.goto("https://www.zerogpt.com/", wait_until="domcontentloaded")
    page.wait_for_selector("#textArea", timeout=timeout_ms)

    page.locator("#textArea").fill(text, timeout=timeout_ms)
    page.get_by_role("button", name=re.compile("Detect Text", re.I)).click(timeout=timeout_ms)

    # ZeroGPT UI can render the "Instructions for Educators and Evaluators" span as hidden
    # while still updating the result card. Waiting for it to be *visible* can hang.
    page.wait_for_selector("text=Instructions for Educators and Evaluators", state="attached", timeout=timeout_ms)

    # Prefer extracting from the first ancestor block that contains the "AI GPT" label.
    anchor = page.locator("text=Instructions for Educators and Evaluators").first
    card = anchor.locator('xpath=ancestor::*[contains(.,"AI GPT")][1]')

    # Wait until the card's text contains a percentage.
    page.wait_for_function(
        """(el) => el && /\b\d+(?:\.\d+)?%\s*AI\s*GPT\*?/i.test(el.innerText || '')""",
        arg=card,
        timeout=timeout_ms,
    )

    raw = card.inner_text(timeout=10000)
    m = re.search(r"(\d+(?:\.\d+)?)%\s*AI\s*GPT\*?", raw)
    return m.group(1) if m else ""


def load_rows(path: str) -> List[Dict[str, str]]:
    with open(path, newline='', encoding='utf-8') as f:
        return list(csv.DictReader(f))


def load_done_indices(out_path: str) -> set:
    if not os.path.exists(out_path):
        return set()
    done = set()
    with open(out_path, newline='', encoding='utf-8') as f:
        r = csv.DictReader(f)
        for i, row in enumerate(r, start=1):
            if (row.get('baseline_zerogpt_ai_gpt_percent') or '').strip() != '' and (row.get('skill_zerogpt_ai_gpt_percent') or '').strip() != '':
                done.add(i)
    return done


def write_rows(out_path: str, fieldnames: List[str], rows: List[Dict[str, str]]):
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, 'w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=fieldnames, quoting=csv.QUOTE_ALL)
        w.writeheader()
        w.writerows(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--in', dest='in_path', required=True)
    ap.add_argument('--out', dest='out_path', required=True)
    ap.add_argument('--sleep', type=float, default=1.2)
    ap.add_argument('--timeout-ms', type=int, default=60000)
    ap.add_argument('--standalone', action='store_true', help='Launch a fresh Playwright-controlled browser instead of attaching over CDP')
    args = ap.parse_args()

    # IMPORTANT: if --out already exists, load it so we preserve partial progress.
    # Otherwise, we'd overwrite previously-scored rows with blanks.
    if os.path.exists(args.out_path):
        in_rows = load_rows(args.out_path)
    else:
        in_rows = load_rows(args.in_path)

    # Expand rows with new columns
    for r in in_rows:
        r.setdefault('baseline_zerogpt_ai_gpt_percent', '')
        r.setdefault('skill_zerogpt_ai_gpt_percent', '')
        r.setdefault('baseline_word_count', '')
        r.setdefault('skill_word_count', '')
        r.setdefault('baseline_length_pass', '')
        r.setdefault('skill_length_pass', '')
        r.setdefault('length_range', '')

    # Determine done rows based on the in-memory rows (1-indexed)
    done = set()
    for i, row in enumerate(in_rows, start=1):
        if (row.get('baseline_zerogpt_ai_gpt_percent') or '').strip() != '' and (row.get('skill_zerogpt_ai_gpt_percent') or '').strip() != '':
            done.add(i)

    fieldnames = list(in_rows[0].keys())

    with sync_playwright() as p:
        if args.standalone:
            browser = p.chromium.launch(
                headless=False,
                executable_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                args=["--no-first-run", "--no-default-browser-check"],
            )
            page = browser.new_page()
        else:
            # CDP attach can be slow if the Chrome profile has many targets; use a larger timeout.
            browser = p.chromium.connect_over_cdp(get_cdp_ws(), timeout=120000)
            page = find_zerogpt_page(browser)
            if not page:
                # fallback to first page
                page = browser.contexts[0].pages[0]

            page.bring_to_front()

        for idx, row in enumerate(in_rows, start=1):
            if idx in done:
                continue

            prompt = row.get('prompt', '')
            rng = extract_range(prompt)
            if rng:
                row['length_range'] = f"{rng[0]}-{rng[1]}"

            bwc = wc(row.get('baseline_result', ''))
            swc = wc(row.get('skill_result', ''))
            row['baseline_word_count'] = str(bwc)
            row['skill_word_count'] = str(swc)
            row['baseline_length_pass'] = length_pass(bwc, rng)
            row['skill_length_pass'] = length_pass(swc, rng)

            # Score baseline
            try:
                row['baseline_zerogpt_ai_gpt_percent'] = score_text(page, row.get('baseline_result', ''), timeout_ms=args.timeout_ms)
            except Exception as e:
                row['baseline_zerogpt_ai_gpt_percent'] = ''
                print(f"[{idx}] baseline scoring failed: {e}", file=sys.stderr)

            time.sleep(args.sleep + random.uniform(0, 0.6))

            # Score skill
            try:
                row['skill_zerogpt_ai_gpt_percent'] = score_text(page, row.get('skill_result', ''), timeout_ms=args.timeout_ms)
            except Exception as e:
                row['skill_zerogpt_ai_gpt_percent'] = ''
                print(f"[{idx}] skill scoring failed: {e}", file=sys.stderr)

            print(f"{idx:04d}/{len(in_rows)} base={row['baseline_zerogpt_ai_gpt_percent']} skill={row['skill_zerogpt_ai_gpt_percent']}")

            # Write checkpoint every row
            write_rows(args.out_path, fieldnames, in_rows)

            time.sleep(args.sleep + random.uniform(0, 0.6))

        browser.close()

    print('DONE:', args.out_path)


if __name__ == '__main__':
    main()
