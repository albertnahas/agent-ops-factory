// Opens a built dashboard.html in headless Chromium and prints one JSON line: how long the page takes to load, draw the
// Factory graph, show its Checks lines and switch scope, what the page threw, and what each part shows: Needs you, the
// phone's route list, a loop's drawer and its conversation, the loop form, Feeds, Fleet health and the Improver.
// Usage: node tests/dashboard.check.mjs <dashboard.html> [scope]   SHOTS=<dir> also saves phone-width screenshots of a
// loop's drawer, Fleet health and the Improver there.   Exits 2 when Playwright is missing (set PLAYWRIGHT to its
// index.mjs if it isn't installed where node finds it).
const pw = await import(process.env.PLAYWRIGHT || 'playwright').catch(() => null);
if (!pw) { console.error('playwright not found'); process.exit(2); }
const [file, scope = ''] = process.argv.slice(2);
const browser = await pw.chromium.launch();
const phone = {width: 375, height: 812}, desk = {width: 1200, height: 900};
const page = await browser.newPage({viewport: phone});
const errors = [];
page.on('pageerror', (e) => errors.push(String(e)));
page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
/* two frames, then any finite animation done (the drawer slides in), so a measure sees where things land */
const frames = () => page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))
  .then(() => Promise.all(document.getAnimations().filter((a) => a.effect.getTiming().iterations !== Infinity).map((a) => a.finished.catch(() => {})))));
const timed = async (f) => { const t = Date.now(); await f(); await frames(); return Date.now() - t; };
const close = async () => { await page.keyboard.press('Escape'); await frames(); };
const sheetText = () => page.evaluate(() => [...document.querySelectorAll('.fx-sheet p')].map((p) => p.textContent));
const ms = {};
ms.load = await timed(async () => { await page.goto('file://' + file); await page.waitForFunction(() => dash.data('loops').status === 'ok'); });

/* Needs you, from the status line: what needs a look, capped, then every waiting item, dated or not */
await page.click('.fx-pill'); await frames();
const attention = await page.evaluate(() => document.querySelectorAll('.fx-sheet .fx-lrow').length);
const waiting = await page.evaluate(() => ({
  badge: +(document.querySelectorAll('.fx-pill')[1]?.querySelector('b')?.textContent || 0),
  rows: document.querySelectorAll('.fx-sheet .fx-row:not(.fx-lrow)').length,
  invalid: /Invalid Date|NaN/.test(document.querySelector('.fx-sheet').textContent),
}));
/* the drawer is a stack: a loop opened from Needs you goes back to it */
const back = {};
if (attention) {
  await page.click('.fx-sheet .fx-lrow'); await frames();
  back.loop = await page.textContent('.fx-sheet h2');
  await page.click('.fx-sheet .fx-back'); await frames();
  back.title = await page.textContent('.fx-sheet h2');
}
await close();

/* the loop form, from New loop: its fields in order, then a prompt from filling every field one way (text "v-<id>", a
   longtext "a" and "b" on two lines, a repeat "x" and "y", each choice's first option, numbers left at their default) */
const fill = () => page.evaluate(() => {
  const set = (i, v) => { i.value = v; i.dispatchEvent(new Event('input')); };
  for (const q of document.querySelectorAll('.fx-sheet .fx-q')) {
    const radio = q.querySelector('input[type=radio]:not([value=""])'); if (radio) { radio.click(); continue; }
    const i = q.querySelector('.fx-input'); if (!i || i.readOnly || i.type === 'number') continue;
    set(i, i.placeholder === 'One per line' ? 'x\ny' : i.tagName === 'TEXTAREA' ? 'a\nb' : 'v-' + q.dataset.q);
  }
});
const built = async () => { await page.click('.fx-sheet .fx-form-body > .fx-btn'); await frames();
  return page.evaluate(() => ({prompt: document.querySelector('.fx-sheet .fx-prompt')?.textContent ?? null, copy: !!document.querySelector('.fx-sheet .fx-built .fx-btn'),
    founder: document.querySelectorAll('.fx-sheet .fx-founder').length, missing: document.querySelectorAll('.fx-sheet [data-missing]').length})); };
