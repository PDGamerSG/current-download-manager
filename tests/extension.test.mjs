import test from 'node:test';
import assert from 'node:assert/strict';
import {
  normalizeURL, normalizeURLs, cookieHeader, requestForURL,
  detectMedia, mergeMedia, handoffBrowserDownload
} from '../extensions/shared/core.mjs';

test('accepts explicit network URLs and removes fragments', () => {
  assert.equal(normalizeURL(' https://example.com/file.zip#chapter '), 'https://example.com/file.zip');
  assert.equal(normalizeURL('ftp://example.com/file.zip'), 'ftp://example.com/file.zip');
  assert.equal(normalizeURL('sftp://example.com/file.zip'), 'sftp://example.com/file.zip');
});

test('rejects browser-only, executable, malformed, and credential URLs', () => {
  for (const url of ['blob:https://example.com/id', 'data:text/plain,a', 'javascript:alert(1)', 'file:///tmp/a', 'chrome-extension://abc/a', 'https://user:pass@example.com/a', 'https://example.com/a\r\nCookie:secret', '/relative', 'https://']) {
    assert.equal(normalizeURL(url), null, url);
  }
});

test('batches preserve distinct query URLs and remove duplicate fragments', () => {
  assert.deepEqual(normalizeURLs(['https://example.com/a?a=1#x', 'https://example.com/a?a=1#y', 'https://example.com/a?a=2', 'data:text/plain,x']), ['https://example.com/a?a=1', 'https://example.com/a?a=2']);
});

test('cookie selection follows destination domain, path, and secure scope', () => {
  const cookies = [
    { name:'session', value:'one', domain:'files.example.com', hostOnly:true, path:'/', secure:true },
    { name:'parent', value:'two', domain:'.example.com', hostOnly:false, path:'/private', secure:false },
    { name:'sibling', value:'secret', domain:'login.example.com', hostOnly:true, path:'/', secure:true },
    { name:'spoof', value:'secret', domain:'evil-example.com', hostOnly:false, path:'/', secure:false },
    { name:'otherPath', value:'secret', domain:'files.example.com', hostOnly:true, path:'/privately', secure:false }
  ];
  assert.equal(cookieHeader('https://files.example.com/private/a', cookies), 'parent=two; session=one');
  assert.equal(cookieHeader('http://files.example.com/private/a', cookies), 'parent=two');
  assert.equal(cookieHeader('https://other.example.net/private/a', cookies), '');
  assert.equal(cookieHeader('chrome-extension://files.example.com/private/a', cookies), '');
});

test('unsafe cookie values cannot inject request headers', () => {
  const cookies = [{ name:'ok', value:'yes', domain:'example.com', path:'/' }, { name:'bad', value:'x\r\nInjected: true', domain:'example.com', path:'/' }];
  assert.equal(cookieHeader('https://example.com/a', cookies), 'ok=yes');
});

test('each download retrieves cookies for its own URL and limits cross-origin referer', async () => {
  const lookups = [];
  const getCookies = async ({ url }) => { lookups.push(url); return [{ name:'token', value:new URL(url).hostname, domain:new URL(url).hostname, hostOnly:true, path:'/' }]; };
  const one = await requestForURL('https://cdn.example.com/video.mp4', { pageURL:'https://www.example.com/account?secret=1', getCookies });
  const two = await requestForURL('https://other.net/file.zip', { pageURL:'chrome-extension://abc/popup.html', getCookies });
  assert.deepEqual(lookups, ['https://cdn.example.com/video.mp4', 'https://other.net/file.zip']);
  assert.deepEqual(one, { urls:['https://cdn.example.com/video.mp4'], headers:{ Cookie:'token=cdn.example.com', Referer:'https://www.example.com/' }, kind:'file' });
  assert.deepEqual(two, { urls:['https://other.net/file.zip'], headers:{ Cookie:'token=other.net' }, kind:'file' });
});

test('HTTPS pages do not leak a referer to HTTP targets', async () => {
  const value = await requestForURL('http://example.com/file', { pageURL:'https://example.com/private', getCookies:async () => [] });
  assert.deepEqual(value.headers, {});
});

