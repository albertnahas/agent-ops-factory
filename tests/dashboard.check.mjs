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
  [loops.good, loops.read] = await page.evaluate(() => { const t = [...document.querySelectorAll('#loop-groups .fx-more:not([hidden]) p')].map((p) => p.textContent);
    return [t.find((s) => s.startsWith('Good: ')), t.find((s) => s.startsWith('Read by '))]; });
  if (process.env.SHOTS) await withChanges.first().locator('xpath=..').screenshot({path: process.env.SHOTS + '/loop-changes.png'});
}
loops.firstCardAll = await page.locator('#loop-groups .fx-card:first-child .fx-all button').click({timeout: 1000})
  .then(() => page.evaluate(() => document.querySelectorAll('#loop-groups .fx-card:first-child .fx-row').length), () => null);
/* the prompt builder: its fields in order, then a prompt from filling every field one way (text "v-<id>", a longtext
   "a" and "b" on two lines, a repeat "x" and "y", each choice's first option, numbers left at their default) */
const fill = () => page.evaluate(() => {
  const set = (i, v) => { i.value = v; i.dispatchEvent(new Event('input')); };
  for (const q of document.querySelectorAll('#loop-form .fx-q')) {
    const radio = q.querySelector('input[type=radio]:not([value=""])'); if (radio) { radio.click(); continue; }
    const i = q.querySelector('.fx-input'); if (!i || i.readOnly || i.type === 'number') continue;
    set(i, i.placeholder === 'One per line' ? 'x\ny' : i.tagName === 'TEXTAREA' ? 'a\nb' : 'v-' + q.dataset.q);
  }
});
const built = async () => { await page.click('#loop-form .fx-form-body > .fx-btn'); await frames();
  return page.evaluate(() => ({prompt: document.querySelector('#loop-form .fx-prompt')?.textContent ?? null, copy: !!document.querySelector('#loop-form .fx-built .fx-btn'),
    founder: document.querySelectorAll('#loop-form .fx-founder').length, missing: document.querySelectorAll('#loop-form [data-missing]').length})); };
const fields = () => page.evaluate(() => [...document.querySelectorAll('#loop-form .fx-q')].map((q) => q.dataset.q));
const form = {offered: await page.locator('#loop-form .fx-btn', {hasText: 'New loop'}).count()};
if (form.offered) {
  await page.click('#loop-form .fx-btn'); await frames();
  form.fields = await fields(); form.empty = await built(); await fill(); form.new = await built();
  form.overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  const row = page.locator('#loop-groups .fx-row').first(); await row.click(); await frames();
  await row.locator('xpath=..').locator('.fx-btn', {hasText: 'Change this loop'}).click(); await frames();
  form.loop = await page.inputValue('#loop-form [data-q="loop"] .fx-input');
  form.editFields = await fields(); await fill(); form.edit = await built();
}
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
const evals = await page.evaluate(() => ({rows: Object.fromEntries([...document.querySelectorAll('#evals .fx-eval')].map((li) => [li.firstChild.textContent, li.lastChild.textContent])),
  below: document.querySelectorAll('#evals .fx-row').length}));
if (process.env.SHOTS) await page.locator('#evals').screenshot({path: process.env.SHOTS + '/evaluations.png'});
const improver = {scope, hidden: await page.locator('#improver').isHidden(), rows: await page.locator('#improver .fx-row').count(), rate: await page.textContent('[data-draw="improver-rate"]')};
if (improver.rows) {
  await page.locator('#improver .fx-row').first().click(); await frames();
  improver.detail = await page.evaluate(() => /Why: .*Replay: /s.test(document.querySelector('#improver .fx-more:not([hidden])')?.textContent || ''));
  if (process.env.SHOTS) await page.locator('#improver').screenshot({path: process.env.SHOTS + '/improver.png'});
}
ms.overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
await browser.close();
console.log(JSON.stringify({ms, errors, attention, factory, loops, improver, form, evals, waiting: {...waiting, invalid: /Invalid Date|NaN/.test(waiting.text), text: undefined}}));
