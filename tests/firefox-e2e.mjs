// Real isolated Firefox extension → native host → Current service → file checks.
// No user profile is opened; per-user host manifests are restored in finally.
import {firefox} from 'playwright';
import {spawn, execFileSync} from 'node:child_process';
import {mkdtemp, readFile, writeFile, mkdir, rm, chmod, stat} from 'node:fs/promises';
import {tmpdir, homedir} from 'node:os';
import {resolve, join, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createServer, createConnection} from 'node:net';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const cli = process.env.CURRENT_TEST_CLI || join(root, '.build/debug/currentctl');
const directory = await mkdtemp(join(tmpdir(), 'current-firefox-e2e-'));
const state = join(directory, 'state');
const profile = join(directory, 'profile');
const env = {...process.env, CURRENT_STATE_DIR:state};
const extensionID = 'current@current-downloadmanager.local';
const extensionUUID = 'e2e6e3af-8c9a-4f11-8ac3-34d53b975001';
const hostName = 'io.current.downloadmanager';
const manifestFolders = ['Google/Chrome', 'Google/Chrome Canary', 'Google/Chrome for Testing', 'Chromium', 'Microsoft Edge', 'BraveSoftware/Brave-Browser', 'Mozilla'];
const backups = new Map();
let fixture, service, context, debuggerClient;
let diagnostics = '';
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const sha256 = value => createHash('sha256').update(value).digest('hex');
async function until(fn, label, timeout = 20000) {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    try { last = await fn(); if (last) return last; } catch (error) { last = error.message; }
    await delay(100);
  }
  throw new Error(`Timed out: ${label}; last=${JSON.stringify(last)}`);
}
async function stop(child) {
  if (!child || child.exitCode !== null) return;
  child.kill('SIGTERM');
  await Promise.race([new Promise(resolve => child.once('exit', resolve)), delay(7000)]);
  if (child.exitCode === null) child.kill('SIGKILL');
}
async function availableLoopbackPort() {
  const server = createServer();
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}

async function launchFirefoxWithBrowserDownloads(profile, options) {
  // Playwright's download interception replaces Firefox's real filename with a
  // GUID. Filename-filter tests need the ordinary browser download manager.
  // Its protocol supports this mode, but the public boolean option cannot
  // express it. Scope the protocol override to this launch and restore it.
  const channel = firefox._channel;
  assert.equal(typeof channel?.launchPersistentContext, 'function');
  firefox._channel = new Proxy(channel, {
    get(target, property) {
      if (property === 'launchPersistentContext') {
        return (params, ...rest) => target.launchPersistentContext({...params, acceptDownloads:'internal-browser-default'}, ...rest);
      }
      return Reflect.get(target, property);
    }
  });
  try { return await firefox.launchPersistentContext(profile, options); }
  finally { firefox._channel = channel; }
}