test('detects direct video and audio from response content type', () => {
  assert.equal(detectMedia({ url:'https://example.com/play?id=1', responseHeaders:[{ name:'Content-Type', value:'video/mp4; charset=binary' }] })?.format, 'direct');
  assert.equal(detectMedia({ url:'https://example.com/audio.mp3' })?.kind, 'media');
  assert.equal(detectMedia({ url:'https://example.com/api', responseHeaders:[{ name:'Content-Type', value:'application/json' }] }), null);
});

test('detects HLS and DASH playlists without listing streaming segments', () => {
  assert.equal(detectMedia({ url:'https://example.com/master.m3u8?token=one' })?.format, 'stream');
  assert.equal(detectMedia({ url:'https://example.com/manifest', mime:'application/dash+xml' })?.format, 'stream');
  assert.equal(detectMedia({ url:'https://example.com/segment.ts', mime:'video/mp2t' }), null);
  assert.equal(detectMedia({ url:'blob:https://example.com/id', mime:'video/mp4' }), null);
});

test('media entries are deduplicated, refreshed, and bounded per tab', () => {
  let entries = [];
  entries = mergeMedia(entries, {url:'https://example.com/a.mp4#one', label:'old'}, 2);
  entries = mergeMedia(entries, {url:'https://example.com/b.mp4', label:'b'}, 2);
  entries = mergeMedia(entries, {url:'https://example.com/a.mp4#two', label:'new'}, 2);
  assert.deepEqual(entries.map(v => [v.url, v.label]), [['https://example.com/a.mp4', 'new'], ['https://example.com/b.mp4', 'b']]);
  entries = mergeMedia(entries, {url:'https://example.com/c.mp4', label:'c'}, 2);
  assert.deepEqual(entries.map(v => v.url), ['https://example.com/c.mp4', 'https://example.com/a.mp4']);
});

function browserHarness(response = {ok:true, result:[{id:'native-job'}]}) {
  const events = [];
  let state = 'in_progress';
  let paused = false;
  const io = {
    pause:async id => { events.push(`pause:${id}`); paused = true; },
    resume:async id => { events.push(`resume:${id}`); paused = false; },
    cancel:async id => { events.push(`cancel:${id}`); state = 'interrupted'; },
    send:async request => { events.push('native'); assert.equal(paused, true); assert.deepEqual(request, {action:'add', requests:[{urls:['https://example.com/a.zip'], headers:{}, kind:'file'}]}); return typeof response === 'function' ? response() : response; }
  };
  return { events, io, state:() => ({state, paused}) };
}
const browserDownload = {id:7, url:'https://example.com/a.zip', state:'in_progress', paused:false};
const nativeRequest = {urls:['https://example.com/a.zip'], headers:{}, kind:'file'};

test('automatic handoff pauses the browser and waits for native acceptance before cancellation', async () => {
  let acknowledge;
  const harness = browserHarness(() => new Promise(resolve => { acknowledge = resolve; }));
  const result = handoffBrowserDownload(browserDownload, {method:'GET'}, nativeRequest, harness.io);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(harness.events, ['pause:7', 'native']);
  assert.deepEqual(harness.state(), {state:'in_progress', paused:true});
  acknowledge({ok:true, result:[{id:'native-job'}]});
  assert.equal((await result).status, 'accepted');
  assert.deepEqual(harness.events, ['pause:7', 'native', 'cancel:7']);
});

test('native rejection resumes the browser without cancelling it', async () => {
  const harness = browserHarness({ok:false, error:'Host is not running'});
  await assert.rejects(handoffBrowserDownload(browserDownload, {method:'GET'}, nativeRequest, harness.io), /Host is not running/);
  assert.deepEqual(harness.events, ['pause:7', 'native', 'resume:7']);
  assert.deepEqual(harness.state(), {state:'in_progress', paused:false});
});

