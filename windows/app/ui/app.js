// SpaceSaver for Windows UI. Plain JS, no build step.
// Talks to the Rust core through Tauri commands; in a normal browser (no window.__TAURI__)
// it runs on DemoBackend's built-in demo data.
'use strict';

(() => {
  const TAURI = window.__TAURI__;
  const api = TAURI && TAURI.core ? {
    demo: false,
    disk: () => TAURI.core.invoke('disk_status'),
    lastScan: () => TAURI.core.invoke('last_scan'),
    scan: () => TAURI.core.invoke('scan'),
    clean: (ids, scanId) => TAURI.core.invoke('clean', { ids, scanId }),
    activity: () => TAURI.core.invoke('activity'),
    restore: (id) => TAURI.core.invoke('restore', { id }),
    reveal: (path) => TAURI.core.invoke('reveal', { path }),
    onCleanProgress: (cb) => TAURI.event.listen('clean-progress', (e) => cb(e.payload)),
  } : DemoBackend;

  const CATS = [
    { id: 'projectArtifacts', title: 'Project Artifacts', icon: 'package', c: '#5c8cfa', c2: '#7aa2ff', group: 'Developer',
      blurb: "node_modules, build outputs and virtualenvs in projects you haven't touched lately." },
    { id: 'packageCaches', title: 'Package Caches', icon: 'archive', c: '#8c6bf2', c2: '#b28cff', group: 'Developer',
      blurb: 'Download caches for npm, pnpm, Yarn, pip, uv, NuGet, Cargo, Gradle, Go and others.' },
    { id: 'ideCaches', title: 'IDEs & Editors', icon: 'code', c: '#6b66d9', c2: '#9591f0', group: 'Developer',
      blurb: 'Caches and logs for VS Code, Cursor, Windsurf, JetBrains IDEs and Android Studio.' },
    { id: 'aiModels', title: 'AI Models', icon: 'cpu', c: '#d961bf', c2: '#f08ad9', group: 'Developer',
      blurb: 'Hugging Face, Ollama, LM Studio and other local model weights.' },
    { id: 'wslDocker', title: 'WSL & Docker', icon: 'container', c: '#2194cc', c2: '#55b8e8', group: 'Developer',
      blurb: 'WSL and Docker Desktop virtual disks. They never shrink by themselves; here is how to compact them.' },
    { id: 'systemJunk', title: 'System Junk', icon: 'sparkles', c: '#fa9e33', c2: '#ffc266', group: 'Cleanup',
      blurb: 'Crash dumps and temporary files nothing has touched for a week.' },
  ];
  const CAT = Object.fromEntries(CATS.map((c) => [c.id, c]));
  const RISK = { safe: 'Safe', review: 'Review', caution: 'Caution' };

  const state = {
    view: 'overview',
    scan: null,
    disk: null,
    activity: [],
    selected: new Set(),
    scanning: false,
    busy: false,
    pending: [],
    pendingScanId: null,
    // Id of the scan made in this session. Only that scan can be cleaned from; a scan saved by
    // an earlier session or the CLI is shown read-only.
    liveScanId: null,
    lastView: null,
  };

  // ---------- helpers ----------
  const $ = (sel) => document.querySelector(sel);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const sum = (list) => list.reduce((a, i) => a + (i.size || i.bytes || 0), 0);
  const plural = (n, one, many) => n + ' ' + (n === 1 ? one : (many || one + 's'));
  const errText = (e) => (e && e.message) ? e.message : String(e);

  function fmt(bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    if (!bytes || bytes < 1024) return (bytes || 0) + ' B';
    let v = bytes, u = 0;
    while (v >= 1024 && u < units.length - 1) { v /= 1024; u++; }
    return (v >= 100 ? v.toFixed(0) : v >= 10 ? v.toFixed(1) : v.toFixed(2)) + ' ' + units[u];
  }

  function ago(ts) {
    const s = Math.max(0, Math.floor(Date.now() / 1000) - ts);
    if (s < 60) return 'just now';
    if (s < 3600) return plural(Math.floor(s / 60), 'minute') + ' ago';
    if (s < 86400) return plural(Math.floor(s / 3600), 'hour') + ' ago';
    return plural(Math.floor(s / 86400), 'day') + ' ago';
  }

  function greeting() {
    const h = new Date().getHours();
    return h < 5 ? 'Good evening' : h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening';
  }

  const items = () => (state.scan ? state.scan.items : []);
  const selectable = (i) => !i.blockedReason && i.method && i.method.kind === 'recycleBin';
  const recommended = () => items().filter((i) => i.recommended && selectable(i));
  const selectedItems = () => items().filter((i) => state.selected.has(i.id) && selectable(i));
  const inCat = (id) => items().filter((i) => i.category === id);

  function setScan(scan, resetSelection) {
    const first = !state.scan;
    state.scan = scan;
    if (scan && scan.disk) state.disk = scan.disk;
    if (!scan) return;
    if (resetSelection || first) {
      state.selected = new Set(scan.items.filter((i) => i.recommended && selectable(i)).map((i) => i.id));
    } else {
      const ids = new Set(scan.items.map((i) => i.id));
      state.selected = new Set([...state.selected].filter((id) => ids.has(id)));
    }
  }

  let toastTimer = null;
  function toast(text) {
    const t = $('#toast');
    t.textContent = text;
    t.hidden = false;
    t.style.animation = 'none';
    void t.offsetWidth;
    t.style.animation = '';
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.hidden = true; }, 3200);
  }

  // ---------- sidebar and toolbar ----------
  function renderNav() {
    const navItem = (view, title, ic, color, extra) =>
      '<button class="side-item' + (state.view === view ? ' active' : '') + '" data-act="nav" data-view="' + view + '">' +
      '<span class="tile" style="--c:' + color + '">' + icon(ic) + '</span>' + esc(title) + (extra || '') + '</button>';
    let html = navItem('overview', 'Overview', 'gauge', '#4f82ff');
    let group = null;
    for (const c of CATS) {
      if (c.group !== group) { group = c.group; html += '<div class="side-head">' + group + '</div>'; }
      const size = sum(inCat(c.id));
      html += navItem(c.id, c.title, c.icon, c.c, state.scan && size ? '<em>' + fmt(size) + '</em>' : '');
    }
    html += '<div class="side-head">History</div>' + navItem('activity', 'Activity', 'history', '#8c8c99');
    $('#nav').innerHTML = html;
  }

  function renderSideDisk() {
    const d = state.disk;
    const el = $('#side-disk');
    if (!d || !d.total) { el.hidden = true; return; }
    el.hidden = false;
    const used = Math.round(((d.total - d.free) / d.total) * 100);
    el.innerHTML = '<svg viewBox="0 0 36 36" class="mini-gauge"><circle cx="18" cy="18" r="14" class="trk"/>' +
      '<circle cx="18" cy="18" r="14" class="val" pathLength="100" stroke-dasharray="' + used + ' 100"/></svg>' +
      '<div><b>' + fmt(d.free) + ' free</b><span>of ' + fmt(d.total) + ' on ' + esc(d.drive.replace(/\\$/, '')) + '</span></div>';
  }

  function renderToolbar() {
    const chip = $('#scan-chip');
    const btn = $('#rescan');
    if (state.scanning) {
      chip.innerHTML = icon('refresh', 'spin') + 'Scanning…';
    } else if (state.scan) {
      chip.innerHTML = icon('checkCircle') + 'Scanned ' + ago(state.scan.date);
    } else {
      chip.innerHTML = 'Not scanned yet';
    }
    btn.innerHTML = icon('refresh', state.scanning ? 'spin' : '');
    btn.disabled = state.scanning;
  }

  // ---------- overview ----------
  function ringSvg(segs) {
    return '<svg viewBox="0 0 200 200" class="ring" aria-hidden="true"><defs>' +
      '<linearGradient id="gBrand" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#4f82ff"/><stop offset="1" stop-color="#8f5efa"/></linearGradient>' +
      '<linearGradient id="gOk" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#21cc8f"/><stop offset="1" stop-color="#12a1c7"/></linearGradient>' +
      '<linearGradient id="gWarn" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f7b23b"/><stop offset="1" stop-color="#f58533"/></linearGradient>' +
      '</defs><circle class="ring-track" cx="100" cy="100" r="82"/>' +
      segs.map((s) => '<circle class="ring-seg" data-len="' + s.len + '" data-start="' + s.start + '" stroke="url(#' + s.grad + ')" cx="100" cy="100" r="82" pathLength="1000" stroke-dasharray="0 1000"/>').join('') +
      '</svg>';
  }

  function legendRow(color, label, value, total, c1, c2) {
    const w = total ? Math.max(0.5, (value / total) * 100) : 0;
    return '<div class="lg-row"><span class="dot" style="--c:' + color + '"></span><span>' + label + '</span>' +
      '<span class="bar"><span style="--w:' + w.toFixed(1) + '%;--c1:' + c1 + ';--c2:' + c2 + '"></span></span><b>' + fmt(value) + '</b></div>';
  }

  function viewOverview() {
    if (!state.scan) return state.scanning ? viewScanning() : viewEmpty();
    const disk = state.disk;
    const rec = recommended();
    const recSize = sum(rec);
    const reviewSize = sum(items().filter((i) => !(i.recommended && selectable(i))));
    let html = '<h2 class="greet">' + greeting() + '</h2>' +
      '<p class="greet-sub">' + (recSize ? fmt(recSize) + ' can go safely.' : 'Nothing needs cleaning right now.') +
      ' Last checked ' + ago(state.scan.date) + '.</p>';

    if (disk && disk.total) {
      const used = disk.total - disk.free;
      const safe = Math.min(recSize, used);
      const review = Math.min(reviewSize, used - safe);
      const other = Math.max(0, used - safe - review);
      const k = 1000 / disk.total;
      const segs = [];
      let start = 0;
      for (const [v, grad] of [[other, 'gBrand'], [review, 'gWarn'], [safe, 'gOk']]) {
        const len = Math.round(v * k);
        segs.push({ len, start, grad });
        start += len;
      }
      const pct = Math.round((used / disk.total) * 100);
      const low = disk.free / disk.total < 0.1;
      html += '<div class="w-card hero-card"><div class="ring-box">' + ringSvg(segs) +
        '<div class="ring-center"><b class="' + (low ? 'danger-text' : '') + '">' + fmt(disk.free) + '</b><span>free of ' + fmt(disk.total) + '</span>' +
        '<em class="' + (low ? 'low' : '') + '">' + pct + '% used</em></div></div>' +
        '<div class="legend"><div class="lg-head">' + icon('drive') + '<b>Local Disk (' + esc(disk.drive.replace(/\\$/, '')) + ')</b><span class="chip">NTFS</span></div>' +
        legendRow('#5f74ff', 'Used by files', other, disk.total, '#4f82ff', '#8f5efa') +
        legendRow('#f59e0b', 'Found, needs review', review, disk.total, '#f7b23b', '#f58533') +
        legendRow('#21cc8f', 'Safe to clean', safe, disk.total, '#21cc8f', '#12a1c7') +
        legendRow('#9aa0b2', 'Free', disk.free, disk.total, '#9aa0b2', '#9aa0b2') +
        '<div class="lg-note">' + icon('info') + '<span>Cleaning moves items to the Recycle Bin. The space comes back when you empty it.</span></div>' +
        '</div></div>';
    }

    // Smart Clean
    const byCat = CATS.map((c) => ({ c, size: sum(rec.filter((i) => i.category === c.id)) }))
      .filter((x) => x.size > 0).sort((a, b) => b.size - a.size).slice(0, 5);
    const max = byCat.length ? byCat[0].size : 1;
    html += '<div class="w-row"><div class="w-card smart"><div class="smart-l">' +
      '<span class="w-label ok">' + icon('wand') + 'Smart Clean</span>' +
      '<b class="smart-num">' + fmt(recSize) + '</b>' +
      '<p>' + (rec.length ? plural(rec.length, 'regenerable item') + ': caches and build folders of projects you haven\'t touched in 45 days. Safe items only.' : 'No Safe items to clean. Review the categories below for more.') + '</p>' +
      '<button class="w-btn ok" data-act="smart-clean"' + (rec.length ? '' : ' disabled') + '>' + icon('sparkles') + 'Clean ' + fmt(recSize) + '</button></div>' +
      '<div class="smart-r">' + (byCat.length ? byCat.map((x) =>
        '<div class="sm-row">' + icon(x.c.icon) + '<span>' + esc(x.c.title) + '</span><span class="bar"><span style="--w:' + ((x.size / max) * 100).toFixed(0) + '%;--c1:' + x.c.c + ';--c2:' + x.c.c2 + '"></span></span><b>' + fmt(x.size) + '</b></div>'
      ).join('') : '<p class="muted">Everything recommended is already clean.</p>') + '</div></div>';

    const wsl = inCat('wslDocker');
    if (wsl.length) {
      html += '<div class="w-card side-card"><span class="w-label info">' + icon('container') + 'WSL & Docker disks</span>' +
        '<b class="big-num">' + fmt(sum(wsl)) + '</b>' +
        '<p>' + plural(wsl.length, 'virtual disk') + '. Never deleted: they don\'t shrink by themselves, so SpaceSaver shows the steps to compact them.</p>' +
        '<button class="w-btn brand sm" data-act="nav" data-view="wslDocker">Show the steps</button></div>';
    } else {
      html += '<div class="w-card side-card"><span class="w-label info">' + icon('shield') + 'Undo built in</span>' +
        '<p>Everything goes to the Recycle Bin and every cleanup is logged, so you can restore it from Activity. Active projects, system folders and anything inside .git are never touched.</p>' +
        '<button class="w-btn brand sm" data-act="nav" data-view="activity">View activity</button></div>';
    }
    html += '</div>';

    // Category list
    html += '<div class="w-card cat-list">' + CATS.map((c) => {
      const list = inCat(c.id);
      const size = sum(list);
      const recC = sum(list.filter((i) => i.recommended && selectable(i)));
      return '<button class="cat-row" data-act="nav" data-view="' + c.id + '"><span class="tile" style="--c:' + c.c + '">' + icon(c.icon) + '</span>' +
        '<span><b>' + esc(c.title) + '</b><small>' + (list.length ? plural(list.length, 'item') + ' · ' : 'Nothing found · ') + esc(c.blurb) + '</small></span>' +
        '<span class="rec">' + (recC ? fmt(recC) + ' recommended' : '') + '</span>' +
        '<span class="size">' + (size ? fmt(size) : '—') + '</span>' + icon('chevron', 'chev') + '</button>';
    }).join('') + '</div>';
    return html;
  }

  function viewEmpty() {
    return '<div class="empty"><span class="tile big" style="--c:#4f82ff">' + icon('sparkles') + '</span>' +
      '<h2>Find the space your dev tools left behind</h2>' +
      '<p>SpaceSaver looks for build folders in dormant projects, package-manager and editor caches, AI models and WSL disks. Scanning only reads; nothing changes until you confirm.</p>' +
      '<button class="w-btn brand" data-act="scan">' + icon('refresh') + 'Scan this PC</button></div>';
  }

  function viewScanning() {
    return '<div class="empty"><div class="scanning-ring"></div><h2>Scanning…</h2>' +
      '<p>Looking through your projects, package caches, editors, AI models and WSL disks. This usually takes a few seconds.</p></div>';
  }

  // ---------- category ----------
  function itemRow(i) {
    const manual = !i.method || i.method.kind !== 'recycleBin';
    const sel = state.selected.has(i.id) && selectable(i);
    const check = selectable(i)
      ? '<button class="check' + (sel ? ' on' : '') + '" data-act="toggle" data-id="' + esc(i.id) + '" role="checkbox" aria-checked="' + sel + '" aria-label="Select ' + esc(i.title) + '">' + icon('check') + '</button>'
      : '<button class="check locked" disabled title="' + esc(manual ? 'Never deleted. See the steps below.' : i.blockedReason) + '">' + icon('lock') + '</button>';
    const badge = manual ? '<span class="risk manual">Manual</span>' : '<span class="risk ' + esc(i.risk) + '">' + (RISK[i.risk] || esc(i.risk)) + '</span>';
    const tags = (i.tags || []).map((t) => '<span class="chip' + (/^Active/.test(t) ? ' active' : /^Dormant/.test(t) ? ' dormant' : '') + '">' + esc(t) + '</span>').join('');
    let html = '<div class="item w-card' + (sel ? ' selected' : '') + (selectable(i) ? '' : ' blocked') + '" data-item="' + esc(i.id) + '">' + check +
      '<div class="item-main"><div class="item-top"><b>' + esc(i.title) + '</b>' + badge + tags + '</div>' +
      '<div class="item-path"><span class="mono" title="' + esc((i.paths || []).join('\n')) + '">' + esc(i.subtitle) + '</span>' +
      '<button class="icon-btn" data-act="reveal" data-path="' + esc((i.paths || [])[0]) + '" title="Show in Explorer" aria-label="Show in Explorer">' + icon('folder') + '</button></div>' +
      (i.explanation ? '<p class="item-exp">' + esc(i.explanation) + '</p>' : '') +
      (i.regenerate ? '<p class="item-regen">' + icon('rotate') + '<span>' + esc(i.regenerate) + '</span></p>' : '') +
      (i.blockedReason ? '<p class="item-blocked">' + icon('alert') + '<span>' + esc(i.blockedReason) + '</span></p>' : '');
    if (manual && i.method.kind === 'manual') {
      html += '<details class="steps"' + (inCat(i.category).length <= 2 ? ' open' : '') + '><summary>' + icon('chevron', 'chev-i') + 'How to shrink it</summary>' +
        '<pre>' + esc(i.method.instructions) + '</pre><div class="cmds">' +
        (i.method.commands || []).map((c) => '<div class="cmd"><span class="prompt">&gt;</span><code>' + esc(c) + '</code>' +
          '<button class="icon-btn" data-act="copy" data-text="' + esc(c) + '" title="Copy" aria-label="Copy command">' + icon('copy') + '</button></div>').join('') +
        '</div></details>';
    } else if (manual && i.method.kind === 'command') {
      const c = [i.method.program].concat(i.method.args || []).join(' ');
      html += '<div class="cmds" style="padding:10px 0 0"><div class="cmd"><code>' + esc(c) + '</code><button class="icon-btn" data-act="copy" data-text="' + esc(c) + '" title="Copy">' + icon('copy') + '</button></div></div>';
    }
    html += '</div><div class="item-size">' + fmt(i.size) + (i.files > 1 ? '<small>' + i.files.toLocaleString() + ' files</small>' : '') + '</div></div>';
    return html;
  }

  function catSelectionText(id) {
    const list = inCat(id).filter((i) => state.selected.has(i.id) && selectable(i));
    return list.length ? plural(list.length, 'item') + ' selected · ' + fmt(sum(list)) : 'Nothing selected';
  }

  function viewCategory(id) {
    const c = CAT[id];
    if (!state.scan) return state.scanning ? viewScanning() : viewEmpty();
    const list = inCat(id).slice();
    const total = sum(list);
    let html = '<div class="cat-head"><span class="tile big" style="--c:' + c.c + '">' + icon(c.icon) + '</span>' +
      '<div><h2>' + esc(c.title) + '</h2><p>' + esc(c.blurb) + '</p></div>' +
      '<div class="cat-total"><b>' + fmt(total) + '</b><span>' + plural(list.length, 'item') + '</span></div></div>';
    if (!list.length) {
      return html + '<div class="empty">' + icon('checkCircle') + '<p>Nothing found here.</p></div>';
    }
    const anySelectable = list.some(selectable);
    if (anySelectable) {
      html += '<div class="cat-tools"><button class="ghost-btn" data-act="select-rec">' + icon('wand') + 'Select recommended</button>' +
        '<button class="ghost-btn" data-act="select-none">Select none</button>' +
        '<span class="hint" id="cat-sel">' + catSelectionText(id) + '</span></div>';
    } else if (id === 'wslDocker') {
      html += '<div class="cat-tools"><span class="hint" style="margin-left:0">' + icon('lock') + 'SpaceSaver never deletes these disks. Follow the steps to compact them; your files stay.</span></div>';
    }
    html += '<div class="items">';
    if (id === 'projectArtifacts') {
      const groups = new Map();
      for (const i of list) {
        const g = i.group || '';
        if (!groups.has(g)) groups.set(g, []);
        groups.get(g).push(i);
      }
      const ordered = [...groups.entries()].sort((a, b) => sum(b[1]) - sum(a[1]));
      for (const [g, gi] of ordered) {
        html += '<div class="group-head">' + icon('folder') + '<span class="mono">' + esc(g) + '</span><span>· ' + fmt(sum(gi)) + '</span></div>';
        html += gi.sort((a, b) => b.size - a.size).map(itemRow).join('');
      }
    } else {
      html += list.sort((a, b) => b.size - a.size).map(itemRow).join('');
    }
    return html + '</div>';
  }

  // ---------- activity ----------
  function viewActivity() {
    const list = state.activity || [];
    let html = '<div class="cat-head"><span class="tile big" style="--c:#8c8c99">' + icon('history') + '</span>' +
      '<div><h2>Activity</h2><p>Every cleanup, with what moved. Restore puts items back where they were while they\'re still in the Recycle Bin.</p></div><div></div></div>';
    if (!list.length) return html + '<div class="empty"><p>No cleanups yet.</p></div>';
    html += '<div class="act-list">' + list.map((e) => {
      const restorable = (e.records || []).some((r) => !r.restored);
      const status = { incomplete: 'Incomplete (interrupted)', completed: 'Completed', partial: 'Partly done', failed: 'Failed', restored: 'Restored', partiallyRestored: 'Partly restored' }[e.status] || e.status;
      const cls = e.status === 'restored' || e.status === 'partiallyRestored' ? 'restored' : e.status === 'incomplete' ? 'partial' : e.status;
      return '<div class="act w-card"><span class="act-icon ' + esc(cls) + '">' + icon(cls === 'restored' ? 'undo' : cls === 'completed' ? 'trash' : 'alert') + '</span>' +
        '<div class="act-main"><b>' + esc(e.title) + '</b><span>' + new Date(e.date * 1000).toLocaleString() + ' · ' + esc(status) + ' · from the ' + esc(e.source === 'cli' ? 'command line' : 'app') + '</span>' +
        (e.records && e.records.length ? '<details><summary>' + plural(e.records.length, 'path') + '</summary><ul>' + e.records.map((r) =>
          '<li>' + (r.restored ? icon('undo') : '<span></span>') + '<span class="mono" title="' + esc(r.original) + '">' + esc(r.original) + '</span><span class="num">' + fmt(r.bytes) + '</span></li>').join('') + '</ul></details>' : '') +
        ((e.errors || []).length ? '<div class="act-err">' + esc(e.errors[0]) + (e.errors.length > 1 ? ' (+' + (e.errors.length - 1) + ' more)' : '') + '</div>' : '') +
        '</div><span class="act-size">' + fmt(e.bytes) + '</span>' +
        (restorable ? '<button class="w-btn brand sm" data-act="restore" data-id="' + esc(e.id) + '">' + icon('undo') + 'Restore</button>' : '<span></span>') +
        '</div>';
    }).join('') + '</div>';
    return html;
  }

  // ---------- selection bar ----------
  function renderSelBar() {
    const bar = $('#sel-bar');
    const onCategory = !!CAT[state.view];
    const sel = selectedItems();
    if (!onCategory || !sel.length || !state.scan) { bar.hidden = true; return; }
    const cats = new Set(sel.map((i) => i.category)).size;
    bar.hidden = false;
    bar.innerHTML = '<span><b>' + plural(sel.length, 'item') + '</b> · <b>' + fmt(sum(sel)) + '</b></span>' +
      '<span class="muted">' + (cats > 1 ? 'across ' + cats + ' categories' : 'selected') + '</span>' +
      '<button class="w-btn ok" data-act="review">' + icon('sparkles') + 'Review & clean</button>';
  }

  // ---------- render ----------
  function render() {
    renderNav();
    renderSideDisk();
    renderToolbar();
    const content = $('#content');
    const entering = state.lastView !== state.view;
    let html;
    if (state.view === 'overview') html = viewOverview();
    else if (state.view === 'activity') html = viewActivity();
    else html = viewCategory(state.view);
    content.innerHTML = '<div class="view' + (entering ? ' enter' : '') + '">' + html + '</div>';
    if (entering) content.scrollTop = 0;
    state.lastView = state.view;
    animateRing(entering);
    renderSelBar();
  }

  function animateRing(animate) {
    const segs = document.querySelectorAll('.ring-seg');
    const apply = () => segs.forEach((s) => {
      s.setAttribute('stroke-dasharray', s.dataset.len + ' 1000');
      s.setAttribute('stroke-dashoffset', String(-Number(s.dataset.start)));
    });
    if (animate) requestAnimationFrame(() => requestAnimationFrame(apply));
    else { segs.forEach((s) => { s.style.transition = 'none'; }); apply(); }
  }

  function go(view) {
    state.view = view;
    render();
  }

  // ---------- actions ----------
  function toggle(id) {
    if (state.selected.has(id)) state.selected.delete(id); else state.selected.add(id);
    const on = state.selected.has(id);
    const row = document.querySelector('[data-item="' + CSS.escape(id) + '"]');
    if (row) {
      row.classList.toggle('selected', on);
      const btn = row.querySelector('.check');
      btn.classList.toggle('on', on);
      btn.setAttribute('aria-checked', String(on));
    }
    const hint = $('#cat-sel');
    if (hint && CAT[state.view]) hint.textContent = catSelectionText(state.view);
    renderSelBar();
  }

  function selectInView(mode) {
    const list = CAT[state.view] ? inCat(state.view) : items();
    for (const i of list) {
      if (mode === 'none') state.selected.delete(i.id);
      else if (i.recommended && selectable(i)) state.selected.add(i.id);
      else state.selected.delete(i.id);
    }
    render();
  }

  function openModal(html) {
    const m = $('#modal');
    m.innerHTML = html;
    m.hidden = false;
    const focus = m.querySelector('[data-autofocus]') || m.querySelector('button');
    if (focus) focus.focus();
  }

  function closeModal() {
    if (state.busy) return;
    state.pending = [];
    state.pendingScanId = null;
    $('#modal').hidden = true;
    $('#modal').innerHTML = '';
  }

  const SCAN_MAX_AGE = 3600;

  function openReview(list, heading) {
    list = list.filter(selectable);
    if (!list.length) { toast('Nothing selected.'); return; }
    if (!api.demo && state.scan) {
      const stale = state.scan.id !== state.liveScanId || (Date.now() / 1000 - state.scan.date) > SCAN_MAX_AGE;
      if (stale) {
        toast('Scan again before cleaning: this list is from an earlier scan. Scanning now…');
        doScan();
        return;
      }
    }
    state.pending = list;
    state.pendingScanId = state.scan ? state.scan.id : null;
    const total = sum(list);
    const notSafe = list.filter((i) => i.risk !== 'safe');
    const rows = CATS.map((c) => {
      const ci = list.filter((i) => i.category === c.id);
      if (!ci.length) return '';
      return '<div class="review-cat"><span>' + esc(c.title) + '</span><span>' + fmt(sum(ci)) + '</span></div>' +
        ci.map((i) => '<div class="review-row"><span title="' + esc(i.subtitle) + '">' + esc(i.title) + '</span><span class="risk ' + esc(i.risk) + '">' + (RISK[i.risk] || '') + '</span><b>' + fmt(i.size) + '</b></div>').join('');
    }).join('');
    openModal('<div class="sheet" role="dialog" aria-modal="true" aria-labelledby="rv-title">' +
      '<h3 id="rv-title">' + esc(heading || 'Review') + ': move ' + plural(list.length, 'item') + ' to the Recycle Bin?</h3>' +
      '<p class="sub">This moves ' + plural(list.length, 'item') + ', ' + fmt(total) + ', to the Recycle Bin.</p>' +
      '<div class="review-list">' + rows + '</div>' +
      '<div class="sheet-note">' + icon('undo') + '<span>You can restore everything from Activity until you empty the Recycle Bin. The disk space comes back once it\'s emptied.</span></div>' +
      (notSafe.length ? '<div class="sheet-note warn">' + icon('alert') + '<span>' + plural(notSafe.length, 'item') + ' marked Review take time or bandwidth to rebuild.</span></div>' : '') +
      '<div class="sheet-actions"><button class="ghost-btn" data-act="modal-close">Cancel</button>' +
      '<button class="w-btn danger" data-act="confirm-clean" data-autofocus>' + icon('trash') + 'Move ' + fmt(total) + ' to the Recycle Bin</button></div></div>');
  }

  function showProgress(total) {
    state.busy = true;
    openModal('<div class="sheet center" role="dialog" aria-modal="true" aria-live="polite">' +
      '<div class="scanning-ring"></div><h3>Moving to the Recycle Bin…</h3>' +
      '<div class="pbar"><span id="pbar"></span></div><p class="progress-line" id="pline">Starting · 0 of ' + total + '</p></div>');
  }

  function updateProgress(p) {
    const bar = document.getElementById('pbar');
    const line = document.getElementById('pline');
    if (!bar || !line || !p) return;
    bar.style.width = (p.total ? (p.done / p.total) * 100 : 100).toFixed(1) + '%';
    line.textContent = p.current ? (p.done + 1) + ' of ' + p.total + ' · ' + p.current : 'Finishing…';
  }

  function showResult(report) {
    const moved = report.items || [];
    const problems = (report.skipped || []).map((s) => s.title + ': ' + s.reason).concat(report.errors || []);
    const list = problems.length ? '<div class="result-list">' + problems.map((p) => '<p>' + icon('alert') + ' ' + esc(p) + '</p>').join('') + '</div>' : '';
    if (!moved.length) {
      openModal('<div class="sheet center" role="dialog" aria-modal="true"><div class="burst" style="filter:grayscale(1)">' + icon('x') + '</div>' +
        '<h3>Nothing was moved</h3>' + list +
        '<div class="sheet-actions"><button class="w-btn brand" data-act="modal-close" data-autofocus>Close</button></div></div>');
      return;
    }
    openModal('<div class="sheet center" role="dialog" aria-modal="true"><div class="burst">' + icon('check') + '</div>' +
      '<h3>Moved ' + fmt(report.bytes) + ' to the Recycle Bin</h3>' +
      '<p class="sub">' + plural(moved.length, 'item') + '. Empty the Recycle Bin to get the space back. Changed your mind? Restore it from Activity.</p>' + list +
      '<div class="sheet-actions"><button class="ghost-btn" data-act="goto-activity">' + icon('history') + 'View activity</button>' +
      '<button class="w-btn ok" data-act="modal-close" data-autofocus>Done</button></div></div>');
  }

  async function runClean() {
    const list = state.pending;
    if (!list.length) return;
    showProgress(list.length);
    let report;
    try {
      report = await api.clean(list.map((i) => i.id), state.pendingScanId);
    } catch (e) {
      state.busy = false;
      openModal('<div class="sheet center" role="dialog" aria-modal="true"><h3>Cleanup failed</h3><p class="sub">' + esc(errText(e)) + '</p>' +
        '<div class="sheet-actions"><button class="w-btn brand" data-act="modal-close" data-autofocus>Close</button></div></div>');
      return;
    }
    try {
      const [scan, activity, disk] = await Promise.all([api.lastScan(), api.activity(), api.disk()]);
      if (scan) setScan(scan, false);
      state.activity = activity || [];
      if (disk) state.disk = disk;
    } catch (e) { console.error(e); }
    (report.movedIds || []).forEach((id) => state.selected.delete(id));
    state.busy = false;
    state.pending = [];
    state.pendingScanId = null;
    render();
    showResult(report);
  }

  async function doScan() {
    if (state.scanning) return;
    state.scanning = true;
    render();
    try {
      const scan = await api.scan();
      state.liveScanId = scan.id || null;
      // A review opened on the previous scan no longer matches what's shown.
      if (state.pending.length && !state.busy) {
        state.pending = [];
        state.pendingScanId = null;
        closeModal();
        toast('The scan finished while the review was open. Review your selection again.');
      }
      setScan(scan, true);
      if (!state.disk) state.disk = await api.disk();
    } catch (e) {
      toast('Scan failed: ' + errText(e));
    } finally {
      state.scanning = false;
      render();
    }
  }

  async function restore(id, btn) {
    if (btn) btn.disabled = true;
    try {
      const r = await api.restore(id);
      const msg = r.restored ? 'Restored ' + plural(r.restored, 'path') + ' to where they were.' : 'Nothing was restored.';
      toast(r.errors && r.errors.length ? msg + ' ' + r.errors[0] : msg + (api.demo ? '' : ' Scan again to see them.'));
      state.activity = await api.activity();
      const scan = await api.lastScan();
      if (scan) setScan(scan, false);
    } catch (e) {
      toast('Restore failed: ' + errText(e));
    }
    render();
  }

  function copy(text) {
    const done = () => toast('Copied: ' + (text.length > 60 ? text.slice(0, 57) + '…' : text));
    const fallback = () => {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); done(); } catch (e) { toast('Copy failed'); }
      ta.remove();
    };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, fallback);
    else fallback();
  }

  document.addEventListener('click', (e) => {
    const el = e.target.closest('[data-act]');
    if (!el || el.disabled) return;
    const act = el.dataset.act;
    if (act === 'nav') go(el.dataset.view);
    else if (act === 'toggle') toggle(el.dataset.id);
    else if (act === 'select-rec') selectInView('rec');
    else if (act === 'select-none') selectInView('none');
    else if (act === 'smart-clean') openReview(recommended(), 'Smart Clean');
    else if (act === 'review') openReview(selectedItems(), 'Review');
    else if (act === 'confirm-clean') runClean();
    else if (act === 'modal-close') closeModal();
    else if (act === 'goto-activity') { closeModal(); go('activity'); }
    else if (act === 'restore') restore(el.dataset.id, el);
    else if (act === 'copy') copy(el.dataset.text);
    else if (act === 'reveal') api.reveal(el.dataset.path).catch((err) => toast(errText(err)));
    else if (act === 'scan') doScan();
  });

  $('#rescan').addEventListener('click', doScan);
  $('#modal').addEventListener('click', (e) => { if (e.target.id === 'modal') closeModal(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !$('#modal').hidden) closeModal(); });

  async function init() {
    $('#logo').innerHTML = icon('sparkles');
    if (api.demo) $('#demo-chip').hidden = false;
    try { api.onCleanProgress(updateProgress); } catch (e) { console.error(e); }
    try {
      const [scan, disk, activity] = await Promise.all([api.lastScan(), api.disk(), api.activity()]);
      state.disk = disk || null;
      state.activity = activity || [];
      if (scan) setScan(scan, true);
    } catch (e) {
      console.error(e);
    }
    render();
    if (!state.scan) doScan();
    setInterval(renderToolbar, 30000);
  }

  init();
})();