// Firefox's supported DevTools add-on actor is the temporary-install mechanism
// used by web-ext. Permanent unsigned installation is rejected by this build.
async function installTemporaryAddon(port, addonPath) {
  const socket = await until(() => new Promise((resolve, reject) => {
    const connection = createConnection({host:'127.0.0.1', port});
    connection.once('connect', () => resolve(connection));
    connection.once('error', error => { connection.destroy(); reject(error); });
  }), 'Firefox loopback DevTools server');
  let buffer = Buffer.alloc(0);
  const packets = [], pending = [];
  function nextPacket() {
    if (packets.length) return Promise.resolve(packets.shift());
    return new Promise((resolve, reject) => {
      const waiter = {resolve, reject};
      const timer = setTimeout(() => {
        const at = pending.indexOf(waiter); if (at >= 0) pending.splice(at, 1);
        reject(new Error('Firefox DevTools packet timed out'));
      }, 15000);
      waiter.resolve = value => { clearTimeout(timer); resolve(value); };
      waiter.reject = error => { clearTimeout(timer); reject(error); };
      pending.push(waiter);
    });
  }
  function send(value) {
    const json = JSON.stringify(value);
    socket.write(`${Buffer.byteLength(json)}:${json}`);
  }
  socket.on('data', data => {
    buffer = Buffer.concat([buffer, data]);
    while (true) {
      const colon = buffer.indexOf(58);
      if (colon < 0) return;
      const length = Number(buffer.subarray(0, colon).toString());
      if (!Number.isSafeInteger(length) || length < 0 || length > 16 * 1024 * 1024) { socket.destroy(new Error('Invalid Firefox DevTools framing')); return; }
      if (buffer.length < colon + 1 + length) return;
      const packet = JSON.parse(buffer.subarray(colon + 1, colon + 1 + length).toString());
      buffer = buffer.subarray(colon + 1 + length);
      if (pending.length) pending.shift().resolve(packet); else packets.push(packet);
    }
  });
  socket.on('error', error => { for (const waiter of pending.splice(0)) waiter.reject(error); });
  const events = [];
  async function matching(predicate) {
    const saved = events.findIndex(predicate);
    if (saved >= 0) return events.splice(saved, 1)[0];
    while (true) {
      const packet = await nextPacket();
      if (predicate(packet)) return packet;
      events.push(packet);
    }
  }
  async function request(actor, type, values = {}) {
    send({to:actor, type, ...values});
    const reply = await matching(packet => packet.from === actor && !packet.type);
    if (reply.error) throw new Error(`Firefox DevTools ${type}: ${reply.error}: ${reply.message}`);
    return reply;
  }
  try {
    await nextPacket(); // Root greeting.
    const root = await request('root', 'getRoot');
    if (!root.addonsActor) throw new Error(`Firefox DevTools did not expose its add-on actor: ${JSON.stringify(root)}`);
    const installed = await request(root.addonsActor, 'installTemporaryAddon', {addonPath, openDevTools:false});
    assert.equal(installed.addon?.id, extensionID, JSON.stringify(installed));
    const list = await request('root', 'listAddons');
    const descriptor = list.addons.find(addon => addon.id === extensionID);
    assert.ok(descriptor, 'Temporary extension is listed by real Firefox');
    const watcher = await request(descriptor.actor, 'getWatcher', {isServerTargetSwitchingEnabled:true});
    const watcherID = watcher.actor || watcher.watcher?.actor;
    if (!watcherID) throw new Error(`Firefox watcher unavailable: ${JSON.stringify(watcher)}`);
    await request(watcherID, 'watchTargets', {targetType:'frame'});
    const target = await matching(packet => packet.type === 'target-available-form' && packet.target?.consoleActor && packet.target.url?.startsWith('moz-extension://'));
    const consoleActor = target.target.consoleActor;
    async function evaluateRaw(text) {
      const response = await request(consoleActor, 'evaluateJSAsync', {text});
      const result = await matching(packet => packet.type === 'evaluationResult' && packet.resultID === response.resultID && (packet.hasException || typeof packet.result === 'string' || packet.result?.type === 'longString'));
      if (result.hasException) throw new Error(`Firefox extension evaluation: ${result.exceptionMessage}`);
      if (result.result?.type === 'longString') {
        const full = await request(result.result.actor, 'substring', {start:0, end:result.result.length});
        return JSON.parse(full.substring);
      }
      return JSON.parse(result.result);
    }
    return {
      close:() => socket.destroy(),
      async evaluate(body) {
        // The raw console actor does not rewrite top-level await as DevTools UI
        // does. Resolve async browser APIs inside the actual extension global.
        await evaluateRaw(`globalThis.__currentE2E = {pending:true}; (async () => { try { globalThis.__currentE2E = {value:await (async () => { ${body} })()}; } catch (error) { globalThis.__currentE2E = {error:error.message}; } })(); JSON.stringify(true);`);
        const settled = await until(async () => {
          const value = await evaluateRaw('JSON.stringify(globalThis.__currentE2E)');
          return value.pending ? null : value;
        }, 'Firefox extension asynchronous evaluation');
        if (settled.error) throw new Error(`Firefox extension evaluation: ${settled.error}`);
        return settled.value;
      }
    };

  } catch (error) { socket.destroy(); throw error; }
}