test('disconnection resumes the browser and exposes the native failure', async () => {
  const harness = browserHarness(() => { throw new Error('Native host disconnected'); });
  await assert.rejects(handoffBrowserDownload(browserDownload, {method:'GET'}, nativeRequest, harness.io), /Native host disconnected/);
  assert.deepEqual(harness.events, ['pause:7', 'native', 'resume:7']);
});

test('malformed acknowledgement does not authorize browser cancellation', async () => {
  for (const response of [{ok:true}, {ok:true, result:[]}, {ok:true, result:[{}]}]) {
    const harness = browserHarness(response);
    await assert.rejects(handoffBrowserDownload(browserDownload, {method:'GET'}, nativeRequest, harness.io), /accept/i);
    assert.deepEqual(harness.events, ['pause:7', 'native', 'resume:7']);
  }
});

test('POST, unknown methods, blob/data, and already paused/completed downloads stay in browser', async () => {
  for (const [download, method] of [[browserDownload, 'POST'], [browserDownload, undefined], [{...browserDownload, url:'blob:https://example.com/id'}, 'GET'], [{...browserDownload, url:'data:plain/x,x'}, 'GET'], [{...browserDownload, paused:true}, 'GET'], [{...browserDownload, state:'complete'}, 'GET']]) {
    const harness = browserHarness();
    assert.equal((await handoffBrowserDownload(download, {method}, nativeRequest, harness.io)).status, 'skipped');
    assert.deepEqual(harness.events, []);
  }
});

test('pause failure leaves browser untouched and never sends native add', async () => {
  const harness = browserHarness();
  harness.io.pause = async () => { throw new Error('Cannot pause download'); };
  await assert.rejects(handoffBrowserDownload(browserDownload, {method:'GET'}, nativeRequest, harness.io), /Cannot pause/);
  assert.deepEqual(harness.events, []);
});

test('cancellation failure after native acceptance keeps browser paused to avoid duplicate downloads', async () => {
  const harness = browserHarness();
  harness.io.cancel = async () => { throw new Error('Cannot cancel'); };
  const result = await handoffBrowserDownload(browserDownload, {method:'GET'}, nativeRequest, harness.io);
  assert.equal(result.status, 'accepted-browser-paused');
  assert.match(result.warning, /Cannot cancel/);
  assert.deepEqual(harness.events, ['pause:7', 'native']);
  assert.equal(harness.state().paused, true);
});

test('relative DOM media resolves against its document and missing sources stay absent', async () => {
  const {resolveMediaURL} = await import('../extensions/shared/core.mjs');
  assert.equal(resolveMediaURL('movie.mp4', 'https://example.com/path/page'), 'https://example.com/path/movie.mp4');
  assert.equal(resolveMediaURL(undefined, 'https://example.com/path/page'), null);
  assert.equal(resolveMediaURL('', 'https://example.com/path/page'), null);
  assert.equal(resolveMediaURL('blob:https://example.com/id', 'https://example.com/page'), null);
});

test('GET response correlation permits a known GET redirect chain', async () => {
  const {observeRequest, captureObservation} = await import('../extensions/shared/core.mjs');
  const records = new Map();
  observeRequest(records, {url:'https://example.com/start', method:'GET', tabId:1}, 1000);
  observeRequest(records, {url:'https://cdn.example.com/file', method:'GET', tabId:1, documentUrl:'https://example.com/page'}, 1001);
  assert.equal(captureObservation({url:'https://example.com/start', finalUrl:'https://cdn.example.com/file'}, records, 1002)?.method, 'GET');
});

test('a POST origin remains in the browser after redirecting to a GET response', async () => {
  const {observeRequest, captureObservation} = await import('../extensions/shared/core.mjs');
  const records = new Map();
  observeRequest(records, {url:'https://example.com/submit', method:'POST', tabId:1}, 1000);
  observeRequest(records, {url:'https://example.com/result', method:'GET', tabId:1}, 1001);
  assert.equal(captureObservation({url:'https://example.com/submit', finalUrl:'https://example.com/result'}, records, 1002), null);
});

