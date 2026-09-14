/* In-app notifikácie — odznak pri zvončeku a panel so zoznamom.
 *
 * Vanilla JS bez závislostí, rovnako ako redmine_command_palette. Všetky id a triedy
 * sú prefixované `rin-`, lebo na stránke súčasne žije viacero cudzích overlayov
 * (command palette, AI asistent, rich editor).
 */
(function () {
  'use strict';

  var CFG = window.RIN_CONFIG || {};
  var i18n = CFG.i18n || {};
  var panel = null;
  var loading = false;

  function url(path) {
    return (CFG.base || '') + path;
  }

  function csrfToken() {
    var m = document.querySelector('meta[name="csrf-token"]');
    return m ? m.content : '';
  }

  function request(path, method) {
    return fetch(url(path), {
      method: method || 'GET',
      credentials: 'same-origin',
      headers: {
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
        'X-CSRF-Token': csrfToken()
      }
    }).then(function (res) {
      if (!res.ok) { throw new Error('HTTP ' + res.status); }
      return res.json();
    });
  }

  function bell() {
    return document.querySelector('a[data-rin="bell"]');
  }

  /* ------------------------------------------------------------------ *
   * Odznak s počtom
   * ------------------------------------------------------------------ */

  function setBadge(n) {
    var link = bell();
    if (!link) { return; }

    var badge = link.querySelector('.rin-badge');
    if (!n || n < 1) {
      if (badge) { badge.remove(); }
      link.removeAttribute('data-rin-unread');
      return;
    }

    if (!badge) {
      badge = document.createElement('span');
      badge.className = 'rin-badge';
      link.appendChild(badge);
    }
    /* Nad 99 sa do odznaku aj tak nič zmysluplné nezmestí a presné číslo nikoho nezaujíma. */
    badge.textContent = n > 99 ? '99+' : String(n);
    link.setAttribute('data-rin-unread', '1');
  }

  /* ------------------------------------------------------------------ *
   * Umiestnenie zvončeka v hlavičke
   *
   * Zvonček MUSÍ byť naľavo od čarovného prútika AI asistenta (požiadavka zadávateľa).
   * `#account` a `#loggedas` sú dva rôzne flex kontajnery, takže CSS `order` medzi nimi
   * nefunguje — rovnaký problém rieši `placePlanLink()` v ai_assistant.js presunom
   * samotného `<a>` o úroveň vyššie do `#top-menu`.
   * ------------------------------------------------------------------ */

  function wandLink() {
    return document.querySelector('#top-menu a[data-raa="plan"]');
  }

  function placeBell() {
    var link = bell();
    if (!link) { return; }

    var topMenu = document.getElementById('top-menu');
    var loggedas = document.getElementById('loggedas');
    if (!topMenu || !loggedas) { return; }

    if (link.dataset.rinPlaced !== '1') {
      var li = link.closest('li');
      topMenu.insertBefore(link, wandLink() || loggedas);
      if (li && !li.children.length) { li.remove(); }
      link.dataset.rinPlaced = '1';
    }

    ensureOrder();
  }

  /* Oba skripty bežia na DOMContentLoaded a nie je zaručené, ktorý prvý. Keď náš skript
   * beží skôr, prútik ešte v `#top-menu` nie je a zvonček by skončil napravo od neho.
   * Preto sa poradie po vložení ešte raz skontroluje — a keď prútik pribudne neskôr,
   * zvonček sa pred neho prehodí. Bez zásahu do ai_assistant. */
  function ensureOrder() {
    var link = bell();
    var wand = wandLink();
    if (!link || !wand || link.parentNode !== wand.parentNode) { return; }

    /* DOCUMENT_POSITION_FOLLOWING = wand je za zvončekom, teda poradie je správne. */
    var wandIsAfter = link.compareDocumentPosition(wand) & Node.DOCUMENT_POSITION_FOLLOWING;
    if (!wandIsAfter) {
      wand.parentNode.insertBefore(link, wand);
    }
  }

  /* ------------------------------------------------------------------ *
   * Panel
   * ------------------------------------------------------------------ */

  function buildPanel() {
    if (panel) { return panel; }

    var box = document.createElement('div');
    box.id = 'rin-panel';
    box.hidden = true;
    box.setAttribute('role', 'dialog');
    box.setAttribute('aria-label', i18n.title || 'Notifications');

    var head = document.createElement('div');
    head.className = 'rin-head';
    var title = document.createElement('span');
    title.className = 'rin-head-title';
    title.textContent = i18n.title || 'Notifications';
    var markAll = document.createElement('a');
    markAll.href = '#';
    markAll.className = 'rin-markall';
    markAll.textContent = i18n.readAll || 'Mark all as read';
    markAll.addEventListener('click', function (e) {
      e.preventDefault();
      markAllRead();
    });
    head.appendChild(title);
    head.appendChild(markAll);

    var body = document.createElement('div');
    body.className = 'rin-body-list';

    var foot = document.createElement('div');
    foot.className = 'rin-foot';
    var all = document.createElement('a');
    all.href = url('/inapp_notifications');
    all.textContent = i18n.seeAll || 'All notifications';
    var settings = document.createElement('a');
    settings.href = url('/notification_filter');
    settings.textContent = i18n.settings || 'E-mail settings';
    foot.appendChild(all);
    foot.appendChild(settings);

    box.appendChild(head);
    box.appendChild(body);
    box.appendChild(foot);
    document.body.appendChild(box);

    panel = { box: box, body: body };
    return panel;
  }

  /* Panel sa kotví k zvončeku, ale NIKDY nesmie vyliezť z okna.
   *
   * Pôvodná verzia ukotvila panel pravou hranou k zvončeku (`right: innerWidth - r.right`).
   * To funguje, len kým je zvonček vpravo — keď skončil v ľavej časti hlavičky, panel
   * odplával mimo obrazovky doľava a nebolo ho vidieť vôbec. Poloha sa preto počíta
   * explicitne a orezáva sa na okno; kde presne zvonček v hlavičke je, prestalo hrať rolu.
   */
  function positionPanel() {
    var link = bell();
    var p = buildPanel();
    if (!link) { return; }

    var r = link.getBoundingClientRect();
    var w = p.box.offsetWidth || 380;
    var margin = 8;

    /* Zarovnané pravou hranou k zvončeku, ale posunuté dnu, keby to nevychádzalo. */
    var left = r.right - w;
    left = Math.min(left, window.innerWidth - w - margin);
    left = Math.max(margin, left);

    p.box.style.top = (r.bottom + margin) + 'px';
    p.box.style.left = left + 'px';
    p.box.style.right = 'auto';
  }

  function isOpen() {
    return panel && !panel.box.hidden;
  }

  function openPanel() {
    var p = buildPanel();
    /* Poradie je dôležité: `offsetWidth` skrytého prvku je 0, takže sa musí najprv
     * zobraziť a až potom umiestniť — inak by výpočet polohy počítal so šírkou 0. */
    p.box.hidden = false;
    positionPanel();
    render(null, i18n.loading || 'Loading…');
    load();
  }

  function closePanel() {
    if (panel) { panel.box.hidden = true; }
  }

  function load() {
    if (loading) { return; }
    loading = true;

    request('/inapp_notifications/list')
      .then(function (data) {
        render(data.items || [], null);
        setBadge(data.unread);
      })
      .catch(function () {
        render(null, i18n.error || 'Could not load notifications.');
      })
      .finally(function () { loading = false; });
  }

  function render(items, message) {
    var p = buildPanel();
    while (p.body.firstChild) { p.body.removeChild(p.body.firstChild); }

    if (message) {
      var note = document.createElement('div');
      note.className = 'rin-note';
      note.textContent = message;
      p.body.appendChild(note);
      return;
    }

    if (!items.length) {
      var empty = document.createElement('div');
      empty.className = 'rin-note';
      empty.textContent = i18n.empty || 'Nothing new.';
      p.body.appendChild(empty);
      return;
    }

    items.forEach(function (item) { p.body.appendChild(row(item)); });
  }

  function row(item) {
    var el = document.createElement('a');
    el.className = 'rin-item' + (item.unread ? ' rin-unread' : '');
    /* Skutočný odkaz, nie div s onclick — stredný klik a „kopírovať odkaz" majú fungovať. */
    el.href = item.url || '#';
    el.setAttribute('data-rin-id', item.id);

    var dot = document.createElement('span');
    dot.className = 'rin-dot';
    el.appendChild(dot);

    var wrap = document.createElement('div');
    wrap.className = 'rin-item-body';

    var title = document.createElement('div');
    title.className = 'rin-title';
    title.textContent = item.title || '';
    wrap.appendChild(title);

    if (item.snippet) {
      var snip = document.createElement('div');
      snip.className = 'rin-snippet';
      snip.textContent = item.snippet;
      wrap.appendChild(snip);
    }

    var meta = document.createElement('div');
    meta.className = 'rin-meta';
    meta.textContent = [item.author, relTime(item.at)].filter(Boolean).join(' · ');
    wrap.appendChild(meta);

    el.appendChild(wrap);

    el.addEventListener('click', function () {
      /* Optimisticky odznačíme a POST pošleme s `keepalive`, aby prežil navigáciu,
       * ktorá začne hneď po tomto handleri. */
      if (item.unread) {
        item.unread = false;
        el.classList.remove('rin-unread');
        markRead(item.id);
      }
    });

    return el;
  }

  function relTime(iso) {
    if (!iso) { return ''; }
    var then = new Date(iso).getTime();
    if (isNaN(then)) { return ''; }

    var mins = Math.round((Date.now() - then) / 60000);
    if (mins < 1) { return 'now'; }
    if (mins < 60) { return mins + ' min'; }
    var hours = Math.round(mins / 60);
    if (hours < 24) { return hours + ' h'; }
    return Math.round(hours / 24) + ' d';
  }

  function markRead(id) {
    fetch(url('/inapp_notifications/' + id + '/read'), {
      method: 'POST',
      credentials: 'same-origin',
      keepalive: true,
      headers: {
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
        'X-CSRF-Token': csrfToken()
      }
    }).then(function (res) {
      return res.ok ? res.json() : null;
    }).then(function (data) {
      if (data) { setBadge(data.unread); }
    }).catch(function () { /* navigácia prebieha, na odpovedi nezáleží */ });
  }

  function markAllRead() {
    request('/inapp_notifications/read_all', 'POST')
      .then(function (data) {
        setBadge(data.unread);
        load();
      })
      .catch(function () { /* ticho — panel zostane, ako bol */ });
  }

  /* ------------------------------------------------------------------ *
   * Napojenie
   * ------------------------------------------------------------------ */

  function onBellClick(e) {
    var link = e.target.closest('a[data-rin="bell"]');
    if (!link) { return; }
    e.preventDefault();

    if (isOpen()) { closePanel(); } else { openPanel(); }
  }

  function init() {
    placeBell();
    setBadge(CFG.unread);

    document.addEventListener('click', onBellClick);

    /* Zatvorenie klikom mimo — kontroluje sa `contains`, nie rovnosť cieľa,
     * inak by panel zavrel aj klik na vlastný riadok. */
    document.addEventListener('mousedown', function (e) {
      if (!isOpen()) { return; }
      if (panel.box.contains(e.target) || e.target.closest('a[data-rin="bell"]')) { return; }
      closePanel();
    });

    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && isOpen()) { closePanel(); }
    });

    window.addEventListener('resize', function () {
      if (isOpen()) { positionPanel(); }
    });

    /* Prútik AI asistenta sa môže do hlavičky dostať až po nás — poradie sa preto
     * ešte raz overí, keď sa `#top-menu` zmení. Observer sa po prvom úspechu odpojí,
     * aby nevisel na stránke zbytočne. */
    var topMenu = document.getElementById('top-menu');
    if (topMenu && !wandLink()) {
      var obs = new MutationObserver(function () {
        if (wandLink()) {
          ensureOrder();
          obs.disconnect();
        }
      });
      obs.observe(topMenu, { childList: true, subtree: true });
      setTimeout(function () { obs.disconnect(); }, 5000);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
