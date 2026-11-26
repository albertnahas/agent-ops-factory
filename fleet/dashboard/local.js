/* Local stand-in for the claude.ai dashboard runtime, so dashboard/index.html runs unchanged as a plain file.
   It provides the part of `dash` the page uses (data, calc, onData, draw, params, setLink, colors) and the design tokens,
   built from fleet/dashboard/look.json; filters start at fleet/dashboard/params.json. fleet/fleet.py inlines this, the data (window.FLEET) and the page into dashboard.html. */
(() => {
  const {look} = window.FLEET;
  let params = {...window.FLEET.params};
  const tokens = (t) => `--color-bg:${t.ground};--color-fg:${t.text};--color-fg-muted:${t.muted};--color-border-line:${t.border};
    --color-panel:${t.card};--color-ok:${t.good};--color-warn:${t.warning};--color-bad:${t.bad};
    --cds-chart-grid:color-mix(in srgb, ${t.text} 12%, ${t.card});`;
  const css = document.createElement('style');
  css.textContent = `
    :root { ${tokens(look.light)} --cds-radius:${look.corners}; --cds-gap-sm:8px; --cds-gap-md:16px; --cds-font-weight-medium:500;
      --cds-font-size-caption:${look.sizes.caption}; --cds-font-size-body:${look.sizes.body}; --cds-font-size-heading:${look.sizes.heading};
      --cds-font-size-title:${look.sizes.title}; --font-anthropic-sans:${look.fonts.text}; --font-anthropic-serif:${look.fonts.display}; color-scheme: light dark; }
    @media (prefers-color-scheme: dark) { :root { ${tokens(look.dark)} } }
    /* as on claude.ai: --color-bg is the page's ground and --color-panel its cards; the page scrolls inside an element, not the document */
    html { height: 100%; overflow: hidden; } body { height: 100%; overflow-y: auto; margin: 0; background: var(--color-bg); }
    #dash-root { max-width: 1200px; margin: 0 auto; padding: 24px 16px 48px; }
    .dash-select { font: inherit; font-size: var(--cds-font-size-caption); color: var(--color-fg); background: var(--color-panel);
      border: 1px solid var(--color-border-line); border-radius: 6px; padding: 5px 8px; }`;
  document.head.append(css);

  const datasets = {}, calcs = {}, draws = {}, widths = new WeakMap();
  /* as on claude.ai, a drawing runs again when its element's width changes, opening a hidden tab included */
  const resized = new ResizeObserver((entries) => requestAnimationFrame(() => entries.forEach(({target: e}) => {
    if (!e.closest('[hidden]') && widths.get(e) !== e.clientWidth) { widths.set(e, e.clientWidth); run(e.dataset.draw, e); }
  })));
  for (const id of ['loops', 'waiting', 'changes', 'questions', 'talk']) {
    const d = window.FLEET[id];
    /* as on claude.ai, a cell is a string, number, boolean or null */
    d.rows.forEach((r) => Object.entries(r).forEach(([k, v]) => { if (v !== null && typeof v === 'object') throw new TypeError(`${id}.${k} is not a scalar: ${JSON.stringify(v)}`); }));
    datasets[id] = {status: 'ok', data: d.rows, meta: d.meta, columns: Object.keys(d.rows[0] || {})};
  }
  /* as on claude.ai, the first drawings run before the data has come: every dataset says loading, then the data lands */
  let loaded = false;
  setTimeout(() => { loaded = true; rerun(); }, 50);
  /* as claude.ai's check, a drawing writes only inside its own element, past the attributes any script may set */
  const free = /^(class|style|hidden|open|disabled|checked|selected|value|tabindex|aria-.*)$/;
  const run = (name, e) => {
    const seen = new MutationObserver(() => {});
    seen.observe(document.documentElement, {subtree: true, childList: true, attributes: true, characterData: true});
    try { draws[name](e); } finally {
      for (const r of seen.takeRecords()) if (!e.contains(r.target) && !free.test(r.attributeName || '')) console.error(`drawing "${name}" wrote outside itself: ${r.type} ${r.attributeName || ''} on ${r.target.id || r.target.nodeName}`);
      seen.disconnect();
    }
  };
  const watchers = [];
  const rerun = () => { Object.values(calcs).forEach((c) => delete c.value); watchers.forEach((f) => f()); Object.keys(draws).forEach((n) => window.dash.draw(n)); };
  const dark = matchMedia('(prefers-color-scheme: dark)');
  window.dash = {
    get colors() { return (dark.matches ? look.dark : look.light).charts; },
    data(id) {
      if (!loaded) return {status: 'loading', data: null};
      if (datasets[id]) return datasets[id];
      const c = calcs[id];
      if (!c) return {status: 'missing', data: null};
      if (!('value' in c)) c.value = c.fn(...c.inputs.map((i) => this.data(i).data));
      return {status: 'ok', data: c.value};
    },
    calc(id, spec) { calcs[id] = {...spec}; },
    onData(fn) { watchers.push(fn); fn(); },
    draw(name, fn) {
      if (fn) draws[name] = fn;
      /* as on claude.ai, an element under a hidden attribute (its own, or a hidden tab's) is drawn once that's lifted */
      document.querySelectorAll(`[data-draw="${name}"]`).forEach((e) => {
        if (!draws[name]) return;
        resized.observe(e); if (e.closest('[hidden]')) return;
        run(name, e); widths.set(e, e.clientWidth);
      });
    },
    params() { return {...params}; },
    setParams(v) { params = {...params, ...v}; rerun(); },
    resetParams() { params = {...window.FLEET.params}; rerun(); },
    setLink(name) { history.replaceState(null, '', name ? '#' + name : location.pathname); },
  };
  dark.addEventListener('change', () => location.reload());
})();