test('overlapping GET and POST requests for one URL are never assumed to be a safe GET download', async () => {
  const {observeRequest, captureObservation} = await import('../extensions/shared/core.mjs');
  const records = new Map();
  observeRequest(records, {url:'https://example.com/file', method:'POST', tabId:1}, 1000);
  observeRequest(records, {url:'https://example.com/file', method:'GET', tabId:2}, 1001);
  assert.equal(captureObservation({url:'https://example.com/file'}, records, 1002), null);
  observeRequest(records, {url:'https://example.com/file', method:'GET', tabId:2}, 121002);
  assert.equal(captureObservation({url:'https://example.com/file'}, records, 121003)?.method, 'GET');
});

test('stale or unobserved requests cannot capture an automatic download', async () => {
  const {observeRequest, captureObservation} = await import('../extensions/shared/core.mjs');
  const records = new Map();
  observeRequest(records, {url:'https://example.com/file', method:'GET', tabId:1}, 1000);
  assert.equal(captureObservation({url:'https://example.com/file'}, records, 122000), null);
  assert.equal(captureObservation({url:'https://example.com/unknown'}, records, 1002), null);
});

test('request observations stay bounded in a long-lived Firefox background page', async () => {
  const {observeRequest} = await import('../extensions/shared/core.mjs');
  const records = new Map();
  for (let i = 0; i < 600; i++) observeRequest(records, {url:`https://example.com/file/${i}`, method:'GET', tabId:1}, 1000 + i);
  assert.equal(records.size, 500);
  assert.equal(records.has('https://example.com/file/0'), false);
  assert.equal(records.has('https://example.com/file/599'), true);
});

// Browser APIs are the external boundary; the generated background worker is run unchanged.
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
function event(beforeEmit = () => {}) {
  const listeners = [];
  return {addListener:fn => listeners.push(fn), emit:(...args) => { beforeEmit(...args); return listeners.map(fn => fn(...args)); }, listeners};
}
async function backgroundHarness({flavor = 'firefox', native = async message => ({ok:true, result:message.action === 'status' ? {jobs:[]} : [{id:'job-1'}]})} = {}) {
  const local = {}, session = {}, notifications = [], downloadEvents = [], cookies = [], nativeMessages = [], badges = [];
  const downloadItems = new Map();
  const store = data => ({
    get:async keys => Object.fromEntries((Array.isArray(keys) ? keys : [keys]).filter(key => key in data).map(key => [key, data[key]])),
    set:async values => { Object.assign(data, values); },
    remove:async key => { delete data[key]; }
  });
  const browser = {
    runtime:{id:flavor === 'chromium' ? 'ljmcdchlnbjjjbeljjlhdinmdcimngmm' : 'current@current-downloadmanager.local', getURL:path => `${flavor === 'chromium' ? 'chrome-extension://ljmcdchlnbjjjbeljjlhdinmdcimngmm/' : 'moz-extension://5cf92634-81bc-40fd-938a-58028decbf89/'}${path}`, onMessage:event(), sendNativeMessage:async (host, message) => { assert.equal(host, 'io.current.downloadmanager'); nativeMessages.push(message); return native(message); }},
    storage:{local:store(local), session:store(session)},
    action:{setBadgeText:async details => { badges.push({...details}); }, setBadgeBackgroundColor:async () => {}, setTitle:async () => {}},
    notifications:{create:async (id, value) => { notifications.push(value); return id; }},
    contextMenus:{removeAll:async () => {}, create:() => {}, onClicked:event()},
    webRequest:{onBeforeRequest:event(), onHeadersReceived:event()},
    tabs:{onRemoved:event(), onUpdated:event(), sendMessage:async () => ({urls:[]})},
    cookies:{getAll:async options => { cookies.push(options); return []; }},
    downloads:{onCreated:event(item => downloadItems.set(item.id, {...item})), search:async ({id}) => downloadItems.has(id) ? [downloadItems.get(id)] : [], pause:async id => { downloadEvents.push(`pause:${id}`); }, resume:async id => { downloadEvents.push(`resume:${id}`); }, cancel:async id => { downloadEvents.push(`cancel:${id}`); }}
  };
  const unhandledErrors = [];
  if (flavor === 'chromium') {
    let lastError, consumed;
    Object.defineProperty(browser.runtime, 'lastError', {get() { if (lastError) consumed = true; return lastError; }});
    const callbackNamespaces = [browser.runtime, browser.action, browser.notifications, browser.contextMenus, browser.tabs, browser.cookies, browser.downloads, browser.storage.local, browser.storage.session];
    for (const methods of callbackNamespaces) for (const [name, fn] of Object.entries(methods)) {
      if (typeof fn !== 'function' || name === 'getURL') continue;
      methods[name] = (...args) => {
        const callback = args.pop();
        Promise.resolve().then(() => fn(...args)).then(value => callback(value), error => {
          lastError = {message:error.message}; consumed = false;
          try { callback(undefined); if (!consumed) unhandledErrors.push(error.message); }
          finally { lastError = undefined; }
        });
      };
    }
  }
  const globals = flavor === 'chromium' ? {chrome:browser} : {browser};
  const context = vm.createContext({...globals, URL, setTimeout, clearTimeout, console});
  vm.runInContext(await readFile(new URL(`../extensions/${flavor}/background.js`, import.meta.url), 'utf8'), context);
  await new Promise(resolve => setImmediate(resolve));
  const message = (value, sender = {id:browser.runtime.id, url:browser.runtime.getURL('popup.html')}) => new Promise(resolve => browser.runtime.onMessage.emit(value, sender, resolve));
  const settle = async () => { for (let i = 0; i < 3; i++) await new Promise(resolve => setImmediate(resolve)); };
  return {browser, local, session, notifications, downloadItems, downloadEvents, cookies, nativeMessages, badges, unhandledErrors, message, settle};
}

