/* Bundled after core.mjs and api.mjs by build.mjs; classic syntax works in Firefox MV2 and Chromium workers. */
(() => {
  const {normalizeURL, normalizeURLs, requestForURL, detectMedia, mergeMedia, acceptedJobs, handoffBrowserDownload, observeRequest, captureObservation} = globalThis.CurrentCore;
  const {api, callAPI, nativeMessage} = globalThis.CurrentAPI;
  const action = api.action || api.browserAction;
  const recentRequests = new Map();
  const inHandoff = new Set();
  const media = new Map();
  const sessionStore = api.storage.session || null;
  let mutation = Promise.resolve();
  let captureEnabled = false;
  let lastFailure = '';
  const ready = Promise.all([
    callAPI(api.storage.local, 'get', ['captureEnabled', 'lastError']).then(value => { captureEnabled = value.captureEnabled === true; if (value.lastError) { lastFailure = value.lastError; badge('!'); } }),
    sessionStore ? callAPI(sessionStore, 'get', 'tabMedia').then(value => { for (const [tab, entries] of Object.entries(value.tabMedia || {})) media.set(Number(tab), entries.slice(0, 60)); }) : Promise.resolve()
  ]);

  function badge(text, tabId) {
    const details = tabId === undefined ? {} : {tabId};
    callAPI(action, 'setBadgeText', {...details, text}).catch(() => {});
    callAPI(action, 'setBadgeBackgroundColor', {...details, color:text === '!' ? '#c0392b' : '#2463d9'}).catch(() => {});
  }
  async function report(error) {
    const message = String(error?.message || error).slice(0, 700);
    const previous = await callAPI(api.storage.local, 'get', 'lastError').catch(() => ({}));
    await callAPI(api.storage.local, 'set', {lastError:message}).catch(() => {});
    lastFailure = message;
    badge('!');
    for (const tabId of media.keys()) badge('!', tabId);
    callAPI(action, 'setTitle', {title:`Current — ${message}`}).catch(() => {});
    if (previous.lastError === message) return;
    await callAPI(api.notifications, 'create', 'current-handoff-error', {
      type:'basic', iconUrl:api.runtime.getURL('icons/icon128.png'), title:'Current needs attention', message
    }).catch(() => {});
  }
  async function clearError() {
    await callAPI(api.storage.local, 'remove', 'lastError');
    lastFailure = '';
    badge('');
    for (const [tabId, entries] of media) badge(String(entries.length || ''), tabId);
    await callAPI(action, 'setTitle', {title:'Current — Download manager'}).catch(() => {});
  }
  async function persistMedia() {
    if (sessionStore) await callAPI(sessionStore, 'set', {tabMedia:Object.fromEntries(media)});
  }
  function rememberMedia(tabId, entries) {
    if (!Number.isInteger(tabId) || tabId < 0) return Promise.resolve();
    mutation = mutation.catch(() => {}).then(async () => {
      await ready;
      let values = media.get(tabId) || [];
      for (const entry of entries.slice(0, 100)) {
        const detected = detectMedia(entry);
        if (detected) values = mergeMedia(values, {...detected, pageURL:normalizeURL(entry.pageURL, true) || ''});
      }
      media.set(tabId, values);
      await persistMedia();
      badge(lastFailure ? '!' : String(values.length || ''), tabId);
    });
    return mutation;
  }
  function clearTab(tabId) {
    // Firefox can observe the new navigation's GET before queued media writes
    // settle. Clear old request records at the event boundary, not afterward.
    for (const [url, record] of recentRequests) if (record.tabId === tabId) recentRequests.delete(url);
    mutation = mutation.catch(() => {}).then(async () => {
      await ready;
      media.delete(tabId);
      await persistMedia();
      badge(lastFailure ? '!' : '', tabId);
    });
    return mutation;
  }
  function observed(details) { observeRequest(recentRequests, details); }
  api.webRequest.onBeforeRequest.addListener(observed, {urls:['http://*/*', 'https://*/*']});
  api.webRequest.onHeadersReceived.addListener(details => {
    observed(details);
    if (details.statusCode < 200 || details.statusCode >= 400) return;
    const entry = detectMedia(details);
    if (entry) rememberMedia(details.tabId, [{...entry, pageURL:details.documentUrl || details.originUrl || details.initiator || ''}]).catch(report);
  }, {urls:['http://*/*', 'https://*/*']}, ['responseHeaders']);

  async function addURLs(urls, {pageURL, filename, kind = 'file', tabId} = {}) {
    const normalized = normalizeURLs(urls, 101);
    if (!normalized.length) throw new Error('No downloadable network links were found. Blob and data URLs stay in the browser.');
    if (normalized.length > 100) throw new Error('Choose at most 100 links at a time.');
    const requests = await Promise.all(normalized.map(url => requestForURL(url, {
      pageURL, filename:normalized.length === 1 ? filename : undefined, kind,
      getCookies:options => callAPI(api.cookies, 'getAll', options)
    })));
    const response = await nativeMessage({action:'add', requests});
    if (!acceptedJobs(response, requests.length)) throw new Error('Current did not acknowledge acceptance of every requested download.');
    await clearError();
    return response.result;
  }
  api.downloads.onCreated.addListener(download => {
    (async () => {
      await ready;
      if (!captureEnabled || inHandoff.has(download.id)) return;
      let url = normalizeURL(download.finalUrl || download.url, true);
      if (!url || !normalizeURL(download.url, true) || download.state !== 'in_progress' || download.paused) return;
      inHandoff.add(download.id);
      try {
        let record = captureObservation(download, recentRequests);
        if (!record) {
          // Firefox can dispatch onCreated before the corresponding webRequest
          // event. Wait briefly for positive GET evidence without pausing an
          // unknown/POST transfer. Recheck the actual download after waiting.
          const deadline = Date.now() + 1000;
          while (!record && captureEnabled && Date.now() < deadline) {
            await new Promise(resolve => setTimeout(resolve, 25));
            record = captureObservation(download, recentRequests);
          }
          if (!record || !captureEnabled) return;
          const matches = await callAPI(api.downloads, 'search', {id:download.id});
          const current = matches.find(item => item.id === download.id);
          if (!current || current.state !== 'in_progress' || current.paused || normalizeURL(current.url, true) !== normalizeURL(download.url, true)) return;
          download = current;
          url = normalizeURL(download.finalUrl || download.url, true);
          record = captureObservation(download, recentRequests);
        }
        // Unknown or unsafe request methods always remain in the browser.
        if (!record || !captureEnabled) return;
        const pageURL = download.referrer || record.pageURL;
        const request = await requestForURL(url, {
          pageURL, filename:download.filename?.split(/[\\/]/).pop(),
          getCookies:options => callAPI(api.cookies, 'getAll', options)
        });
        if (!captureEnabled || !captureObservation(download, recentRequests)) return;
        const result = await handoffBrowserDownload(download, record, request, {
          pause:id => callAPI(api.downloads, 'pause', id),
          resume:id => callAPI(api.downloads, 'resume', id),
          cancel:id => callAPI(api.downloads, 'cancel', id),
          search:id => callAPI(api.downloads, 'search', {id}),
          send:nativeMessage
        });
        if (result.warning) await report(result.warning); else if (result.status === 'accepted') await clearError();
      } finally { inHandoff.delete(download.id); }
    })().catch(report);
  });

  const menus = [
    {id:'current-link', title:'Download link with Current', contexts:['link']},
    {id:'current-media', title:'Download media with Current', contexts:['video', 'audio']},
    {id:'current-selected', title:'Download selected links with Current', contexts:['selection']},
    {id:'current-all', title:'Download page links with Current', contexts:['page']}
  ];
  async function installMenus() {
    await callAPI(api.contextMenus, 'removeAll');
    for (const menu of menus) {
      // Firefox returns a synchronous menu ID; Chrome accepts an optional callback.
      if (typeof globalThis.browser !== 'undefined') api.contextMenus.create(menu);
      else await callAPI(api.contextMenus, 'create', menu);
    }
  }
  installMenus().catch(report);
  api.contextMenus.onClicked.addListener((info, tab) => {
    (async () => {
      if (info.menuItemId === 'current-link') return addURLs([info.linkUrl], {pageURL:info.pageUrl || tab?.url});
      if (info.menuItemId === 'current-media') return addURLs([info.srcUrl], {pageURL:info.pageUrl || tab?.url, kind:'media'});
      const result = await callAPI(api.tabs, 'sendMessage', tab.id, {action:'collect-links', selected:info.menuItemId === 'current-selected'});
      return addURLs(result.urls || [], {pageURL:info.pageUrl || tab?.url});
    })().catch(report);
  });
  api.tabs.onRemoved.addListener(tabId => { clearTab(tabId).catch(report); });
  api.tabs.onUpdated.addListener((tabId, change) => {
    if (change.status === 'loading' || change.url) clearTab(tabId).catch(report);
  });

  async function handleMessage(message, sender) {
    await ready;
    if (sender.id !== api.runtime.id || !message || typeof message.action !== 'string') throw new Error('Unrecognized extension request.');
    const extensionPage = typeof sender.url === 'string' && sender.url.startsWith(api.runtime.getURL(''));
    const contentPage = !extensionPage && Boolean(sender.tab && normalizeURL(sender.url, true));
    if (!extensionPage && !contentPage) throw new Error('Unrecognized extension source.');
    switch (message.action) {
      case 'discover-media':
        if (!contentPage || !Array.isArray(message.entries)) throw new Error('Media must come from a page.');
        await rememberMedia(sender.tab.id, message.entries.map(entry => ({...entry, pageURL:sender.url})));
        return {ok:true};
      case 'add': {
        if (!Array.isArray(message.urls)) throw new Error('Provide download URLs.');
        const pageURL = extensionPage ? message.pageURL : sender.url;
        return {ok:true, result:await addURLs(message.urls, {pageURL, kind:message.kind, filename:message.filename})};
      }
      case 'snapshot': {
        if (!extensionPage) throw new Error('Open the Current toolbar popup to view downloads.');
        let status;
        try { status = await nativeMessage({action:'status'}); }
        catch (error) { await report(error); status = {ok:false, error:error.message}; }
        const saved = await callAPI(api.storage.local, 'get', 'lastError');
        return {ok:true, captureEnabled, native:status, media:media.get(message.tabId) || [], lastError:saved.lastError || ''};
      }
      case 'set-capture':
        if (!extensionPage) throw new Error('Change capture from the toolbar popup.');
        captureEnabled = message.enabled === true;
        await callAPI(api.storage.local, 'set', {captureEnabled});
        return {ok:true, captureEnabled};
      case 'clear-error':
        if (!extensionPage) throw new Error('Open the toolbar popup.');
        await clearError(); return {ok:true};
      case 'job-action':
        if (!extensionPage || !['pause', 'resume', 'cancel'].includes(message.command) || typeof message.id !== 'string') throw new Error('Unsupported download action.');
        return nativeMessage({action:message.command, id:message.id});
      default: throw new Error('Unsupported extension request.');
    }
  }
  api.runtime.onMessage.addListener((message, sender, sendResponse) => {
    handleMessage(message, sender).then(sendResponse, async error => {
      await report(error);
      sendResponse({ok:false, error:String(error?.message || error)});
    });
    return true;
  });
})();
