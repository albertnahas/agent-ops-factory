// Opens a built dashboard.html in headless Chromium at phone width and prints one JSON line: how long the page takes to
// load, open the Factory tab, show its Checks lines and switch scope, what the page threw, and what each tab shows.
// Usage: node tests/dashboard.check.mjs <dashboard.html> [scope]   Exits 2 when Playwright is missing (set PLAYWRIGHT to
// its index.mjs if it isn't installed where node finds it).
const pw = await import(process.env.PLAYWRIGHT || 'playwright').catch(() => null);
if (!pw) { console.error('playwright not found'); process.exit(2); }
const [file, scope = ''] = process.argv.slice(2);
const browser = await pw.chromium.launch();
const page = await browser.newPage({viewport: {width: 375, height: 812}});
const errors = [];
page.on('pageerror', (e) => errors.push(String(e)));
page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
const frames = () => page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
const timed = async (f) => { const t = Date.now(); await f(); await frames(); return Date.now() - t; };
const ms = {};
ms.load = await timed(() => page.goto('file://' + file));
await page.click('#tab-loops'); await frames();
const loops = await page.evaluate(() => ({
  cards: document.querySelectorAll('#loop-groups .fx-card').length,
  /* a name in a card header stays before its count, whatever its script */
  countsAfterNames: [...document.querySelectorAll('#loop-groups .fx-group > span:first-child')].every((s) => {
    const small = s.querySelector('small'), name = document.createRange(), count = document.createRange();
    name.setStartBefore(s.firstChild); name.setEndBefore(small); count.setStart(small.firstChild, 0); count.setEnd(small.firstChild, 1);
    return count.getBoundingClientRect().left >= name.getBoundingClientRect().right - 1;
  }),
}));
await page.click('#tab-waiting'); await frames();
const waiting = await page.evaluate(() => ({
  badge: +document.querySelector('[data-draw="badge-waiting"]').textContent || 0,
  rows: document.querySelectorAll('#waiting .fx-row').length,
  text: document.querySelector('#waiting').textContent,
}));
ms.factory = await timed(() => page.click('#tab-factory'));
ms.checks = await timed(() => page.click('.fx-ltog[data-layer="check"]'));
ms.scope = await timed(() => page.selectOption('#scope', scope));
const factory = await page.evaluate(() => ({
  count: document.querySelector('[data-draw="factory-count"]').textContent,
  loops: document.querySelectorAll('#factory-graph .fx-fnode[data-tone]').length,
  you: document.querySelectorAll('#factory-graph .fx-fend.you').length,
  nobody: document.querySelectorAll('#factory-graph .fx-fend.nobody').length,
  lines: document.querySelectorAll('#factory-graph .fx-fedges path').length,
}));
ms.overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
await browser.close();
console.log(JSON.stringify({ms, errors, factory, loops, waiting: {...waiting, invalid: /Invalid Date|NaN/.test(waiting.text), text: undefined}}));