test('generated background capture starts off and requires an explicit opt-in', async () => {
  const h = await backgroundHarness();
  h.browser.webRequest.onBeforeRequest.emit({url:'https://example.com/file', method:'GET', tabId:1});
  h.browser.downloads.onCreated.emit({id:9, url:'https://example.com/file', state:'in_progress', paused:false});
  await h.settle();
  assert.deepEqual(h.downloadEvents, []);
  await h.message({action:'set-capture', enabled:true});
  h.browser.downloads.onCreated.emit({id:10, url:'https://example.com/file', state:'in_progress', paused:false});
  await h.settle();
  assert.deepEqual(h.downloadEvents, ['pause:10', 'cancel:10']);
  assert.deepEqual(JSON.parse(JSON.stringify(h.cookies)), [{url:'https://example.com/file'}]);
});

test('generated worker resumes failed native transfers and makes the error visible', async () => {
  const h = await backgroundHarness({native:async () => { throw new Error('Host disconnected'); }});
  await h.message({action:'set-capture', enabled:true});
  h.browser.webRequest.onBeforeRequest.emit({url:'https://example.com/file', method:'GET', tabId:1});
  h.browser.downloads.onCreated.emit({id:11, url:'https://example.com/file', state:'in_progress', paused:false});
  await h.settle();
  assert.deepEqual(h.downloadEvents, ['pause:11', 'resume:11']);
  assert.match(h.local.lastError, /Host disconnected/);
  assert.equal(h.notifications.length, 1);
  assert.match(h.notifications[0].message, /Host disconnected/);
});

test('repeated popup polling shows an existing native failure without repeating notifications', async () => {
  const h = await backgroundHarness({native:async () => { throw new Error('Host disconnected'); }});
  await h.message({action:'snapshot', tabId:1});
  await h.message({action:'snapshot', tabId:1});
  assert.equal(h.notifications.length, 1);
  assert.match(h.local.lastError, /Host disconnected/);
});

