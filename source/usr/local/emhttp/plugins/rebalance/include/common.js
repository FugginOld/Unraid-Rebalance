/* Array Rebalance - dashboard code shared by the Array Rebalance and Data Move tabs.
   The webGui renders both tabs into one document: one status poller feeds both, and each tab's
   element ids carry its own prefix ('rb-' or 'dm-'). Both pages load this file; the guard keeps one copy. */
window.RB = window.RB || (function () {
  var BASE = '/plugins/rebalance/include/';
  var KI = 1024, GI = 1024 * 1024, TI = GI * 1024;
  var ACTIVE = ['planning', 'running', 'paused'];
  var STATES = {
    idle: ['Idle', ''], planning: ['Planning', 'warn'], planned: ['Dry run ready', 'info'], running: ['Running', 'ok'],
    paused: ['Paused', 'warn'], stopped: ['Stopped', ''], done: ['Done', 'ok'], aborted: ['Aborted', 'bad'],
    error: ['Error', 'bad'], stale: ['Engine not running', 'bad']
  };
  var views = [], busy = false, last = null, csrf = '';

  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
  function fmtKiB(k) { k = Math.max(0, k || 0); return k >= TI ? (k / TI).toFixed(2) + ' TiB' : k >= GI ? (k / GI).toFixed(1) + ' GiB' : (k / KI).toFixed(0) + ' MiB'; }
  function fmtSigned(k) { return (k >= 0 ? '+' : '\u2212') + Math.abs(Math.round(k / GI)) + ' GiB'; }
  function fmtRate(b) { return b > 0 ? (b / 1e6).toFixed(0) + ' MB/s' : '-'; }
  function fmtDur(s) {
    s = Math.max(0, Math.round(s)); var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    return d ? d + 'd ' + h + 'h ' + m + 'm' : h ? h + 'h ' + m + 'm' : m ? m + ' min' : s + ' s';
  }
  function activeSecs(d) { return d.now - d.started - (d.paused_s || 0); }
  function fmtTime(t) { return new Date(t * 1000).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }); }
  function svg(path, color) {
    var ns = 'http://www.w3.org/2000/svg', s = document.createElementNS(ns, 'svg'), p = document.createElementNS(ns, 'path');
    s.setAttribute('width', '16'); s.setAttribute('height', '16'); s.setAttribute('viewBox', '0 0 16 16'); s.setAttribute('fill', 'none');
    s.style.stroke = color; s.setAttribute('stroke-width', '1.8'); s.setAttribute('stroke-linecap', 'round'); s.setAttribute('aria-hidden', 'true');
    s.setAttribute('class', 'ico'); p.setAttribute('d', path); s.appendChild(p); return s;
  }
  function isMove(mode) { return /^move-/.test(mode || ''); }

  function poll() {
    if (document.hidden && last) return;
    fetch(BASE + 'status.php', { cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (d) { last = d; views.forEach(function (v) { v(d); }); })
      .catch(function () { views.forEach(function (v) { v(null); }); });
  }
  function post(action, extra) {
    var body = new URLSearchParams(Object.assign({ action: action, csrf_token: csrf }, extra || {}));
    busy = true;
    return fetch(BASE + 'action.php', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: body })
      .then(function (r) { return r.json(); })
      .catch(function () { return { ok: false, msg: 'Request failed - reload the page and try again' }; })
      .then(function (j) { busy = false; poll(); return j; });
  }

  // P: this tab's id prefix. page: { csrf, move, otherName, otherTab, otherRoot, otherBusy, ask, idle(d), extra(action), render(d) }
  function dashboard(P, page) {
    var $ = function (id) { return document.getElementById(P + '-' + id); };
    var movesKey = null;   // started time of the dry run whose script is shown
    csrf = page.csrf;

    function setMsg(text, cls, link) {
      var m = $('msg'); m.textContent = text || ''; m.className = 'msg' + (cls ? ' ' + cls : '');
      if (link) m.append(' ', link);
    }
    function act(action) {
      var ask = Object.assign({
        abort: 'Abort immediately? The item being moved right now will be left split across two disks. It stays readable through the user share, but won\u2019t be tidied up automatically.',
        stop: 'Stop after the current move finishes?'
      }, page.ask)[action];
      if (ask && !confirm(ask)) return;
      post(action, page.extra ? page.extra(action) : null).then(function (j) { if (!j.ok) setMsg(j.msg, 'bad'); });
    }
    function button(label, action, cls, disabled) {
      var b = el('button', 'rb-btn' + (cls ? ' ' + cls : ''), label); b.type = 'button'; b.disabled = !!disabled;
      b.addEventListener('click', function () { act(action); }); return b;
    }
    function own(d) {   // a run of the other tab's kind shows here as idle; d.other holds its state while it is active
      if (!d.mode || isMove(d.mode) === !!page.move) return d;
      return Object.assign({}, d, {
        state: 'idle', msg: '', warn: false, request: '', pause_reason: '', started: null, updated: null,
        plan: { count: 0, kib: 0, left_out: 0 }, done: { count: 0, kib: 0, skipped: 0, failed: 0 },
        current: null, queue: [], queue_count: 0, queue_kib: 0, history: [],
        other: ACTIVE.indexOf(d.state) >= 0 ? d.state : ''
      });
    }
    function otherLink() {
      var a = el('a', null, 'View it on the ' + page.otherName + ' tab.'); a.href = '#';
      a.addEventListener('click', function (e) {
        e.preventDefault();
        var t = document.getElementById(page.otherTab);
        if (t) t.click(); else document.getElementById(page.otherRoot).scrollIntoView();
      });
      return a;
    }

    function renderHead(d) {
      var s = STATES[d.state] || [d.state, ''];
      var warn = d.state === 'done' && d.warn;   // "Nothing can be moved": done, but a disk is still over target
      var label = s[0];
      if (d.state === 'paused' && d.pause_reason && d.pause_reason !== 'user') label = 'Paused \u00b7 ' + d.pause_reason;
      var pending = d.request === 'stop' || (d.request === 'pause' && d.state === 'running') ? d.request : '';
      if (pending) label += ' \u00b7 ' + (pending === 'pause' ? 'pausing' : 'stopping') + (d.state === 'running' ? ' after this move' : '');
      var pill = $('pill'); pill.className = 'pill ' + (warn ? 'warn' : s[1]); pill.lastChild.textContent = label;

      var meta = [];
      var active = ['planning', 'running', 'paused'].indexOf(d.state) >= 0;
      if (d.started) {
        meta.push((active ? 'Started ' : 'Last run started ') + fmtTime(d.started));
        if (active) meta.push('Elapsed ' + fmtDur(activeSecs(d)) + (d.paused_s ? ' (+' + fmtDur(d.paused_s) + ' paused)' : ''));
      } else meta.push('No run yet');
      if (d.updated && active) meta.push('Updated ' + fmtDur(d.now - d.updated) + ' ago');
      $('meta').textContent = meta.join(' \u00b7 ');

      var a = $('actions'); a.textContent = '';
      if (d.state === 'running') {
        // 'resume' overwrites the pending control word, so it doubles as cancel
        if (pending === 'pause') a.append(button('Cancel pause', 'resume'), button('Stop after this move', 'stop'));
        else if (pending === 'stop') a.append(button('Cancel stop', 'resume'));
        else a.append(button('Pause after this move', 'pause'), button('Stop after this move', 'stop'));
        a.append(button('Abort now', 'abort', 'danger'));
      } else if (d.state === 'paused') {
        if (d.pause_reason === 'user') a.append(button('Resume', 'resume', 'primary'));
        if (pending !== 'stop') a.append(button('Stop', 'stop'));
        a.append(button('Abort now', 'abort', 'danger'));
      } else if (d.state === 'planning') {
        a.append(button('Abort', 'abort', 'danger'));
      } else {
        page.idle(d).forEach(function (b) { a.append(button(b[0], b[1], b[2], b[3] || !!d.other)); });
      }
      if (d.other) setMsg(page.otherBusy, 'warn', otherLink());
      else if (d.state === 'error' || d.state === 'stale') setMsg(d.msg || 'The engine stopped unexpectedly - check the log.', 'bad');
      else setMsg(d.msg || '', warn ? 'warn' : '');
    }

    function chip(k, v, s) {
      var c = el('div', 'chip'); c.append(el('div', 'k', k), el('div', 'v', v)); if (s) c.append(el('div', 's', s)); return c;
    }
    function renderChips(d) {
      var A = d.array, wm = { '0': 'Read/modify/write', '1': 'Reconstruct \u00b7 turbo', 'auto': 'Auto' }[A.write_method] || (A.write_method || 'Unknown');
      var safety = d.cfg.SKIP_OPEN_FILES === 'true' || d.cfg.SKIP_HARDLINKED === 'true';
      var c = $('chips'); c.textContent = '';
      c.append(
        chip('Array', A.state === 'STARTED' ? 'Started' : A.state),
        chip('Parity check', A.parity ? 'Running' : 'Idle'),
        chip('Mover', A.mover ? 'Running' : 'Idle'),
        chip('Write method', wm, A.observed ? 'observed: ' + A.observed : null),
        chip('Live-safety checks', (safety ? 'On' : 'Off') + (A.docker ? ' \u00b7 Docker running' : ''))
      );
    }

    function renderOverall(d) {
      var total = d.plan.kib, cur = d.current, moved = d.done.kib + (cur ? cur.bytes / 1024 : 0);
      moved = Math.min(moved, total);
      var pct = total ? moved / total * 100 : 0;
      if (!d.plan.count) {
        $('pct').textContent = '-';
        $('pct-sub').textContent = d.state === 'planning' ? 'Building the plan\u2026'
          : d.state === 'done' ? (d.warn ? 'Nothing can be moved' : 'Nothing to move') : 'Run a dry run to see what would move';
      } else if (d.state === 'planned') {
        $('pct').textContent = fmtKiB(total);
        $('pct-sub').textContent = 'planned across ' + d.plan.count + ' moves (dry run)';
      } else {
        $('pct').textContent = pct.toFixed(1) + '%';
        $('pct-sub').textContent = fmtKiB(moved) + ' of ' + fmtKiB(total) + ' moved';
      }
      $('bar').style.width = (d.state === 'planned' ? 0 : pct).toFixed(2) + '%';
      $('s-moves').textContent = d.plan.count ? d.done.count + ' / ' + d.plan.count : '-';
      $('s-skip').textContent = d.plan.count || d.plan.left_out ? String(d.done.skipped + d.plan.left_out) : '-';
      var running = ['running', 'paused'].indexOf(d.state) >= 0;
      var avg = running && d.started && activeSecs(d) > 0 ? moved * 1024 / activeSecs(d) : 0;
      $('s-avg').textContent = avg ? fmtRate(avg) : '-';
      var rate = cur && cur.rate ? cur.rate : avg;
      $('s-eta').textContent = running && rate ? '\u2248 ' + fmtDur((total - moved) * 1024 / rate) : '-';
    }

    function renderCurrent(d) {
      var box = $('current'), c = d.current; box.textContent = '';
      if (!c) {
        box.append(el('h2', 'label', 'Now moving'));
        var t = d.state === 'paused' ? 'Paused \u00b7 ' + (d.pause_reason === 'user' ? 'waiting for Resume' : 'waiting for the ' + d.pause_reason + ' to finish')
              : d.state === 'planning' ? 'Scanning disks and building the plan\u2026' : 'Nothing is moving right now.';
        box.append(el('div', 'muted', t)); return;
      }
      box.append(el('h2', 'label', 'Now moving \u00b7 item ' + c.idx + ' of ' + d.plan.count));
      box.append(el('div', 'cur-title', c.title));
      var r = el('div', 'route'); r.append(el('span', 'dtag from', c.src), svg('M1 8h13M10 4l4 4-4 4', 'var(--muted)'), el('span', 'dtag to', c.dst), el('span', 'muted', c.share + ' share'));
      box.append(r);
      if (c.cmd) box.append(el('div', 'cmd', c.cmd));   // exact rsync command, text only
      var bar = el('div', 'bar'); var f = el('div'); f.style.width = (c.pct || 0) + '%'; bar.append(f); box.append(bar);
      var left = c.rate ? ' \u00b7 ' + fmtDur(Math.max(0, c.kib * 1024 - c.bytes) / c.rate) + ' left' : '';
      var sp = el('div', 'spread'); sp.append(el('span', null, fmtKiB(c.bytes / 1024) + ' of ' + fmtKiB(c.kib)), el('span', 'soft', fmtRate(c.rate) + left));
      box.append(sp);
      var file = c.file ? c.file.replace(c.rel + '/', '') : 'Preparing\u2026';
      var fe = el('div', 'mono muted ellip', file); fe.style.fontSize = '12px'; fe.title = file; box.append(fe);
    }

    function renderLists(d) {
      $('q-meta').textContent = d.queue_count ? d.queue_count + ' items \u00b7 ' + fmtKiB(d.queue_kib) : '';
      var q = $('queue'); q.textContent = '';
      if (!d.queue.length) q.append(el('div', 'empty', d.plan.count ? 'Nothing left in the plan.' : 'No plan yet.'));
      d.queue.forEach(function (p) {
        var it = el('div', 'item'), l = el('div'); l.style.minWidth = '0';
        l.append(el('div', 't ellip', p.title), el('div', 'r', p.src + ' \u2192 ' + p.dst));
        var sz = el('div', 'mono soft', fmtKiB(p.kib)); sz.style.cssText = 'font-size:13px;white-space:nowrap';
        it.append(l, sz); q.append(it);
      });

      $('h-meta').textContent = d.done.count || d.done.skipped ? d.done.count + ' done' + (d.done.skipped ? ' \u00b7 ' + d.done.skipped + ' skipped' : '') : '';
      var h = $('hist'); h.textContent = '';
      if (!d.history.length) h.append(el('div', 'empty', 'Nothing yet.'));
      d.history.forEach(function (x) {
        var it = el('div', 'item'), l = el('div'); l.style.cssText = 'display:flex;align-items:center;gap:10px;min-width:0';
        var icon = x.result === 'done' ? svg('M3 8.5l3.2 3L13 4.5', 'var(--green)') : x.result === 'skip' ? svg('M4 8h8', 'var(--amber-t)') : svg('M4 4l8 8M12 4l-8 8', 'var(--red-t)');
        var txt = el('div'); txt.style.minWidth = '0';
        txt.append(el('div', 't ellip', x.title), el('div', 'r', x.src + ' \u2192 ' + x.dst + (x.result !== 'done' ? ' \u00b7 ' + x.reason : '')));
        l.append(icon, txt);
        var stat = x.result === 'done' ? fmtKiB(x.kib) + ' \u00b7 ' + fmtDur(x.secs) + (x.secs ? ' \u00b7 ' + fmtRate(x.kib * 1024 / x.secs) : '') : x.result === 'skip' ? 'skipped' : 'failed';
        var s = el('div', 'mono soft', stat); s.style.cssText = 'font-size:12px;white-space:nowrap;text-align:right';
        it.append(l, s); h.append(it);
      });
    }

    function renderLog(d) {
      var ready = d.plan.count > 0 && d.state === 'planned';
      $('script').hidden = $('moves-pill').hidden = $('moves').hidden = !ready;
      if (ready && movesKey !== d.started) {   // fetch the script once per dry run, not on every poll
        movesKey = d.started;
        fetch(BASE + 'script.php', { cache: 'no-store' }).then(function (r) { if (!r.ok) throw r.status; return r.text(); })
          .then(function (t) { var m = $('moves-text'); m.textContent = ''; m.append(el('div', '', t)); })
          .catch(function () { movesKey = null; });
      }
      var box = $('log'); box.textContent = '';
      if (!d.log.length) { box.append(el('div', 'muted', 'No log yet.')); return; }
      d.log.forEach(function (line) {
        var cls = /\bSKIP\b|PAUSED|WARNING/.test(line) ? 'skip' : /ERROR|ABORT|PLAN-NOFIT|PLAN-CONFLICT/.test(line) ? 'err' : /\bMOVE\b/.test(line) ? 'mv' : '';
        box.append(el('div', cls, line));
      });
    }

    function render(d) {
      if (!d) { setMsg('Could not reach the status endpoint - retrying', 'bad'); return; }
      var o = own(d);
      renderHead(o); renderChips(o); renderOverall(o); renderCurrent(o); renderLists(o); renderLog(o);
      page.render(o);
    }

    views.push(render);
    if (views.length === 1) {   // the first tab starts the one poller
      poll();
      setInterval(function () { if (!busy) poll(); }, 3000);
      document.addEventListener('visibilitychange', function () { if (!document.hidden) poll(); });
    } else if (last) render(last);
    return { post: post, setMsg: setMsg, refresh: function () { if (last) render(last); } };
  }

  return { dashboard: dashboard, BASE: BASE, KI: KI, GI: GI, TI: TI, ACTIVE: ACTIVE,
           el: el, svg: svg, fmtKiB: fmtKiB, fmtSigned: fmtSigned, fmtDur: fmtDur };
})();
