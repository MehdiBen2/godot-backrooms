(function () {
  const vscode = acquireVsCodeApi();
  const app = document.getElementById('app');
  const NS = 'http://www.w3.org/2000/svg';
  let state = null;
  let refreshing = false;

  // ---------- small DOM helpers ----------
  const el = (tag, cls, text) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  };
  const svgEl = (tag, attrs) => {
    const e = document.createElementNS(NS, tag);
    for (const k in attrs) e.setAttribute(k, attrs[k]);
    return e;
  };
  const mkSvg = (size, vb) => svgEl('svg', { width: size, height: size, viewBox: vb || '0 0 24 24', fill: 'none', stroke: 'currentColor', 'stroke-width': 1.8, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' });
  const path = (svg, d) => { svg.append(svgEl('path', { d })); return svg; };

  // ---------- icons ----------
  // Claude-style starburst: 12 rounded rays of varying length.
  const RAYS = [[0, 10], [30, 7.5], [58, 9.5], [90, 7], [120, 10], [148, 7.5], [180, 9.5], [210, 7], [238, 10], [270, 7.5], [300, 9.5], [330, 7]];
  function spark(size) {
    const s = mkSvg(size);
    s.setAttribute('stroke-width', 2.4);
    RAYS.forEach(([deg, len]) => {
      const a = (deg * Math.PI) / 180;
      s.append(svgEl('line', { x1: 12 + 2 * Math.cos(a), y1: 12 + 2 * Math.sin(a), x2: 12 + len * Math.cos(a), y2: 12 + len * Math.sin(a) }));
    });
    return s;
  }
  const icons = {
    refresh: () => path(mkSvg(15), 'M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7'),
    trash: () => path(mkSvg(15), 'M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6'),
    userPlus: () => path(mkSvg(17), 'M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM2 21c0-4 3.1-6.5 7-6.5s7 2.5 7 6.5M19 8v6M16 11h6'),
    swap: () => path(mkSvg(15), 'M17 3l4 4-4 4M21 7H8M7 21l-4-4 4-4M3 17h13'),
    save: () => path(mkSvg(15), 'M5 13l4 4L19 7'),
  };
  const withIcon = (icon, label) => { const f = document.createDocumentFragment(); f.append(icon, el('span', '', label)); return f; };

  // ---------- formatting ----------
  function fmtReset(iso) {
    if (!iso) return 'No active window';
    const ms = new Date(iso).getTime() - Date.now();
    if (ms <= 0) return 'Just reset';
    const m = Math.floor(ms / 60000);
    const d = Math.floor(m / 1440), h = Math.floor((m % 1440) / 60), mm = m % 60;
    if (d > 0) return 'Resets in ' + d + 'd ' + h + 'h';
    if (h > 0) return 'Resets in ' + h + 'h ' + mm + 'm';
    return 'Resets in ' + mm + 'm';
  }
  function ago(ts) {
    const mins = Math.round((Date.now() - ts) / 60000);
    return mins < 1 ? 'just now' : mins < 90 ? mins + 'm ago' : Math.round(mins / 60) + 'h ago';
  }
  function planLabel(p) {
    const plan = p.plan ? p.plan.charAt(0).toUpperCase() + p.plan.slice(1) : '';
    const m = /(\d+)x/.exec(p.tier || '');
    return plan + (m ? ' ' + m[1] + 'x' : '');
  }
  function avatarColor(name) {
    let h = 0;
    for (const c of name) h = (h * 31 + c.charCodeAt(0)) % 360;
    return 'hsl(' + h + ', 45%, 42%)';
  }
  const initials = (name) => name.trim().split(/[\s._-]+/).slice(0, 2).map((w) => w[0] || '').join('') || '?';

  // ---------- components ----------
  function meter(label, win) {
    const expired = win && win.resetsAt && new Date(win.resetsAt).getTime() <= Date.now();
    const used = !win || expired ? 0 : Math.max(0, Math.min(100, win.pct));
    const left = Math.round(100 - used);
    const wrap = el('div', 'meter');
    const head = el('div', 'meter-head');
    const val = el('span', 'meter-val', win ? left + '%' : '–');
    if (win) val.append(el('small', '', 'left'));
    head.append(el('span', 'meter-label', label), val);
    const track = el('div', 'track');
    const fill = el('div', 'fill ' + (used >= 90 ? 'bad' : used >= 70 ? 'warn' : 'ok'));
    fill.style.width = (win ? used : 0) + '%';
    track.append(fill);
    wrap.append(head, track, el('div', 'meter-sub', win ? fmtReset(win.resetsAt) : 'No data yet'));
    return wrap;
  }

  function card(p) {
    const c = el('div', 'card' + (p.active ? ' active' : ''));
    const top = el('div', 'card-top');
    const av = el('div', 'avatar', initials(p.name));
    av.style.background = avatarColor(p.name);
    const who = el('div', 'who');
    who.append(el('div', 'name', p.name), el('div', 'email', p.email || ''));
    const del = el('button', 'icon-btn danger');
    del.title = 'Delete saved profile';
    del.append(icons.trash());
    del.addEventListener('click', () => vscode.postMessage({ type: 'delete', name: p.name }));
    top.append(av, who, del);
    c.append(top);

    const pills = el('div', 'pills');
    if (p.active) pills.append(el('span', 'pill live', 'Active'));
    if (planLabel(p)) pills.append(el('span', 'pill', planLabel(p)));
    if (p.org && p.org !== p.email) pills.append(el('span', 'pill', p.org));
    if (p.tokenExpired) pills.append(el('span', 'pill warn', 'Login refreshes on switch'));
    c.append(pills);

    const meters = el('div', 'meters');
    meters.append(meter('Session · 5 hours', p.usage && p.usage.fiveHour), meter('Weekly · 7 days', p.usage && p.usage.sevenDay));
    c.append(meters);
    if (!p.active && p.usage && p.usage.fetchedAt) c.append(el('div', 'hint', 'Last seen ' + ago(p.usage.fetchedAt)));

    if (!p.active) {
      const actions = el('div', 'actions');
      const b = el('button', 'btn');
      b.append(withIcon(icons.swap(), 'Switch to ' + p.name));
      b.addEventListener('click', () => vscode.postMessage({ type: 'switch', name: p.name }));
      actions.append(b);
      c.append(actions);
    }
    return c;
  }

  function saveCard(cur) {
    const c = el('div', 'card notice');
    const t = el('div', 'notice-title');
    t.append(spark(18), el('span', '', 'New login detected'));
    t.firstChild.style.color = 'var(--accent)';
    c.append(t, el('div', 'hint', (cur.email || 'This account') + ' is not saved yet. Name it to switch back later.'));
    const input = el('input');
    input.placeholder = 'Profile name';
    input.value = (cur.email || '').split('@')[0];
    const go = () => { if (input.value.trim()) vscode.postMessage({ type: 'save', name: input.value.trim() }); };
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); });
    const b = el('button', 'btn fit');
    b.append(withIcon(icons.save(), 'Save'));
    b.addEventListener('click', go);
    const row = el('div', 'actions');
    row.append(input, b);
    c.append(row);
    return c;
  }

  function header() {
    const h = el('div', 'header');
    const logo = el('div', 'logo');
    logo.append(spark(26));
    const title = el('div', 'title');
    const n = state ? state.profiles.length : 0;
    title.append(el('b', '', 'Claude Accounts'), el('span', '', n + (n === 1 ? ' saved account' : ' saved accounts')));
    const r = el('button', 'icon-btn' + (refreshing ? ' spin' : ''));
    r.title = 'Refresh usage';
    r.append(icons.refresh());
    r.addEventListener('click', () => { refreshing = true; render(true); vscode.postMessage({ type: 'refresh' }); });
    h.append(logo, title, r);
    return h;
  }

  function render(force) {
    if (!state) return;
    // Don't wipe text the user is typing (unless forced by a user action).
    if (!force && app.querySelector('input:focus')) return;
    app.textContent = '';
    app.append(header());

    if (state.current && !state.current.saved) app.append(saveCard(state.current));

    const sorted = state.profiles.slice().sort((a, b) => (b.active - a.active) || a.name.localeCompare(b.name));
    sorted.forEach((p) => app.append(card(p)));

    if (!sorted.length && !state.current) {
      const e = el('div', 'empty');
      const logo = el('div', 'logo');
      logo.append(spark(40));
      e.append(logo, el('div', '', 'Not signed in. Log in to Claude Code, then save the account here.'));
      app.append(e);
    }

    const add = el('button', 'add');
    add.append(withIcon(icons.userPlus(), 'Add account'));
    add.title = 'Sign out and log in with another account';
    add.addEventListener('click', () => vscode.postMessage({ type: 'add' }));
    app.append(add, el('div', 'footer', 'Updated ' + new Date(state.now).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })));
  }

  window.addEventListener('message', (e) => {
    if (e.data.type === 'state') {
      state = e.data.state;
      const forced = refreshing;
      refreshing = false;
      render(forced);
    }
  });
  setInterval(() => render(false), 30000); // keep countdowns fresh
  vscode.postMessage({ type: 'ready' });
})();