test('generated worker removes detected media when tabs navigate or close', async () => {
  const h = await backgroundHarness();
  h.browser.webRequest.onHeadersReceived.emit({url:'https://example.com/a.mp4', method:'GET', statusCode:200, tabId:1, responseHeaders:[]});
  await h.settle();
  assert.equal((await h.message({action:'snapshot', tabId:1})).media.length, 1);
  h.browser.tabs.onUpdated.emit(1, {status:'loading'});
  await h.settle();
  assert.equal((await h.message({action:'snapshot', tabId:1})).media.length, 0);
  h.browser.webRequest.onHeadersReceived.emit({url:'https://example.com/a.mp4', method:'GET', statusCode:200, tabId:2, responseHeaders:[]});
  await h.settle();
  h.browser.tabs.onRemoved.emit(2);
  await h.settle();
  assert.equal((await h.message({action:'snapshot', tabId:2})).media.length, 0);
});


test('Chromium callback worker waits for native ACK before cancelling a captured GET', async () => {
  let acknowledge;
  const h = await backgroundHarness({flavor:'chromium', native:async () => new Promise(resolve => { acknowledge = resolve; })});
  await h.message({action:'set-capture', enabled:true});
  h.browser.webRequest.onBeforeRequest.emit({url:'https://example.com/file', method:'GET', tabId:1});
  h.browser.downloads.onCreated.emit({id:21, url:'https://example.com/file', state:'in_progress', paused:false});
  await h.settle();
  assert.deepEqual(h.downloadEvents, ['pause:21']);
  acknowledge({ok:true, result:[{id:'job-21'}]});
  await h.settle();
  assert.deepEqual(h.downloadEvents, ['pause:21', 'cancel:21']);
  assert.deepEqual(h.unhandledErrors, []);
});

test('Chromium runtime.lastError is consumed and native disconnect resumes the browser', async () => {
  const h = await backgroundHarness({flavor:'chromium', native:async () => { throw new Error('Native host exited'); }});
  await h.message({action:'set-capture', enabled:true});
  h.browser.webRequest.onBeforeRequest.emit({url:'https://example.com/file', method:'GET', tabId:1});
  h.browser.downloads.onCreated.emit({id:22, url:'https://example.com/file', state:'in_progress', paused:false});
  await h.settle();
  assert.deepEqual(h.downloadEvents, ['pause:22', 'resume:22']);
  assert.match(h.local.lastError, /Native host exited/);
  assert.deepEqual(h.unhandledErrors, []);
});


test('newly discovered media cannot hide an unresolved native error badge', async () => {
  const h = await backgroundHarness({native:async () => { throw new Error('Host unavailable'); }});
  h.browser.webRequest.onHeadersReceived.emit({url:'https://example.com/a.mp4', method:'GET', statusCode:200, tabId:1, responseHeaders:[]});
  await h.settle();
  await h.message({action:'snapshot', tabId:1});
  h.browser.webRequest.onHeadersReceived.emit({url:'https://example.com/b.mp4', method:'GET', statusCode:200, tabId:1, responseHeaders:[]});
  await h.settle();
  assert.equal(h.badges.filter(value => value.tabId === 1).at(-1).text, '!');
  await h.message({action:'clear-error'});
  assert.equal(h.badges.filter(value => value.tabId === 1).at(-1).text, '2');
});


