const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

function nowIsoMT() {
  // Best-effort: use local time (machine is America/Denver)
  const d = new Date();
  const pad = (n) => String(n).padStart(2,'0');
  const yyyy = d.getFullYear();
  const mm = pad(d.getMonth()+1);
  const dd = pad(d.getDate());
  const hh = pad(d.getHours());
  const mi = pad(d.getMinutes());
  const ss = pad(d.getSeconds());
  return `${yyyy}-${mm}-${dd} ${hh}:${mi}:${ss}`;
}

function parseCorpus(md) {
  // Parse only blocks that start with headings like: "## T1" "## T2" ...
  const re = /^##\s+(T\d+)\b[\s\S]*?(?=^##\s+T\d+\b|\Z)/gm;
  const items = [];
  let m;
  while ((m = re.exec(md)) !== null) {
    const id = m[1];
    const block = m[0];
    const body = block.replace(/^##\s+T\d+\b.*\n/, '').trim();

    // Heuristic: if block begins with **Notes** paragraph, drop it and keep remaining.
    const parts = body.split(/\n\n+/);
    let text = body;
    if (parts.length >= 2 && /^\*\*Notes\*\*/.test(parts[0])) {
      text = parts.slice(1).join('\n\n').trim();
    }
    items.push({ id, raw: body, text });
  }
  return items;
}

async function main() {
  const outDir = path.join(process.cwd(), 'docs/ai-detector-testing/screenshots');
  fs.mkdirSync(outDir, { recursive: true });

  const corpusPath = path.join(process.cwd(), 'docs/ai-detector-testing/corpus.md');
  const corpus = fs.readFileSync(corpusPath, 'utf8');
  const items = parseCorpus(corpus);

  // Use system Chrome (Playwright-bundled Chromium may not run on older macOS builds)
  const browser = await chromium.launch({
    headless: false,
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
  });
  const context = await browser.newContext();
  const page = await context.newPage();

  const detector = 'gptzero';
  const url = 'https://gptzero.me/';

  for (const item of items) {
    const runId = `${detector}-${item.id}-${Date.now()}`;
    console.log(`\n[${runId}] testing ${item.id}...`);

    await page.goto(url, { waitUntil: 'domcontentloaded' });

    // Find main textarea
    const ta = page.getByPlaceholder('Paste your text or');
    await ta.waitFor({ timeout: 15000 });

    // Fill reliably
    await ta.click();
    await ta.fill(item.text);

    // Try to find a scan button near detector widget.
    // GPTZero changes UI; attempt several likely labels.
    const candidates = [
      page.getByRole('button', { name: /scan/i }),
      page.getByRole('button', { name: /advanced scan/i }),
      page.getByRole('button', { name: /detect/i }),
    ];

    let clicked = false;
    for (const btn of candidates) {
      const count = await btn.count();
      if (count > 0) {
        try {
          await btn.first().click({ timeout: 3000 });
          clicked = true;
          break;
        } catch (e) {}
      }
    }

    // Wait a bit for results to render
    await page.waitForTimeout(4000);

    // Best-effort extraction: look for common result phrases on the page
    const textContent = await page.locator('body').innerText();
    let label = '';
    let score = '';
    const mPct = textContent.match(/(\d{1,3})%\s*(?:AI|likely AI|AI-generated|generated)/i);
    if (mPct) score = mPct[1] + '%';
    const mLikely = textContent.match(/(likely\s+AI|likely\s+human|human|AI-generated)/i);
    if (mLikely) label = mLikely[1];

    const screenshotPath = path.join(outDir, `${runId}.png`);
    await page.screenshot({ path: screenshotPath, fullPage: true });

    const ts = nowIsoMT();
    const chars = item.text.length;

    // Append to results.md as a markdown row
    const row = `| ${runId} | ${ts} | ${detector} | ${url} | ${item.id} |  |  | ${chars} | ${label} | ${score} | clicked=${clicked} | ${path.relative(process.cwd(), screenshotPath)} |\n`;
    fs.appendFileSync(path.join(process.cwd(), 'docs/ai-detector-testing/results.md'), row);

    // Small delay to reduce rate-limit risk
    await page.waitForTimeout(1500);
  }

  await browser.close();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
