// SpaceSaver website: download metadata, the interactive island, the room planner.
(() => {
  'use strict';

  const REPO = 'rushabh05/SpaceSaver';
  // Visit counting: sign up at https://www.goatcounter.com, then put your site code here
  // (for "spacesaver.goatcounter.com" it's 'spacesaver'). Empty means no analytics at all.
  const GOATCOUNTER_CODE = 'rushabh05';
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const gb = (n) => `${n.toFixed(1)} GB`;

  // Shared gradients for the island SVGs.
  document.body.insertAdjacentHTML('afterbegin', `
    <svg width="0" height="0" style="position:absolute" aria-hidden="true"><defs>
      <linearGradient id="iBrand" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#4f82ff"/><stop offset="1" stop-color="#8f5efa"/></linearGradient>
      <linearGradient id="iOk" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#21cc8f"/><stop offset="1" stop-color="#12a1c7"/></linearGradient>
      <linearGradient id="iBad" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ff5c5c"/><stop offset="1" stop-color="#f58533"/></linearGradient>
    </defs></svg>`);

  // ---------- Dynamic Island ----------
  const DISK = { total: 494.4, free: 18.6, safe: 42.2 };
  const CLEAN_STEPS = ['npm cache', 'pnpm store', 'Xcode DerivedData', 'Homebrew downloads',
    'Gradle caches', 'Simulator caches', 'node_modules (9 projects)', 'Docker build cache'];

  const islandHTML = `
    <div class="island low" data-mode="live">
      <div class="island-body">
        <div class="i-band">
          <div class="i-left">
            <svg class="i-mini" viewBox="0 0 20 20" aria-hidden="true"><circle class="trk" cx="10" cy="10" r="7.4"/><circle class="val" cx="10" cy="10" r="7.4" pathLength="100" stroke-dasharray="96 100"/></svg>
            <span class="i-title"><i data-lucide="sparkles"></i>SpaceSaver</span>
          </div>
          <div class="i-right"><span class="i-free"></span><span class="i-pct">96% used</span></div>
        </div>
        <div class="i-peek" aria-live="polite">
          <span class="i-peek-icon" data-icon="sparkles"><i data-lucide="sparkles"></i><i data-lucide="check"></i><i data-lucide="bot"></i></span>
          <div><b class="pk-title"></b><span class="pk-sub"></span></div>
        </div>
        <div class="i-exp">
          <div class="i-stats">
            <div class="i-ring">
              <svg viewBox="0 0 80 80" aria-hidden="true">
                <circle class="trk" cx="40" cy="40" r="33"/>
                <circle class="seg" cx="40" cy="40" r="33" pathLength="100" stroke="url(#iBrand)" stroke-dasharray="86.6 100"/>
                <circle class="seg seg-safe" cx="40" cy="40" r="33" pathLength="100" stroke="url(#iOk)" stroke-dasharray="8.5 100" stroke-dashoffset="-87.5"/>
              </svg>
              <div class="center"><i data-lucide="hard-drive"></i></div>
            </div>
            <div>
              <div class="i-num">${gb(DISK.free)} <small>free</small></div>
              <div class="i-sub">of ${gb(DISK.total)}</div>
              <div class="i-safe"></div>
            </div>
          </div>
          <div class="i-progress"><div><span class="pr-title"></span><span class="pr-count"></span></div><div class="track"><div class="fill"></div></div></div>
          <div class="i-actions">
            <button class="i-btn main" type="button"><i data-lucide="zap" class="ic-zap"></i><i data-lucide="trash-2" class="ic-trash"></i><i data-lucide="check" class="ic-done"></i><span class="lbl"></span></button>
            <button class="i-btn round scan" type="button" aria-label="Scan again"><i data-lucide="rotate-cw"></i></button>
            <button class="i-btn round open" type="button" aria-label="Open SpaceSaver"><i data-lucide="arrow-up-right"></i></button>
          </div>
        </div>
      </div>
    </div>`;

  // Show only the icon that matches the current state.
  const iconCSS = document.createElement('style');
  iconCSS.textContent = `
    .i-peek-icon svg{display:none}
    .i-peek-icon[data-icon=sparkles] .lucide-sparkles,.i-peek-icon[data-icon=check] .lucide-check,.i-peek-icon[data-icon=bot] .lucide-bot{display:block}
    .i-btn.main svg{display:none}
    .i-btn.main[data-icon=zap] .ic-zap,.i-btn.main[data-icon=trash] .ic-trash,.i-btn.main[data-icon=done] .ic-done{display:block}
    .island.cleaning .i-mini .val{stroke:url(#iOk)}`;
  document.head.appendChild(iconCSS);

  class Island {
    constructor(host) {
      host.innerHTML = islandHTML;
      this.el = host.firstElementChild;
      this.s = { hover: false, pinned: null, peek: null, cleaning: null, confirming: false, safe: DISK.safe, cleaned: false };
      this.listeners = [];
      this.el.addEventListener('mouseenter', () => { clearTimeout(this.leaveTimer); this.emit('user'); this.set({ hover: true }); });
      this.el.addEventListener('mouseleave', () => { this.leaveTimer = setTimeout(() => this.set({ hover: false }), 350); });
      $('.i-btn.main', this.el).addEventListener('click', () => this.quickClean());
      $('.i-btn.scan', this.el).addEventListener('click', () => this.rescan());
      $('.i-btn.open', this.el).addEventListener('click', () => toast('In the app, this opens the SpaceSaver window.'));
      this.render();
    }
    on(fn) { this.listeners.push(fn); }
    emit(kind) { this.listeners.forEach((fn) => fn(kind)); }
    set(patch) { Object.assign(this.s, patch); this.render(); }
    get mode() {
      if (this.s.hover || this.s.pinned === 'expanded') return 'expanded';
      if (this.s.peek || this.s.pinned === 'peek') return 'peek';
      return 'live';
    }
    peek(icon, title, sub, ms = 4000) {
      clearTimeout(this.peekTimer);
      this.set({ peek: { icon, title, sub } });
      if (ms) this.peekTimer = setTimeout(() => this.set({ peek: null }), ms);
    }
    quickClean() {
      const s = this.s;
      if (s.cleaning || s.safe <= 0) return;
      if (!s.confirming) {
        this.set({ confirming: true });
        this.confirmTimer = setTimeout(() => this.set({ confirming: false }), 4000);
        return;
      }
      clearTimeout(this.confirmTimer);
      const moved = s.safe;
      this.set({ confirming: false, cleaning: { done: 0, total: CLEAN_STEPS.length } });
      const step = () => {
        const c = this.s.cleaning;
        if (c.done < c.total) {
          this.set({ cleaning: { ...c, done: c.done + 1 } });
          this.cleanTimer = setTimeout(step, reduceMotion ? 60 : 420);
          return;
        }
        this.set({ cleaning: null, safe: 0, cleaned: true });
        this.peek('check', `Moved ${gb(moved)} to the Trash`, 'Restore it anytime from Activity', 5000);
        // Reset the demo so it can be tried again.
        this.resetTimer = setTimeout(() => this.set({ safe: DISK.safe, cleaned: false }), 9000);
      };
      this.cleanTimer = setTimeout(step, 250);
    }
    rescan() {
      if (this.s.cleaning) return;
      clearTimeout(this.resetTimer);
      this.set({ safe: DISK.safe, cleaned: false });
      this.peek('sparkles', 'Scan complete', `${gb(DISK.safe)} safe to clean`);
    }
    render() {
      const { s, el } = this;
      el.dataset.mode = this.mode;
      el.classList.toggle('cleaning', !!s.cleaning);
      const c = s.cleaning;
      $('.i-free', el).textContent = c ? `${c.done}/${c.total}` : gb(DISK.free);
      $('.i-mini .val', el).setAttribute('stroke-dasharray', c ? `${(c.done / c.total) * 100} 100` : '96 100');
      if (s.peek) {
        $('.i-peek-icon', el).dataset.icon = s.peek.icon;
        $('.pk-title', el).textContent = s.peek.title;
        $('.pk-sub', el).textContent = s.peek.sub;
      } else if (s.pinned === 'peek') {
        $('.i-peek-icon', el).dataset.icon = 'sparkles';
        $('.pk-title', el).textContent = 'Scan complete';
        $('.pk-sub', el).textContent = `${gb(DISK.safe)} safe to clean`;
      }
      $('.i-safe', el).innerHTML = s.cleaned
        ? `<b>${gb(DISK.safe)}</b> moved to the Trash`
        : `<b>${gb(s.safe)}</b> safe to clean`;
      $('.seg-safe', el).setAttribute('stroke-dasharray', `${s.cleaned ? 0 : 8.5} 100`);
      if (c) {
        $('.pr-title', el).textContent = `Cleaning ${CLEAN_STEPS[Math.max(c.done - 1, 0)]}`;
        $('.pr-count', el).textContent = `${c.done}/${c.total}`;
        $('.i-progress .fill', el).style.width = `${(c.done / c.total) * 100}%`;
      }
      const main = $('.i-btn.main', el);
      main.classList.toggle('confirm', s.confirming);
      main.disabled = !!c || s.safe <= 0;
      main.dataset.icon = s.cleaned ? 'done' : s.confirming ? 'trash' : 'zap';
      $('.lbl', main).textContent = s.cleaned ? 'All clean'
        : c ? 'Cleaning…'
        : s.confirming ? `Move ${gb(s.safe)} to Trash?` : 'Quick Clean';
    }
  }

  const islands = {};
  $$('[data-island]').forEach((host) => { islands[host.dataset.island] = new Island(host); });

  // Hero island cycles through its modes until someone hovers it.
  const hero = islands.hero;
  if (hero && !reduceMotion) {
    let auto = true;
    const timers = [];
    hero.on((kind) => { if (kind === 'user' && auto) { auto = false; timers.forEach(clearTimeout); hero.set({ pinned: null }); } });
    const cycle = () => {
      if (!auto) return;
      timers.push(setTimeout(() => auto && hero.peek('sparkles', 'Scan complete', `${gb(DISK.safe)} safe to clean`, 3400), 1800));
      timers.push(setTimeout(() => auto && hero.set({ pinned: 'expanded' }), 6000));
      timers.push(setTimeout(() => auto && hero.set({ pinned: null }), 10800));
      timers.push(setTimeout(cycle, 13000));
    };
    cycle();
  } else if (hero) {
    hero.set({ pinned: 'expanded' });
  }

  // Island section: the mode buttons pin a mode.
  const demo = islands.demo;
  if (demo) {
    const tabs = $$('.mode');
    const select = (mode) => {
      tabs.forEach((t) => t.setAttribute('aria-selected', String(t.dataset.mode === mode)));
      demo.set({ pinned: mode === 'live' ? null : mode, peek: null });
    };
    tabs.forEach((t) => t.addEventListener('click', () => select(t.dataset.mode)));
  }

  // ---------- Scale fixed-size mock-ups to their container ----------
  $$('.scaler').forEach((box) => {
    const inner = $('.scaled', box);
    const W = +box.dataset.w, H = +box.dataset.h;
    const fit = () => {
      const scale = Math.min(1, box.clientWidth / W);
      inner.style.transform = `scale(${scale})`;
      inner.style.left = `${Math.max(0, (box.clientWidth - W * scale) / 2)}px`;
      box.style.height = `${H * scale}px`;
    };
    new ResizeObserver(fit).observe(box);
    fit();
  });

  // ---------- Ring gauge in the hero window ----------
  const ring = $('[data-ring]');
  const drawRing = () => {
    let start = 0;
    $$('.ring-seg', ring).forEach((seg) => {
      const len = (+seg.dataset.seg / DISK.total) * 1000;
      seg.style.strokeDasharray = `${Math.max(len - 6, 0)} 1000`;
      seg.style.strokeDashoffset = `${-start}`;
      start += len;
    });
  };

  // ---------- Reveal on scroll ----------
  let ringDrawn = false;
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (!e.isIntersecting) return;
      e.target.classList.add('in');
      io.unobserve(e.target);
      if (!ringDrawn && e.target.contains(ring)) { ringDrawn = true; setTimeout(drawRing, 250); }
      $$('[data-count]', e.target).forEach(countUp);
    });
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
  // Stagger siblings that reveal together.
  $$('.reveal').forEach((el) => {
    const sibs = [...el.parentElement.children].filter((c) => c.classList.contains('reveal'));
    el.style.setProperty('--d', `${Math.min(sibs.indexOf(el), 6) * 0.06}s`);
    io.observe(el);
  });
  if (ring && !ring.closest('.reveal')) drawRing();

  function countUp(el) {
    const to = +el.dataset.count, dec = +(el.dataset.dec || 0);
    if (reduceMotion) return;
    const t0 = performance.now(), dur = 1100;
    const tick = (t) => {
      const p = Math.min(1, (t - t0) / dur), e = 1 - Math.pow(1 - p, 3);
      el.textContent = (to * e).toFixed(dec);
      if (p < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }

  // ---------- Make room planner (mirrors RoomPlanner in the app) ----------
  const ITEMS = [
    { t: 'Xcode DerivedData', p: '~/Library/Developer/Xcode/DerivedData', s: 9.4, r: 'safe', c: '#339ef2' },
    { t: 'node_modules in 9 dormant projects', p: '~/Developer/*/node_modules', s: 7.9, r: 'safe', c: '#5c8cfa' },
    { t: 'npm cache', p: '~/.npm/_cacache', s: 6.8, r: 'safe', c: '#8c6bf2' },
    { t: 'Docker build cache', p: 'docker builder prune', s: 5.6, r: 'safe', c: '#2194cc' },
    { t: 'pnpm store', p: '~/Library/pnpm/store', s: 4.2, r: 'safe', c: '#8c6bf2' },
    { t: 'Homebrew downloads', p: '~/Library/Caches/Homebrew', s: 3.1, r: 'safe', c: '#8c6bf2' },
    { t: 'Gradle caches', p: '~/.gradle/caches', s: 2.8, r: 'safe', c: '#8c6bf2' },
    { t: 'Simulator caches', p: '~/Library/Developer/CoreSimulator/Caches', s: 2.4, r: 'safe', c: '#339ef2' },
    { t: 'Hugging Face · Llama-3.1-8B-Instruct', p: '~/.cache/huggingface/hub', s: 16.1, r: 'review', c: '#d961bf' },
    { t: 'Ollama · qwen2.5-coder:14b', p: '~/.ollama/models', s: 9.0, r: 'review', c: '#d961bf' },
    { t: 'iOS 17.5 device support', p: '~/Library/Developer/Xcode/iOS DeviceSupport', s: 6.3, r: 'review', c: '#339ef2' },
    { t: 'Claude Code transcripts (archived first)', p: '~/.claude/projects', s: 1.2, r: 'review', c: '#ed738c' },
  ];
  const RANK = { safe: 0, review: 1 };
  const slider = $('#roomSlider');
  if (slider) {
    const out = $('#roomValue'), list = $('#roomList'), summary = $('#roomSummary'), cover = $('#roomCover');
    const sorted = [...ITEMS].sort((a, b) => (RANK[a.r] - RANK[b.r]) || (b.s - a.s));
    const available = sorted.reduce((n, i) => n + i.s, 0);
    let animateRows = false;
    const update = () => {
      const target = +slider.value;
      out.textContent = `${target} GB`;
      slider.style.setProperty('--fill', `${((target - slider.min) / (slider.max - slider.min)) * 100}%`);
      const chosen = [];
      let total = 0;
      for (const it of sorted) { if (total >= target) break; chosen.push(it); total += it.s; }
      const ok = total >= target;
      cover.style.width = `${Math.min(100, (total / target) * 100)}%`;
      const reviews = chosen.filter((i) => i.r === 'review').length;
      summary.innerHTML = ok
        ? `<b>${chosen.length} item${chosen.length === 1 ? '' : 's'}, safest first:</b> ${gb(total)}${reviews ? `, including ${reviews} to review` : ', all Safe'}.`
        : `<b>Only ${gb(available)} available</b> without touching anything marked Caution.`;
      // The plan is always a prefix of the sorted list, so only add or drop rows at the end.
      while (list.children.length > chosen.length) list.lastElementChild.remove();
      for (let n = list.children.length; n < chosen.length; n++) {
        const i = chosen[n];
        const li = document.createElement('li');
        if (animateRows) li.className = 'new';
        li.innerHTML = `<span class="d" style="--c:${i.c}"></span>
          <span>${i.t}<small>${i.p}</small></span>
          <span class="risk ${i.r}">${i.r === 'safe' ? 'Safe' : 'Review'}</span>
          <b>${gb(i.s)}</b>`;
        list.appendChild(li);
      }
    };
    slider.addEventListener('input', update);
    update();
    animateRows = true;
  }

  // ---------- Copy buttons ----------
  $$('[data-copy]').forEach((btn) => btn.addEventListener('click', async () => {
    const text = $(btn.dataset.copy).textContent;
    try { await navigator.clipboard.writeText(text); btn.classList.add('done'); toast('Copied to clipboard'); }
    catch { toast('Select the text to copy it'); }
    setTimeout(() => btn.classList.remove('done'), 1600);
  }));

  // ---------- Toast ----------
  const toastEl = $('#toast');
  let toastTimer;
  function toast(text) {
    toastEl.textContent = text;
    toastEl.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toastEl.classList.remove('show'), 2200);
  }

  // ---------- Nav border on scroll ----------
  const nav = $('.nav');
  const onScroll = () => nav.classList.toggle('scrolled', window.scrollY > 8);
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  // ---------- Latest release: version, size, checksum, direct link ----------
  fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } })
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((rel) => {
      const asset = (rel.assets || []).find((a) => a.name.endsWith('.dmg'));
      if (!asset) return;
      $$('[data-version]').forEach((el) => { el.textContent = rel.tag_name; });
      $$('[data-size]').forEach((el) => { el.textContent = `${(asset.size / 1e6).toFixed(1)} MB`; });
      $$('[data-download]').forEach((el) => { el.href = asset.browser_download_url; });
      if (asset.digest && asset.digest.startsWith('sha256:')) {
        $('[data-sha]').textContent = asset.digest.slice(7);
        $('[data-sha-row]').hidden = false;
      }
    })
    .catch(() => { /* keep the static fallbacks */ });

  // ---------- Analytics (cookieless; only when GOATCOUNTER_CODE is set) ----------
  if (GOATCOUNTER_CODE) {
    const gc = document.createElement('script');
    gc.async = true;
    gc.src = 'https://gc.zgo.at/count.js';
    gc.dataset.goatcounter = `https://${GOATCOUNTER_CODE}.goatcounter.com/count`;
    document.head.appendChild(gc);
    const note = document.createElement('p');
    note.className = 'privacy-note';
    note.textContent = 'This site counts visits with GoatCounter: no cookies, no personal data.';
    $('.foot-inner').appendChild(note);
  }

  // ---------- Icons ----------
  if (window.lucide) window.lucide.createIcons({ attrs: { 'aria-hidden': 'true' } });
})();
