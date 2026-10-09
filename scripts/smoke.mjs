// Headless end-to-end check: builds must already exist (npm run build) and a preview
// server must be running (npm run preview -- --port 4173). Runs the in-browser
// simulator for each preset and reports decode time.
//   npm run smoke
import { chromium } from 'playwright';

const base = process.env.SMOKE_URL ?? 'https://localhost:4173/';
const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROME_PATH || undefined });
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 800, height: 1200 } });
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));

async function run(preset, palette, px, blur, text, timeoutMs) {
  await page.goto(`${base}#sim`, { waitUntil: 'networkidle' });
  const selects = page.locator('select');
  await selects.nth(0).selectOption(preset);
  await selects.nth(1).selectOption(palette);
  const nums = page.locator('input[type=number]');
  await nums.nth(0).fill(String(px));
  await nums.nth(1).fill(String(blur));
  await page.locator('textarea').fill(text);
  await page.getByRole('button', { name: 'Run' }).click();
  const start = Date.now();
  let status = '';
  while (Date.now() - start < timeoutMs) {
    status = await page.locator('.card').first().innerText();
    if (status.startsWith('DONE')) break;
    await page.waitForTimeout(500);
  }
  const got = await page.locator('.rx-message').innerText();
  const ok = status.startsWith('DONE') && got === text;
  console.log(`${ok ? 'PASS' : 'FAIL'} ${preset}/${palette} @${px}px blur ${blur}: ${status}`);
  return ok;
}

let ok = true;
ok &= await run('near', 'rgbw', 24, 1, 'The quick brown fox jumps over the lazy dog', 40000);
ok &= await run('near', 'rgw', 12, 1, 'near, no blue, 12 px', 40000);
ok &= await run('mid', 'rgbw', 8, 2, 'mid ok', 60000);
if (process.env.SMOKE_FAR) ok &= await run('far', 'wr', 6, 1, 'hi', 240000);
await browser.close();
if (errors.length) console.log('page errors:', errors);
process.exit(ok ? 0 : 1);
