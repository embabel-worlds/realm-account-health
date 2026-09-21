/*
 * UI smoke test for the Account Signals app — what the view harness cannot check.
 *
 * `tests/verify.sh` proves every view answers when called BY NAME. This proves the PAGE:
 * that the CRM notice is absent, that the map is capped and says so, that a dot carries a
 * label that distinguishes it, and that nothing throws. Each assertion here exists because
 * the thing it checks was broken on 2026-09-21 and was invisible to verify.sh.
 *
 *   AH_USER=<you> AH_PASS=<your password> node tests/ui-smoke.js
 *
 * Only the account created during appliance setup can sign in; there is no default login.
 * Set AH_URL to point somewhere other than the local appliance.
 */
const path = require('path');
async function loadPlaywright() {
  const { execSync } = require('child_process');
  const cands = [];
  for (const m of ['playwright', 'playwright-core']) {
    try { cands.push(require.resolve(m)); } catch (e) { /* not here */ }
  }
  try {
    const found = execSync(
      "find \"$HOME/.npm/_npx\" \"$HOME/dev\" -maxdepth 6 -type d -name playwright -path '*node_modules*' 2>/dev/null",
      { encoding: 'utf8' }).trim().split('\n').filter(Boolean);
    cands.push(...found);
  } catch (e) { /* none */ }
  // TRY TO LAUNCH, do not merely check `executablePath()`. Several copies of playwright can
  // be on one machine, each pinned to a different browser build, and `executablePath()`
  // reports the HEADED binary while a headless launch needs `chromium_headless_shell` —
  // which a given copy may not have downloaded. Checking the path finds a module that loads
  // and then dies at launch, which reads as a failure of the app rather than of the harness.
  for (const c of cands) {
    try {
      const pw = require(c);
      const b = await pw.chromium.launch();
      await b.close();
      return pw;
    } catch (e) { /* try the next */ }
  }
  console.error('No playwright with a working chromium was found.');
  console.error('Install one:  npm i -D playwright && npx playwright install chromium');
  process.exit(4);
}

const APP = process.env.AH_URL || 'http://127.0.0.1:11043/apps/account-health/account-signals.html';
const [USER, PASS] = [process.env.AH_USER, process.env.AH_PASS];
const pass = [], fail = [], warn = [];
const ok  = (n, c, d) => (c ? pass : fail).push(`${c?'PASS':'FAIL'}: ${n}${d?` — ${d}`:''}`);

(async () => {
  const { chromium } = await loadPlaywright();
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1440, height: 1000 } });
  const errors = [];
  p.on('console', m => { if (m.type() === 'error') errors.push(m.text().slice(0,160)); });
  p.on('pageerror', e => errors.push('PAGEERROR ' + e.message.slice(0,160)));

  await p.goto(APP, { waitUntil: 'networkidle' });
  if (p.url().includes('/ui/login')) {
    await p.fill('#username', USER); await p.fill('#password', PASS);
    await p.click('button[type=submit]');
    // The login posts via fetch; wait for the URL to leave /ui/login rather than for a nav event.
    await p.waitForFunction(() => !location.pathname.includes('/ui/login'), { timeout: 60000 })
           .catch(() => {});
    await p.waitForTimeout(2000);
    if (!p.url().includes('account-signals')) await p.goto(APP, { waitUntil:'networkidle' });
  }
  if (p.url().includes('/ui/login')) {
    const msg = await p.innerText('body').catch(()=>'')
    console.error('\nCOULD NOT SIGN IN. ' + (/Incorrect/i.test(msg) ? 'The appliance rejected those credentials.' : 'Still on the login page.'));
    console.error('Only the account created during setup can sign in. Re-run with:');
    console.error('  AH_USER=<you> AH_PASS=<your password> node ' + __filename + '\n');
    await b.close(); process.exit(3);
  }
  ok('app loads (not the login page)', true, p.url());

  // The page reads 13 views one after another; wait for the lane counts to stop being placeholders.
  try {
    await p.waitForFunction(() => {
      const t = document.getElementById('bad-count');
      return t && t.textContent.trim() !== '' && t.textContent.trim() !== '–';
    }, { timeout: 240000 });
  } catch (e) { warn.push('lane counts did not settle within 240s'); }
  await p.waitForTimeout(4000);

  const badCount  = await p.innerText('#bad-count').catch(()=>'?').then(t=>t.trim());
  const goodCount = await p.innerText('#good-count').catch(()=>'?').then(t=>t.trim());

  // 1. THE CRM FAILURE NOTICE must be gone.
  const body = await p.innerText('body');
  const crmFailed = /did not answer/i.test(body);
  ok('no "did not answer" notice', !crmFailed,
     crmFailed ? body.split('\n').find(l => /did not answer/i.test(l)).slice(0,160) : 'CRM answered');

  // 2. THE MAP CAP: at most 20 dots per lane => 40 total.
  const dots = await p.$$eval('#mapsvg g.dot', g => g.length);
  ok('map draws at most 40 dots (20/lane)', dots <= 40, `${dots} dots; lanes: bad=${badCount} good=${goodCount}`);
  ok('map actually drew dots', dots > 0, `${dots}`);

  // 3. THE CAP IS DISCLOSED when there is more than fits.
  const cap = (await p.innerText('#mapcap').catch(() => '')).trim();
  ok('legend discloses the cap', /top 20 of each/.test(cap) || dots < 40, cap || '(empty — nothing withheld)');

  // 4. DOT LABELS: not every label is the bare word "Account".
  const labels = await p.$$eval('#mapsvg text.n', t => t.map(x => x.textContent.trim()));
  const bare = labels.filter(l => l === 'Account').length;
  ok('dot labels are not all the bare word "Account"', bare === 0,
     `${labels.length} labels, ${bare} bare; e.g. ${JSON.stringify(labels.slice(0,5))}`);

  // 5. DRAWER: clicking a dot opens an account with CRM notes present.
  if (dots > 0) {
    await p.click('#mapsvg g.dot');
    await p.waitForTimeout(2500);
    const txt = await p.innerText('body');
    ok('clicking a dot opens the account drawer', /at stake|reason|case|invoice/i.test(txt));
  }

  // 6. No JS errors.
  ok('no uncaught JS errors', errors.length === 0, errors.slice(0,3).join(' | ') || 'clean');

  const out = process.env.AH_OUT || require('os').tmpdir();
  await p.screenshot({ path: path.join(out, 'ui-full.png'), fullPage: false });
  await p.locator('#mapwrap').screenshot({ path: path.join(out, 'ui-map.png') }).catch(()=>{});
  console.log('screenshots: ' + out);

  console.log(pass.concat(fail).join('\n'));
  if (warn.length) console.log('WARN: ' + warn.join('; '));
  console.log(`\n${pass.length} passed, ${fail.length} failed`);
  await b.close();
  process.exit(fail.length ? 1 : 0);
})().catch(e => { console.error('ERR', e.message); process.exit(2); });
