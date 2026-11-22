// Opens a built dashboard.html in headless Chromium at phone width and prints one JSON line: how long the page takes to
// load, open the Factory tab, show its Checks lines and switch scope, what the page threw, and what each tab shows.
// Usage: node tests/dashboard.check.mjs <dashboard.html> [scope]   SHOTS=<dir> also saves phone-width screenshots of a loop's
// change history and the Improver card there.   Exits 2 when Playwright is missing (set PLAYWRIGHT to
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
const attention = await page.evaluate(() => document.querySelectorAll('#attention .fx-row').length);
await page.click('#tab-loops'); await frames();
const loops = await page.evaluate(() => ({
  cards: document.querySelectorAll('#loop-groups .fx-card').length,
  firstCard: document.querySelectorAll('#loop-groups .fx-card:first-child .fx-row').length,
  /* a header's loop count stays inside the header, however long the name */
  countsVisible: [...document.querySelectorAll('#loop-groups .fx-group small')].every((s) => {
    const r = s.getBoundingClientRect(); return r.width > 0 && r.right <= s.closest('.fx-group').getBoundingClientRect().right + 1;
  }),
  /* a name in a card header stays before its count, whatever its script */
  countsAfterNames: [...document.querySelectorAll('#loop-groups .fx-group > span:first-child')].every((s) => {
    const small = s.querySelector('small'), count = document.createRange(); count.setStart(small.firstChild, 0); count.setEnd(small.firstChild, 1);
    return count.getBoundingClientRect().left >= s.querySelector('bdi').getBoundingClientRect().right - 1;
  }),
}));
const withChanges = page.locator('#loop-groups .fx-row', {has: page.locator('bdi', {hasText: /^shop1$/})});
if (await withChanges.count()) {
  await withChanges.first().click(); await frames();
  loops.changes = await page.evaluate(() => document.querySelectorAll('#loop-groups .fx-more:not([hidden]) .fx-changes li').length);
  if (process.env.SHOTS) await withChanges.first().locator('xpath=..').screenshot({path: process.env.SHOTS + '/loop-changes.png'});
}
loops.firstCardAll = await page.locator('#loop-groups .fx-card:first-child .fx-all button').click({timeout: 1000})
  .then(() => page.evaluate(() => document.querySelectorAll('#loop-groups .fx-card:first-child .fx-row').length), () => null);
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
  note: !!document.querySelector('#factory-note:not([hidden])'),
  picks: [...document.querySelectorAll('#factory-graph .fx-btn')].map((b) => b.textContent),
}));
if (factory.picks.length) {
  await page.click('#factory-graph .fx-btn'); await frames();
  factory.picked = await page.evaluate(() => document.querySelectorAll('#factory-graph .fx-fnode[data-tone]').length);
}
const improver = {scope, rows: await page.locator('#improver .fx-row').count(), rate: await page.textContent('[data-draw="improver-rate"]')};
if (improver.rows) {
  await page.locator('#improver .fx-row').first().click(); await frames();
  improver.detail = await page.evaluate(() => /Why: .*Replay: /s.test(document.querySelector('#improver .fx-more:not([hidden])')?.textContent || ''));
  if (process.env.SHOTS) await page.locator('#improver').screenshot({path: process.env.SHOTS + '/improver.png'});
}
ms.overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
await browser.close();
console.log(JSON.stringify({ms, errors, attention, factory, loops, improver, waiting: {...waiting, invalid: /Invalid Date|NaN/.test(waiting.text), text: undefined}}));