for (const flavor of ['chromium', 'firefox']) {
  test(`${flavor} extension pages opened as tabs retain status, settings, job actions, and manual referer`, async () => {
    const h = await backgroundHarness({flavor});
    const sender = {id:h.browser.runtime.id, tab:{id:33}, url:h.browser.runtime.getURL('popup.html')};
    assert.equal((await h.message({action:'snapshot', tabId:1}, sender)).native.ok, true);
    assert.equal((await h.message({action:'set-capture', enabled:true}, sender)).captureEnabled, true);
    assert.equal((await h.message({action:'clear-error'}, sender)).ok, true);
    assert.equal((await h.message({action:'job-action', command:'pause', id:'job-33'}, sender)).ok, true);
    assert.equal((await h.message({action:'add', urls:['https://files.example.com/file'], pageURL:'https://www.example.com/private'}, sender)).ok, true);
    const add = h.nativeMessages.find(value => value.action === 'add');
    assert.equal(add.requests[0].headers.Referer, 'https://www.example.com/');
    assert.deepEqual(h.nativeMessages.map(value => value.action), ['status', 'pause', 'add']);
  });

  test(`${flavor} content scripts with the extension ID remain blocked from privileged popup actions`, async () => {
    const h = await backgroundHarness({flavor});
    const sender = {id:h.browser.runtime.id, tab:{id:34}, url:'https://example.com/page'};
    for (const request of [{action:'snapshot', tabId:34}, {action:'set-capture', enabled:true}, {action:'clear-error'}, {action:'job-action', command:'pause', id:'job-34'}]) {
      assert.equal((await h.message(request, sender)).ok, false);
    }
    assert.deepEqual(h.nativeMessages, []);
    assert.equal(h.local.captureEnabled, undefined);
    assert.equal((await h.message({action:'add', urls:['https://example.com/file'], pageURL:'https://attacker.invalid/'}, sender)).ok, true);
    assert.equal(h.nativeMessages[0].requests[0].headers.Referer, 'https://example.com/page');
  });

  test(`${flavor} missing and lookalike extension sender URLs do not receive popup privileges`, async () => {
    const h = await backgroundHarness({flavor});
    const root = h.browser.runtime.getURL('');
    for (const url of [undefined, `${root.slice(0, -1)}.attacker.invalid/popup.html`, `https://example.com/?extension=${root}`]) {
      assert.equal((await h.message({action:'snapshot'}, {id:h.browser.runtime.id, url})).ok, false);
    }
    assert.deepEqual(h.nativeMessages, []);
  });
}

test('automatic handoff rejects a native request for a different or multiple source URLs before pausing', async () => {
  for (const urls of [['https://other.example.com/file'], ['https://example.com/a.zip', 'https://other.example.com/file']]) {
    const h = browserHarness();
    await assert.rejects(handoffBrowserDownload(browserDownload, {method:'GET'}, {...nativeRequest, urls}, h.io), /source/i);
    assert.deepEqual(h.events, []);
  }
});

test('a blob download with a network final URL cannot authorize automatic handoff', async () => {
  const h = browserHarness();
  const download = {...browserDownload, url:'blob:https://example.com/id', finalUrl:'https://example.com/a.zip'};
  assert.equal((await handoffBrowserDownload(download, {method:'GET'}, nativeRequest, h.io)).status, 'skipped');
  assert.deepEqual(h.events, []);
});

test('a browser item erased during accepted native handoff is treated as gone after cancel rejects', async () => {
  const h = browserHarness();
  h.io.cancel = async () => { h.events.push('cancel:7'); throw new Error('Invalid download id 7'); };
  h.io.search = async id => { h.events.push(`search:${id}`); return []; };
  const result = await handoffBrowserDownload(browserDownload, {method:'GET'}, nativeRequest, h.io);
  assert.equal(result.status, 'accepted');
  assert.equal(result.warning, undefined);
  assert.deepEqual(h.events, ['pause:7', 'native', 'cancel:7', 'search:7']);
});

test('a remaining browser item keeps a true cancellation failure visible and stays paused', async () => {
  const h = browserHarness();
  h.io.cancel = async () => { throw new Error('Cannot cancel existing browser item'); };
  h.io.search = async () => [{...browserDownload, paused:true}];
  const result = await handoffBrowserDownload(browserDownload, {method:'GET'}, nativeRequest, h.io);
  assert.equal(result.status, 'accepted-browser-paused');
  assert.match(result.warning, /Cannot cancel existing browser item/);
  assert.deepEqual(h.events, ['pause:7', 'native']);
});

test('failure to check browser removal cannot silently hide a cancellation failure', async () => {
  const h = browserHarness();
  h.io.cancel = async () => { throw new Error('Cannot cancel existing browser item'); };
  h.io.search = async () => { throw new Error('Cannot query downloads'); };
  const result = await handoffBrowserDownload(browserDownload, {method:'GET'}, nativeRequest, h.io);
  assert.equal(result.status, 'accepted-browser-paused');
  assert.match(result.warning, /Cannot cancel existing browser item/);
});