const fields = () => page.evaluate(() => [...document.querySelectorAll('.fx-sheet .fx-q')].map((q) => q.dataset.q));
const form = {offered: await page.locator('[data-draw="new-loop"] .fx-btn').count()};
if (form.offered) {
  await page.click('[data-draw="new-loop"] .fx-btn'); await frames();
  form.fields = await fields(); form.empty = await built(); await fill(); form.new = await built();
  form.overflow = await page.evaluate(() => document.body.scrollWidth - document.body.clientWidth);
  await close();
  await page.locator('#factory-graph .fx-lrow').first().click(); await frames();
  await page.click('.fx-sheet .fx-btn:has-text("Change this loop")'); await frames();
  form.loop = await page.inputValue('.fx-sheet [data-q="loop"] .fx-input');
  form.editFields = await fields(); await fill(); form.edit = await built();
  await close();
}

/* Feeds: each dated line once, no unknown sender; a name opens the loop's drawer with its Orders now and Conversation */
await page.click('#tab-feeds'); await frames();
const talk = await page.evaluate(() => ({rows: document.querySelectorAll('#feeds .fx-post').length, names: document.querySelectorAll('#feeds .fx-name').length,
  unknown: /unknown/.test(document.querySelector('#feeds').textContent)}));
if (talk.names) {
  await page.locator('#feeds .fx-name').first().click(); await frames();
  Object.assign(talk, await page.evaluate(() => ({sheet: document.querySelector('.fx-sheet h2')?.textContent ?? null,
    sections: [...document.querySelectorAll('.fx-sheet .fx-sec')].map((b) => b.textContent), bubbles: document.querySelectorAll('.fx-sheet .fx-bubble').length,
    focus: document.activeElement?.getAttribute('aria-label') ?? null,
    overflow: Math.max(...[...document.querySelectorAll('.fx-sheet *')].map((e) => e.getBoundingClientRect().right)) - innerWidth,
    inView: ((b) => b.top >= 0 && b.top < innerHeight)(document.querySelector('.fx-sheet').getBoundingClientRect()),
    inert: [...document.body.children].filter((e) => !e.contains(document.querySelector('.fx-sheet'))).every((e) => e.inert)})));
  /* the composer writes a prompt for that loop; the page sends nothing */
  await page.fill('.fx-sheet .fx-compose textarea', 'Hold prices until Monday');
  talk.compose = await page.evaluate(() => document.querySelector('.fx-sheet .fx-compose .fx-btn')?.title ?? null);
  await page.keyboard.press('Tab'); await page.keyboard.press('Tab'); await page.keyboard.press('Tab');
  talk.trapped = await page.evaluate(() => !!document.activeElement?.closest('.fx-sheet'));
  const size = page.viewportSize(); await page.setViewportSize({...size, height: 160}); await frames();  /* short, so the drawer scrolls */
  await page.evaluate(() => { document.querySelector('.fx-sheet').scrollTop = 40; dash.draw('sheet'); });
  talk.redraw = await page.evaluate(() => ({focus: !!document.activeElement?.closest('.fx-sheet'), top: document.querySelector('.fx-sheet').scrollTop}));
  await page.setViewportSize(size); await frames();
  if (process.env.SHOTS) await page.screenshot({path: process.env.SHOTS + '/loop-drawer.png'});
  await close();
  talk.closed = await page.evaluate(() => !document.querySelector('.fx-sheet') && ![...document.body.querySelectorAll('[inert]')].length && !!document.activeElement?.closest('#feeds'));
  /* opened from the feed's last name in a short window, the page scrolled: the whole drawer is in view, the page no wider */
  await page.setViewportSize({...size, height: 300}); await page.locator('#feeds .fx-name').last().click(); await frames();
  talk.deep = await page.evaluate(() => ({scrolled: document.body.scrollTop > 0, page: document.body.scrollWidth - document.body.clientWidth,
    fits: ((b) => b.top >= 0 && b.bottom <= innerHeight)(document.querySelector('.fx-sheet').getBoundingClientRect())}));
  await close(); await page.setViewportSize(size); await frames();
}