async function extensionDiagnostics() {
  try {
    const registry = JSON.parse(await readFile(join(profile, 'extensions.json'), 'utf8'));
    const entry = registry.addons?.find(addon => addon.id === extensionID);
    return JSON.stringify(entry ? {id:entry.id, active:entry.active, appDisabled:entry.appDisabled, userDisabled:entry.userDisabled, signedState:entry.signedState, path:entry.path} : {extensionRegistered:false});
  } catch (error) { return `Extension registry unavailable: ${error.message}`; }
}
try {
  fixture = spawn('python3', ['-u', join(root, 'tests/fixture.py')], {stdio:['ignore', 'pipe', 'pipe']});
  let fixtureURL = '';
  fixture.stdout.on('data', data => { fixtureURL += data.toString(); });
  fixture.stderr.on('data', data => { diagnostics += `Fixture: ${data}`; });
  fixture.on('error', error => { diagnostics += `Fixture process: ${error.message}\n`; });
  await until(() => fixtureURL.includes('\n'), 'fixture readiness');
  fixtureURL = fixtureURL.trim();

  service = spawn(cli, ['serve'], {env, stdio:['ignore', 'pipe', 'pipe']});
  service.stdout.on('data', data => { diagnostics += data; });
  service.stderr.on('data', data => { diagnostics += data; });
  const descriptor = await until(async () => JSON.parse(await readFile(join(state, 'bridge.json'), 'utf8')), 'Current engine readiness');
  async function command(action, values = {}) {
    const response = await fetch(`http://127.0.0.1:${descriptor.port}/v1/command`, {
      method:'POST', headers:{'Content-Type':'application/json', Authorization:`Bearer ${descriptor.token}`}, body:JSON.stringify({action, ...values})
    });
    const body = await response.json();
    assert.equal(body.ok, true, JSON.stringify(body));
    return body.result;
  }
  await command('settings', {settings:{downloadDirectory:join(directory, 'files')}});
  for (const folder of manifestFolders) {
    const path = join(homedir(), 'Library/Application Support', folder, 'NativeMessagingHosts', `${hostName}.json`);
    const data = await readFile(path).catch(() => null);
    backups.set(path, data ? {data, mode:(await stat(path)).mode & 0o777} : null);
  }
  execFileSync(cli, ['install-browser-host'], {env, stdio:'pipe'});
  await mkdir(join(profile, 'extensions'), {recursive:true});
  const xpi = join(directory, 'current-firefox.xpi');
  execFileSync('zip', ['-qr', xpi, '.'], {cwd:join(root, 'extensions/firefox'), stdio:'pipe'});
  const debuggerPort = await availableLoopbackPort();
  // Firefox's Playwright protocol applies firefoxUserPrefs after startup. The add-on
  // scanner and UUID allocation need these preferences before the process starts.
  const preferences = {
    'xpinstall.signatures.required':false,
    'devtools.debugger.remote-enabled':true,
    'devtools.debugger.prompt-connection':false,
    'devtools.debugger.force-local':true,
    'devtools.chrome.enabled':true,
    'extensions.autoDisableScopes':0,
    'extensions.enabledScopes':15,
    'extensions.startupScanScopes':15,
    'extensions.webextensions.uuids':JSON.stringify({[extensionID]:extensionUUID}),
    'browser.download.useDownloadDir':true,
    'browser.download.folderList':2,
    'browser.download.dir':join(directory, 'browser-downloads'),
    'browser.helperApps.neverAsk.saveToDisk':'application/octet-stream'
  };
  await writeFile(join(profile, 'user.js'), Object.entries(preferences).map(([key, value]) => `user_pref(${JSON.stringify(key)}, ${JSON.stringify(value)});`).join('\n') + '\n');
  await mkdir(join(directory, 'browser-downloads'), {recursive:true});
  context = await launchFirefoxWithBrowserDownloads(profile, {
    headless:process.env.CURRENT_BROWSER_HEADLESS !== '0', env,
    args:['-start-debugger-server', String(debuggerPort)],
    firefoxUserPrefs:preferences
  });
  debuggerClient = await installTemporaryAddon(debuggerPort, xpi);
  const evaluate = body => debuggerClient.evaluate(body);
  const page = context.pages()[0] || await context.newPage();
  await page.goto(`${fixtureURL}/page`);
  // Juggler cannot attach to moz-extension documents. Use Firefox's ordinary
  // extension debugger to click the actual popup DOM; Playwright drives websites.
  await evaluate('await browser.tabs.create({url:browser.runtime.getURL("popup.html")}); return true;');
  const popupExpression = 'browser.extension.getViews({type:"tab"}).find(view => view.location.pathname === "/popup.html")';
  assert.equal(await evaluate('return browser.runtime.id;'), extensionID);
  assert.equal(await evaluate('return (await browser.runtime.sendNativeMessage("io.current.downloadmanager", {action:"status"})).ok;'), true);
  await until(() => evaluate(`return ${popupExpression}?.document.getElementById("connection")?.textContent.includes("Connected") || false;`), 'Firefox actual popup connection');
  await evaluate(`const popup = ${popupExpression}; popup.document.getElementById("urls").value = ${JSON.stringify(fixtureURL + '/tiny.bin')}; popup.document.getElementById("add-button").click(); return true;`);
  const manual = await until(async () => (await command('status')).jobs.find(job => job.filename === 'tiny.bin' && job.status === 'complete'), 'Firefox popup download completion');
  const tinyHash = sha256(Buffer.from('Current fixture\n'.repeat(4096)));
  assert.equal(sha256(await readFile(join(manual.directory, manual.filename))), tinyHash);

  await evaluate(`const popup = ${popupExpression}; const capture = popup.document.getElementById("capture"); if (!capture.checked) capture.click(); return true;`);
  await until(() => evaluate('return (await browser.storage.local.get("captureEnabled")).captureEnabled === true;'), 'Firefox capture opt-in persistence');
  await evaluate('globalThis.__currentDownloads = []; browser.downloads.onCreated.addListener(item => globalThis.__currentDownloads.push({event:"created", id:item.id, state:item.state, url:item.url, finalUrl:item.finalUrl,filename:item.filename,paused:item.paused})); browser.downloads.onChanged.addListener(delta => globalThis.__currentDownloads.push({event:"changed", ...delta})); browser.downloads.onErased.addListener(id => globalThis.__currentDownloads.push({event:"erased", id})); return true;');
  await evaluate('globalThis.__currentCaptureEvents = []; browser.webRequest.onBeforeRequest.addListener(details => { globalThis.__currentCaptureEvents.push({event:"request", method:details.method, tab:details.tabId,url:details.url, at:Date.now()}); }, {urls:["http://*/*"]}); browser.webRequest.onHeadersReceived.addListener(details => { globalThis.__currentCaptureEvents.push({event:"headers",method:details.method,tab:details.tabId,url:details.url,at:Date.now()}); }, {urls:["http://*/*"]}); browser.tabs.onUpdated.addListener((tab,change) => { if (change.status) globalThis.__currentCaptureEvents.push({event:"tab", tab, status:change.status, at:Date.now()}); }); browser.downloads.onCreated.addListener(item => globalThis.__currentCaptureEvents.push({event:"download", id:item.id, url:item.url, at:Date.now()})); return true;');
  await page.bringToFront();
  await page.locator('#download').click();
  const captured = await until(async () => (await command('status')).jobs.find(job => job.request.urls[0] === `${fixtureURL}/slow.bin`), 'Firefox automatic download handoff');
  await until(async () => (await command('status')).jobs.some(job => job.id === captured.id && job.status === 'complete'), 'Firefox captured download completion', 30000);
  const large = await readFile(join(captured.directory, captured.filename));
  const expected = Buffer.alloc(12 * 1024 * 1024);
  for (let offset = 0; offset < expected.length; offset++) expected[offset] = offset & 255;
  const largeHash = sha256(expected);
  assert.equal(large.length, expected.length);
  assert.equal(sha256(large), largeHash);
  const browserDownloads = await evaluate('return (await browser.downloads.search({})).map(({url,state}) => ({url,state}));');
  const downloadEvents = await evaluate('return globalThis.__currentDownloads;');
  const browserItem = downloadEvents.find(event => event.event === 'created' && event.url.endsWith('/slow.bin'));
  assert.ok(browserItem, 'Firefox exposed the real browser download to the extension');
  const interrupted = downloadEvents.some(event => event.id === browserItem.id && event.state?.current === 'interrupted');
  const erased = downloadEvents.some(event => event.id === browserItem.id && event.event === 'erased');
  assert.ok(browserDownloads.some(download => download.url.endsWith('/slow.bin') && download.state === 'interrupted') || interrupted && erased, 'Firefox browser copy is interrupted and no longer runs');
  assert.equal(await evaluate('return (await browser.storage.local.get("lastError")).lastError || null;'), null, 'Already-erased Firefox download does not leave a false error badge');

  await context.addCookies([{name:'session', value:'fixture', url:fixtureURL, httpOnly:true, sameSite:'Lax'}]);
  await page.locator('#cookie-download').click();
  const authenticated = await until(async () => (await command('status')).jobs.find(job => job.request.urls[0] === `${fixtureURL}/cookie-slow.bin`), 'Firefox authenticated handoff');
  await until(async () => (await command('status')).jobs.some(job => job.id === authenticated.id && job.status === 'complete'), 'Firefox cookie/referer download completion', 30000);
  assert.equal(sha256(await readFile(join(authenticated.directory, authenticated.filename))), largeHash);

  // Download navigation can invalidate the per-tab cache; a real page reload
  // must discover the DOM/network source again in the current document.
  await page.goto(`${fixtureURL}/page`);
  const media = await until(() => evaluate(`
    const target = (await browser.tabs.query({})).find(tab => tab.url?.endsWith('/page'));
    const popup = ${popupExpression};
    const snapshot = await popup.browser.runtime.sendMessage({action:'snapshot', tabId:target?.id});
    return snapshot?.media?.find(entry => entry.url.endsWith('/video.mp4')) || null;
  `), 'Firefox page media discovery');
  assert.ok(media.url.endsWith('/video.mp4'));

  await evaluate(`const popup = ${popupExpression}; popup.document.getElementById("capture-settings").click(); return true;`);
  const optionsExpression = 'browser.extension.getViews({type:"tab"}).find(view => view.location.pathname === "/options.html")';
  await until(() => evaluate(`return ${optionsExpression}?.document.getElementById("save-settings")?.disabled === false;`), 'Firefox actual capture settings ready');
  async function savePolicy({fileTypes = [], excludedDomains = [], excludedURLPatterns = []} = {}) {
    const policy = {fileTypes, excludedDomains, excludedURLPatterns};
    await evaluate(`const view = ${optionsExpression}; view.document.getElementById("file-types").value = ${JSON.stringify(fileTypes.join(', '))}; view.document.getElementById("excluded-domains").value = ${JSON.stringify(excludedDomains.join('\n'))}; view.document.getElementById("excluded-url-patterns").value = ${JSON.stringify(excludedURLPatterns.join('\n'))}; view.document.getElementById("save-settings").click(); return true;`);
    await until(async () => {
      const saved = await evaluate('return (await browser.storage.local.get("capturePolicy")).capturePolicy;');
      assert.deepEqual(saved, policy);
      return true;
    }, 'Firefox capture rules persisted');
    await until(() => evaluate(`return ${optionsExpression}.document.getElementById("settings-feedback").textContent === "Capture rules saved.";`), 'Firefox save feedback');
    assert.equal(await evaluate(`return ${optionsExpression}.document.getElementById("settings-error").hidden;`), true);
  }
  const policyBytes = Buffer.from(Array.from({length:2 * 1024 * 1024}, (_, index) => index & 255));
  const policyHash = sha256(policyBytes);
  async function staysInBrowser(selector, path, clickOptions) {
    await page.bringToFront();
    // Ordinary Firefox downloads do not emit Playwright's intercepted-download
    // navigation signal. Wait for browser.downloads completion below instead.
    await page.locator(selector).click({noWaitAfter:true, ...clickOptions});
    const download = await until(() => evaluate(`return (await browser.downloads.search({})).find(item => item.url === ${JSON.stringify(fixtureURL + path)} && item.state === 'complete') || null;`), `${path} completes in Firefox`);
    assert.ok(download.filename.endsWith(path), 'Firefox preserves the server filename for capture filtering');
    assert.equal(sha256(await readFile(download.filename)), policyHash);
    assert.equal((await command('status')).jobs.some(job => job.request.urls[0] === fixtureURL + path), false, `${path} never becomes a native job`);
    // Clear Juggler's pending download navigation before its next locator
    // action; browser-default downloads have no intercepted-download signal.
    await page.goto(`${fixtureURL}/page`);
  }
  await savePolicy({fileTypes:['zip']});
  await staysInBrowser('#policy-type', '/policy-type.bin');
  await savePolicy({fileTypes:['bin'], excludedDomains:['127.0.0.1']});
  await staysInBrowser('#policy-domain', '/policy-domain.bin');
  await savePolicy({fileTypes:['bin'], excludedURLPatterns:[fixtureURL + '/policy-pattern*']});
  await staysInBrowser('#policy-pattern', '/policy-pattern.bin');
  await evaluate(`const view = ${optionsExpression}; view.document.getElementById("excluded-domains").value = "https://invalid.example/path"; view.document.getElementById("save-settings").click(); return true;`);
  await until(() => evaluate(`return ${optionsExpression}.document.getElementById("settings-error").hidden === false;`), 'Firefox invalid settings error visible');
  assert.deepEqual(await evaluate('return (await browser.storage.local.get("capturePolicy")).capturePolicy.excludedDomains;'), [], 'malformed settings preserve saved rules');
  await evaluate(`const popup = ${popupExpression}; popup.document.getElementById("urls").value = ${JSON.stringify(fixtureURL + '/policy-pattern.bin')}; popup.document.getElementById("add-button").click(); return true;`);
  const explicit = await until(async () => (await command('status')).jobs.find(job => job.request.urls[0] === fixtureURL + '/policy-pattern.bin' && job.status === 'complete'), 'Firefox manual excluded URL completes');
  assert.equal(sha256(await readFile(join(explicit.directory, explicit.filename))), policyHash);
  await savePolicy({fileTypes:['bin']});
  // Firefox on macOS suppresses normal navigation for Alt-click even with no
  // extension installed. Give this fixture a site-owned navigation handler so
  // a real trusted Alt-click still starts the download and exercises the bypass.
  await page.locator('#policy-alt').evaluate(anchor => anchor.addEventListener('click', event => {
    if (event.isTrusted && event.altKey) { event.preventDefault(); location.assign(anchor.href); }
  }));
  await staysInBrowser('#policy-alt', '/policy-alt.bin', {modifiers:['Alt']});
  await staysInBrowser('#policy-post', '/policy-post.bin');
  await page.locator('#policy-allowed').click();
  const allowed = await until(async () => (await command('status')).jobs.find(job => job.request.urls[0] === fixtureURL + '/policy-allowed.bin' && job.status === 'complete'), 'Firefox included browser download completes');
  assert.equal(sha256(await readFile(join(allowed.directory, allowed.filename))), policyHash);
  const userAgent = await page.evaluate(() => navigator.userAgent);
  assert.equal(allowed.request.headers['User-Agent'], userAgent, 'Firefox-created native requests carry its real User-Agent');
  const policyRequests = (await (await fetch(fixtureURL + '/stats')).json()).filter(entry => entry.path === '/policy-allowed.bin');
  assert.ok(policyRequests.length >= 2);
  assert.ok(policyRequests.every(entry => entry.userAgent === userAgent), 'the fixture observes the Firefox User-Agent on native network requests');
  await page.evaluate(() => {
    const anchor = document.getElementById('policy-synthetic');
    // A site's own handler can navigate after an untrusted click. It still
    // must not gain the extension's trusted Alt-click bypass privilege.
    anchor.addEventListener('click', event => { event.preventDefault(); location.assign(anchor.href); });
    anchor.dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true, altKey:true, button:0}));
  });
  const synthetic = await until(async () => (await command('status')).jobs.find(job => job.request.urls[0] === fixtureURL + '/policy-synthetic.bin' && job.status === 'complete'), 'Firefox synthetic Alt event cannot forge bypass');
  assert.equal(sha256(await readFile(join(synthetic.directory, synthetic.filename))), policyHash);

  console.log(JSON.stringify({
    browser:context.browser().version(), extensionID,
    passed:[
      'fixed Firefox identity and isolated temporary development XPI',
      'real Firefox native messaging connection',
      'popup URL → native host → byte-verified file',
      'opt-in automatic GET capture → native acceptance → byte-verified 12 MiB file; browser copy interrupted/removed',
      'HttpOnly cookie and referer handoff → authenticated byte-verified 12 MiB file',
      'DOM/network page media discovery',
      'actual options page persists capture rules and displays validation errors',
      'file-type, exact-domain, and URL-pattern exclusions retain byte-verified browser downloads',
      'manual excluded URL → native byte-verified file',
      'trusted Alt-click bypass retains browser download',
      'POST remains a byte-verified browser download',
      'included GET carries Firefox User-Agent through native network requests',
      'synthetic Alt-click cannot forge bypass'
    ], count:13, automation:{extensionPages:'Firefox DevTools RDP; actual popup DOM controls', website:'Playwright Firefox', browserCopyErasedAfterPause:erased}, hashes:{tiny:tinyHash, large:largeHash}
  }, null, 2));
} catch (error) {
  if (debuggerClient) {
    try { console.error('Firefox capture diagnostics:', JSON.stringify(await debuggerClient.evaluate('return {events:globalThis.__currentCaptureEvents || [], downloads:globalThis.__currentDownloads || [], captureEnabled:(await browser.storage.local.get("captureEnabled")).captureEnabled, lastError:(await browser.storage.local.get("lastError")).lastError || null};'))); } catch (diagnosticError) { console.error(diagnosticError.message); }
  }
  console.error(diagnostics);
  console.error(await extensionDiagnostics());
  throw error;
} finally {
  debuggerClient?.close();
  await context?.close();
  await stop(service);
  await stop(fixture);
  for (const [path, backup] of backups) {
    if (backup) { await writeFile(path, backup.data); await chmod(path, backup.mode); }
    else await rm(path, {force:true});
  }
  await rm(directory, {recursive:true, force:true});
}
