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
/* the pointer moves off first: Escape hides a tip the pointer rests on before it closes the drawer */
const close = async () => { await page.mouse.move(0, 0); await page.keyboard.press('Escape'); await frames(); };
const sheetText = () => page.evaluate(() => [...document.querySelectorAll('.fx-sheet p')].map((p) => p.textContent));
/* every loop's drawer and its row expansion draw without throwing, whatever the builder left empty */
const every = async () => page.evaluate(() => { const bad = [], rows = dash.data('loops').data;
  for (const r of rows) { try { FX.stack = [{kind: 'loop', id: r.loop}]; dash.draw('sheet'); loopMore(r)(document.createElement('div')); } catch (e) { bad.push(r.loop + ': ' + e); } }
  FX.stack = []; dash.draw('sheet'); return [bad, rows.length]; });
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
    const sel = q.querySelector('select'); if (sel) { sel.value = sel.options[sel.options.length - 1].value; sel.dispatchEvent(new Event('change')); set(q.querySelector('input.fx-input'), 'v-' + q.dataset.q); continue; }
    const i = q.querySelector('.fx-input'); if (!i || i.readOnly || i.type === 'number') continue;
    set(i, i.placeholder === 'One per line' ? 'x\ny' : i.tagName === 'TEXTAREA' ? 'a\nb' : 'v-' + q.dataset.q);
  }
});
const built = async () => { await page.click('.fx-sheet .fx-form-body > .fx-btn'); await frames();
  return page.evaluate(() => ({prompt: document.querySelector('.fx-sheet .fx-built .fx-prompt')?.textContent ?? null, copy: !!document.querySelector('.fx-sheet .fx-built .fx-btn'),
    founder: document.querySelectorAll('.fx-sheet .fx-founder').length, missing: document.querySelectorAll('.fx-sheet [data-missing]').length})); };
const fields = () => page.evaluate(() => [...document.querySelectorAll('.fx-sheet .fx-q')].map((q) => q.dataset.q));
const form = {offered: await page.locator('[data-draw="new-loop"] .fx-btn').count()};
if (form.offered) {
  await page.click('[data-draw="new-loop"] .fx-btn'); await frames();
  form.skill = await page.evaluate(() => document.querySelector('.fx-sheet .fx-prompt')?.textContent ?? null);
  form.projects = await page.evaluate(() => [...document.querySelectorAll('.fx-sheet [data-q="project"] option')].map((o) => o.textContent));
  form.fields = await fields(); form.empty = await built(); await fill(); form.new = await built();
  form.overflow = await page.evaluate(() => document.body.scrollWidth - document.body.clientWidth);
  await close();
  await page.locator('#factory-graph .fx-lrow').first().click(); await frames();
  await page.click('.fx-sheet .fx-btn:has-text("Change this loop")'); await frames();
  form.loop = await page.inputValue('.fx-sheet [data-q="loop"] .fx-input');
  form.editFields = await fields(); await fill(); form.edit = await built();
  await close();
}

const [everyBad, everyCount] = await every();

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
  /* a relation icon's tip, focused from the keyboard: Escape hides the tip and keeps the drawer, a second Escape closes it */
  await page.locator('#feeds .fx-name').first().click(); await frames();
  if (await page.locator('.fx-sheet .fx-ri').count()) {
    await page.locator('.fx-sheet .fx-ri').first().focus(); await page.keyboard.press('Tab'); await page.keyboard.press('Shift+Tab');
    const tip = () => page.evaluate(() => [...document.querySelectorAll('.fx-sheet .fx-ri-tip')].some((t) => getComputedStyle(t).visibility === 'visible'));
    talk.tip = {shown: await tip()}; await page.keyboard.press('Escape'); await frames();
    Object.assign(talk.tip, {hidden: !await tip(), open: !!await page.locator('.fx-sheet').count()});
    /* a tip shown by the pointer resting on its icon: Escape hides it too, and the drawer stays */
    await page.locator('.fx-sheet .fx-ri').first().hover(); await frames(); talk.tip.hover = await tip();
    await page.keyboard.press('Escape'); await frames();
    Object.assign(talk.tip, {hoverHidden: !await tip(), hoverOpen: !!await page.locator('.fx-sheet').count()});
  }
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

/* the graph is a canvas inside its card: scrolling over it moves the graph, not the page; Ctrl-scroll zooms at the pointer;
   lines stay on their chips at any zoom, a redraw included; a drag doesn't click; Fit shows it all; Expand fills the view
   and a loop's drawer opens over it; Escape closes the drawer, then the expanded view */