/* the Factory graph, at desktop width */
await page.setViewportSize(desk);
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
if (factory.loops) {
  await page.locator('#factory-graph .fx-fnode[data-tone]').first().click(); await frames();
  factory.drawer = await page.evaluate(() => !!document.querySelector('.fx-sheet h2'));
  await close();
}

/* the same Factory on a phone: a list by route, each loop once, under who reads it */
await page.setViewportSize(phone); await frames();
const loops = await page.evaluate(() => ({
  sections: document.querySelectorAll('#factory-graph .fx-route').length,
  rows: document.querySelectorAll('#factory-graph .fx-lrow').length,
  graph: document.querySelectorAll('#factory-graph .fx-fnode').length,
  firstCard: document.querySelectorAll('#factory-graph .fx-route:first-child .fx-lrow').length,
  /* a header's count stays inside the header, however long the name */
  countsVisible: [...document.querySelectorAll('#factory-graph .fx-group small')].every((s) => {
    const r = s.getBoundingClientRect(); return r.width > 0 && r.right <= s.closest('.fx-group').getBoundingClientRect().right + 1;
  }),
  /* a name in a header stays before its count, whatever its script */
  countsAfterNames: [...document.querySelectorAll('#factory-graph .fx-group > span:first-child')].every((s) => {
    const small = s.querySelector('small'), count = document.createRange(); count.setStart(small.firstChild, 0); count.setEnd(small.firstChild, 1);
    return count.getBoundingClientRect().left >= s.querySelector('bdi').getBoundingClientRect().right - 1;
  }),
}));
loops.firstCardAll = await page.locator('#factory-graph .fx-route:first-child .fx-all button').click({timeout: 1000})
  .then(() => page.evaluate(() => document.querySelectorAll('#factory-graph .fx-route:first-child .fx-lrow').length), () => null);
const drawer = async (name) => {
  const row = page.locator(`#factory-graph .fx-lrow[data-loop="${name}"]`);
  if (!await row.count()) return null;
  await row.first().click(); await frames();
  const out = {p: await sheetText(), changes: await page.evaluate(() => document.querySelectorAll('.fx-sheet .fx-changes li').length)};
  if (process.env.SHOTS && name === 'shop1') await page.screenshot({path: process.env.SHOTS + '/loop-changes.png'});
  await close(); return out;
};
const shop1 = await drawer('shop1'), lonely = await drawer('lonely');
if (shop1) { loops.changes = shop1.changes; loops.good = shop1.p.find((s) => s.startsWith('Good: ')); loops.read = shop1.p.find((s) => s.startsWith('Read by ')); }
if (lonely) loops.measured = lonely.p.find((s) => s.startsWith('Good: '));

/* Fleet health and the Improver, folded under the graph */
await page.evaluate(() => document.querySelectorAll('.fx-disc details').forEach((d) => { d.open = true; })); await frames();
const evals = await page.evaluate(() => ({rows: Object.fromEntries([...document.querySelectorAll('#evals .fx-eval')].map((li) => [li.firstChild.textContent, li.lastChild.textContent])),
  below: document.querySelectorAll('#evals .fx-row').length}));
if (process.env.SHOTS) await page.locator('#evals').screenshot({path: process.env.SHOTS + '/evaluations.png'});
const improver = {scope, hidden: await page.locator('#improver').isHidden(), rows: await page.locator('#improver .fx-row').count(), rate: await page.textContent('[data-draw="improver-rate"]')};
if (improver.rows) {
  await page.locator('#improver .fx-row').first().click(); await frames();
  improver.detail = await page.evaluate(() => /Why: .*Read on: /s.test(document.querySelector('#improver .fx-more:not([hidden])')?.textContent || ''));
  if (process.env.SHOTS) await page.locator('#improver').screenshot({path: process.env.SHOTS + '/improver.png'});
}
ms.overflow = await page.evaluate(() => document.body.scrollWidth - document.body.clientWidth);
await browser.close();
console.log(JSON.stringify({ms, errors, attention, back, factory, loops, improver, form, talk, evals, waiting}));