test('generated Firefox background does not show a native error for an already-erased browser copy', async () => {
  const h = await backgroundHarness();
  h.browser.downloads.cancel = async () => { throw new Error('Invalid download id 28'); };
  h.browser.downloads.search = async query => { assert.equal(query.id, 28); return []; };
  await h.message({action:'set-capture', enabled:true});
  h.browser.webRequest.onBeforeRequest.emit({url:'https://example.com/file', method:'GET', tabId:1});
  h.browser.downloads.onCreated.emit({id:28, url:'https://example.com/file', state:'in_progress', paused:false});
  await h.settle();
  assert.equal(h.local.lastError, undefined);
  assert.deepEqual(h.notifications, []);
});

test('navigation cleanup cannot erase a GET observed immediately after Firefox starts download navigation', async () => {
  const h = await backgroundHarness();
  await h.message({action:'set-capture', enabled:true});
  h.browser.tabs.onUpdated.emit(1, {status:'loading'});
  h.browser.webRequest.onBeforeRequest.emit({url:'https://example.com/new-file', method:'GET', tabId:1});
  await h.settle(); // Firefox's download event arrives after headers/queued storage work.
  h.browser.downloads.onCreated.emit({id:29, url:'https://example.com/new-file', state:'in_progress', paused:false});
  await h.settle();
  assert.deepEqual(h.downloadEvents, ['pause:29', 'cancel:29']);
});

for (const flavor of ['chromium', 'firefox']) {
  test(`${flavor} captures a GET observation delivered after the download-created event`, async () => {
    const h = await backgroundHarness({flavor});
    await h.message({action:'set-capture', enabled:true});
    h.browser.downloads.onCreated.emit({id:30, url:'https://example.com/late-get', state:'in_progress', paused:false});
    await h.settle();
    assert.deepEqual(h.downloadEvents, []);
    h.browser.webRequest.onBeforeRequest.emit({url:'https://example.com/late-get', method:'GET', tabId:1});
    await new Promise(resolve => setTimeout(resolve, 60));
    await h.settle();
    assert.deepEqual(h.downloadEvents, ['pause:30', 'cancel:30']);
    assert.equal(h.nativeMessages.filter(message => message.action === 'add').length, 1);
  });

  test(`${flavor} never captures a late POST followed by an overlapping GET`, async () => {
    const h = await backgroundHarness({flavor});
    await h.message({action:'set-capture', enabled:true});
    h.browser.downloads.onCreated.emit({id:31, url:'https://example.com/late-post', state:'in_progress', paused:false});
    await h.settle();
    h.browser.webRequest.onBeforeRequest.emit({url:'https://example.com/late-post', method:'POST', tabId:1});
    h.browser.webRequest.onBeforeRequest.emit({url:'https://example.com/late-post', method:'GET', tabId:1});
    await new Promise(resolve => setTimeout(resolve, 1100));
    await h.settle();
    assert.deepEqual(h.downloadEvents, []);
    assert.equal(h.nativeMessages.length, 0);
  });

  for (const state of ['complete', 'paused']) {
    test(`${flavor} leaves a download that became ${state} while awaiting its GET in the browser`, async () => {
      const h = await backgroundHarness({flavor});
      await h.message({action:'set-capture', enabled:true});
      h.browser.downloads.onCreated.emit({id:32, url:'https://example.com/late-finished', state:'in_progress', paused:false});
      await h.settle();
      h.downloadItems.set(32, {id:32, url:'https://example.com/late-finished', state:state === 'complete' ? 'complete' : 'in_progress', paused:state === 'paused'});
      h.browser.webRequest.onBeforeRequest.emit({url:'https://example.com/late-finished', method:'GET', tabId:1});
      await new Promise(resolve => setTimeout(resolve, 60));
      await h.settle();
      assert.deepEqual(h.downloadEvents, []);
      assert.equal(h.nativeMessages.length, 0);
    });
  }
}