const canvas = {};
if (await page.locator('#factory-canvas.on').count()) {
  const cv = await page.locator('#factory-canvas').boundingBox(), view = () => page.evaluate(() => ({
    t: document.querySelector('.fx-stage').style.transform, page: document.body.scrollTop, pct: document.querySelector('.fx-cv-pct').textContent,
    sheet: !!document.querySelector('.fx-sheet')}));
  const before = await view();
  await page.mouse.move(cv.x + cv.width / 2, cv.y + cv.height / 2); await page.mouse.wheel(0, 200); await frames();
  const wheeled = await view(); canvas.wheel = wheeled.t !== before.t && wheeled.page === before.page;
  await page.keyboard.down('Control'); await page.mouse.wheel(0, -40); await page.keyboard.up('Control'); await frames();
  canvas.zoom = (await view()).pct;
  await page.evaluate(() => dash.draw('factory')); await frames();
  canvas.onChips = await page.evaluate(() => {
    const chips = [...document.querySelectorAll('#factory-graph .fx-fnode')].map((c) => c.getBoundingClientRect());
    const starts = [...document.querySelectorAll('#factory-graph .fx-fedges path[data-e]')].map((p) => {
      const m = p.getScreenCTM(), q = p.getPointAtLength(0); return {x: m.a * q.x + m.c * q.y + m.e, y: m.b * q.x + m.d * q.y + m.f};
    });
    return starts.length > 0 && starts.every((s) => chips.some((r) => s.x >= r.left - 2 && s.x <= r.right + 2 && s.y >= r.top - 2 && s.y <= r.bottom + 2));
  });
  const chip = await page.locator('#factory-graph .fx-fnode[data-tone]').first().boundingBox();
  await page.mouse.move(chip.x + 10, chip.y + chip.height / 2); await page.mouse.down();
  await page.mouse.move(chip.x + 70, chip.y + 60, {steps: 5}); await page.mouse.up(); await frames();
  const dragged = await view();
  canvas.drag = !dragged.sheet && dragged.t !== before.t;
  /* another tab and back keeps the view; a double click on a loop opens its drawer once */
  const kept = (await view()).t;
  await page.click('#tab-feeds'); await frames(); await page.click('#tab-factory'); await frames();
  canvas.tabKeeps = (await view()).t === kept;
  await page.click('[data-cv="fit"]'); await frames();
  await page.locator('#factory-graph .fx-fnode[data-tone]').first().dblclick(); await frames();
  canvas.once = await page.evaluate(() => !!document.querySelector('.fx-sheet') && !document.querySelector('.fx-sheet .fx-back'));
  await close();
  const fits = () => page.evaluate(() => { const s = document.querySelector('.fx-stage').getBoundingClientRect(), c = document.querySelector('#factory-canvas').getBoundingClientRect();
    return s.left >= c.left - 1 && s.right <= c.right + 1 && s.top >= c.top - 1 && s.bottom <= c.bottom + 1; });
  canvas.fit = await fits();
  await page.mouse.move(cv.x + cv.width / 2, cv.y + cv.height / 2); await page.mouse.wheel(0, 120); await frames();
  const was = (await view()).t;
  await page.click('[data-cv="big"]'); await frames(); await frames();
  canvas.bigFits = await fits();
  const big = await page.locator('#factory-canvas').boundingBox(), size = page.viewportSize();
  canvas.big = big.width >= size.width - 60 && big.height >= size.height - 60;
  /* expanded is modal: what's behind it is inert */
  canvas.bigModal = await page.evaluate(() => document.querySelector('#tabs').closest('[inert]') !== null && !document.querySelector('#factory-canvas').closest('[inert]'));
  await page.locator('#factory-graph .fx-fnode[data-tone]').first().click(); await frames();
  canvas.drawerOver = await page.evaluate(() => { const r = document.querySelector('.fx-sheet')?.getBoundingClientRect();
    return !!r && !!document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)?.closest('.fx-sheet'); });
  await close(); await close();
  canvas.back = (await page.locator('#factory-canvas').boundingBox()).width < size.width - 60 && (await view()).t === was;
}

/* the same Factory on a phone: a list by route, each loop once, under who reads it */
await page.setViewportSize(phone); await frames();
const loops = await page.evaluate(() => ({
  sections: document.querySelectorAll('#factory-graph .fx-route').length,
  rows: document.querySelectorAll('#factory-graph .fx-lrow').length,
  graph: document.querySelectorAll('#factory-graph .fx-fnode').length, canvas: !!document.querySelector('#factory-canvas.on'),
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
if (shop1) { loops.changes = shop1.changes; loops.good = shop1.p.find((s) => s.startsWith('Good: ')); loops.read = shop1.p.find((s) => s.includes('may change it')); }
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
console.log(JSON.stringify({every: everyBad, everyCount, ms, errors, attention, back, factory, canvas, loops, improver, form, talk, evals, waiting}));
