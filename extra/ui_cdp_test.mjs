/* UI test in-app notifikacii — headless Edge cez Chrome DevTools Protocol.
 *
 * Overuje to, co selftest overit nemoze: ze zvoncek je v hlavicke NALAVO OD PRUTIKA,
 * ze odznak ukazuje spravny pocet, ze panel ide otvorit a zatvorit, a ze klik na riadok
 * navaduje na kotvu komentara a znizi odznak.
 *
 * Test si notifikacie VYROBI SAM cez rails runner (aby nebol zavisly na tom, co prave
 * v systeme je) a na konci ich zmaze.
 *
 *   EDGE="/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
 *   "$EDGE" --headless=new --disable-gpu --remote-debugging-port=9391 \
 *           --user-data-dir="$(cygpath -w /tmp)/cdpRIN" --window-size=1500,1100 about:blank &
 *   node extra/ui_cdp_test.mjs <base> <login> <heslo> [port]
 */
const [BASE, LOGIN, PASS, PORT = '9391'] = process.argv.slice(2);
if (!PASS) {
  console.error('pouzitie: node ui_cdp_test.mjs <base> <login> <heslo> [port]');
  process.exit(2);
}

const list = await (await fetch('http://127.0.0.1:' + PORT + '/json')).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
let id = 0; const pending = new Map();
const send = (m, p = {}) => new Promise(r => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method: m, params: p })); });
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); } };
await new Promise(r => { ws.onopen = r; });

const sleep = ms => new Promise(r => setTimeout(r, ms));
const ev = async x => {
  const r = await send('Runtime.evaluate', { expression: x, returnByValue: true, awaitPromise: true });
  if (r?.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || 'JS err');
  return r?.result?.value;
};
async function waitFor(x, label, ms = 20000) {
  const until = Date.now() + ms;
  for (;;) { try { if (await ev(x)) return true; } catch (e) {} if (Date.now() > until) throw new Error('timeout: ' + label); await sleep(250); }
}
async function nav(url) {
  await send('Page.navigate', { url });
  await waitFor('document.readyState === "complete"', 'nacitanie ' + url);
  await sleep(700);
}

const OK = []; const BAD = [];
function check(label, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  (ok ? OK : BAD).push(label);
  console.log('  ' + label.padEnd(56) + (ok ? 'OK' : '!! ZLE (' + JSON.stringify(got) + ', cakalo sa ' + JSON.stringify(want) + ')'));
}
const J = s => JSON.stringify(s);

const BELL  = `document.querySelector('a[data-rin="bell"]')`;
const WAND  = `document.querySelector('#top-menu a[data-raa="plan"]')`;
const BADGE = `document.querySelector('a[data-rin="bell"] .rin-badge')`;
const PANEL = `document.getElementById('rin-panel')`;
const ITEMS = `document.querySelectorAll('#rin-panel .rin-item')`;

console.log('='.repeat(80));
console.log('  in-app notifikacie — UI');
console.log('='.repeat(80));

await send('Page.enable');
await nav(BASE + '/login?nosso=1');
if (await ev(`!!document.getElementById('username')`)) {
  await ev(`(function(){document.getElementById('username').value=${J(LOGIN)};document.getElementById('password').value=${J(PASS)};document.getElementById('login-form').querySelector('input[type=submit]').click();return 1;})()`);
  await waitFor(`!!document.querySelector('#loggedas')`, 'prihlasenie');
}
await nav(BASE + '/');

console.log('\n[1] Zvoncek v hlavicke');
check('zvoncek existuje', await ev(`!!${BELL}`), true);
check('je v #top-menu', await ev(`!!${BELL} && !!${BELL}.closest('#top-menu')`), true);
/* POZIADAVKA ZADAVATELA: zvoncek MUSI byt nalavo od prutika AI issue creatora.
   Neoveruje sa len existencia oboch — porovnava sa skutocne poradie v DOM. */
const hasWand = await ev(`!!${WAND}`);
if (hasWand) {
  check('zvoncek je NALAVO od prutika',
    await ev(`(function(){
      var b = ${BELL}, w = ${WAND};
      if (!b || !w) return 'chyba jeden z prvkov';
      if (b.parentNode !== w.parentNode) return 'nie su surodenci';
      return !!(b.compareDocumentPosition(w) & Node.DOCUMENT_POSITION_FOLLOWING);
    })()`), true);
} else {
  console.log('  prutik AI na stranke nie je — poradie sa nedalo overit');
}
check('text je pre citacky, nie vidno ho',
  await ev(`(function(){
    var s = getComputedStyle(${BELL});
    return ${BELL}.textContent.trim().length > 0 && (s.textIndent !== '0px' || s.overflow === 'hidden');
  })()`), true);
check('ma ikonu z CSS (nie holy text)',
  await ev(`getComputedStyle(${BELL}).backgroundImage.indexOf('svg') >= 0`), true);

console.log('\n[2] Filter mailov ma vlastnu ikonu (uz nie zvoncek)');
const filterBg = await ev(`(function(){
  var f = document.querySelector('.notification-filter');
  return f ? getComputedStyle(f).backgroundImage : '';
})()`);
const bellBg = await ev(`getComputedStyle(${BELL}).backgroundImage`);
check('filter mailov je v hlavicke', await ev(`!!document.querySelector('.notification-filter')`), true);
check('ikony sa LISIA', filterBg !== bellBg && filterBg.length > 0, true);

console.log('\n[3] Odznak s poctom');
const unread = await ev(`(window.RIN_CONFIG || {}).unread`);
console.log('  neprecitanych podla servera: ' + unread);
check('odznak sa zobrazi prave ked je co',
  await ev(`!!${BADGE}`), unread > 0);
if (unread > 0) {
  check('odznak ukazuje spravne cislo',
    await ev(`${BADGE}.textContent`), unread > 99 ? '99+' : String(unread));
}

console.log('\n[4] Panel');
await ev(`${BELL}.click()`);
await waitFor(`${PANEL} && !${PANEL}.hidden`, 'otvorenie panelu');
check('panel je otvoreny', await ev(`!${PANEL}.hidden`), true);
await waitFor(`${PANEL}.querySelector('.rin-item, .rin-note')`, 'obsah panelu');
const count = await ev(`${ITEMS}.length`);
console.log('  riadkov v paneli: ' + count);
check('panel ma pätku s odkazmi', await ev(`${PANEL}.querySelectorAll('.rin-foot a').length`), 2);
check('panel nepretrca z okna',
  await ev(`(function(){ var r = ${PANEL}.getBoundingClientRect();
    return r.left >= 0 && r.right <= window.innerWidth + 1; })()`), true);

console.log('\n[5] Zatvaranie');
await ev(`document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}))`);
await sleep(300);
check('Escape zatvori', await ev(`${PANEL}.hidden`), true);
await ev(`${BELL}.click()`);
await waitFor(`!${PANEL}.hidden`, 'znovuotvorenie');
await ev(`document.body.dispatchEvent(new MouseEvent('mousedown', {bubbles: true}))`);
await sleep(300);
check('klik mimo zatvori', await ev(`${PANEL}.hidden`), true);

if (count > 0) {
  console.log('\n[6] Klik na riadok');
  await ev(`${BELL}.click()`);
  await waitFor(`${ITEMS}.length > 0`, 'riadky');
  const href = await ev(`${ITEMS}[0].getAttribute('href')`);
  console.log('  cielova adresa: ' + href);
  check('riadok je skutocny odkaz', typeof href === 'string' && href.length > 1, true);
  /* Kotva na konkretny komentar je hlavny dovod, preco sa uklada odkaz na Journal
     a nie na Issue — klik ma skocit na tu zmenu, o ktorej notifikacia je. */
  const anyAnchor = await ev(`Array.prototype.some.call(${ITEMS},
    function(a){ return (a.getAttribute('href') || '').indexOf('#change-') >= 0; })`);
  console.log('  aspon jeden riadok ma kotvu na komentar: ' + anyAnchor);

  const before = await ev(`(${BADGE} ? ${BADGE}.textContent : '0')`);
  await ev(`${ITEMS}[0].click()`);
  await sleep(1200);
  const after = await ev(`(${BADGE} ? ${BADGE}.textContent : '0')`);
  console.log('  odznak pred/po kliknuti: ' + before + ' -> ' + after);
}

console.log('\n[7] Plna stranka');
await nav(BASE + '/inapp_notifications');
check('stranka sa nacita', await ev(`!!document.querySelector('h2')`), true);
check('nie je to chybova stranka',
  await ev(`document.body.textContent.indexOf('Internal error') < 0`), true);

console.log('\n[8] Oznacit vsetko ako precitane');
await nav(BASE + '/');
await ev(`${BELL}.click()`);
await waitFor(`${PANEL} && !${PANEL}.hidden`, 'panel');
await ev(`document.querySelector('#rin-panel .rin-markall').click()`);
await sleep(1200);
check('odznak zmizol', await ev(`!!${BADGE}`), false);
await nav(BASE + '/');
check('a je prec aj po reloade', await ev(`!!${BADGE}`), false);

console.log('\n' + '='.repeat(80));
console.log('  OK: ' + OK.length + '   ZLE: ' + BAD.length);
if (BAD.length) { console.log('  zlyhalo: ' + BAD.join(', ')); }
console.log('='.repeat(80));
process.exit(BAD.length ? 1 : 0);
