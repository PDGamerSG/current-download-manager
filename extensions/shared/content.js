/* Runs in an isolated content-script world. No page script receives native privileges. */
(() => {
  const api = globalThis.browser || globalThis.chrome;
  const isFirefox = typeof globalThis.browser !== 'undefined';
  const controls = new Map();
  let scheduled = false;
  let lastDiscovery = '';
  function send(message) {
    if (isFirefox) return api.runtime.sendMessage(message);
    return new Promise((resolve, reject) => api.runtime.sendMessage(message, value => {
      const error = api.runtime.lastError;
      if (error) reject(new Error(error.message)); else resolve(value);
    }));
  }
  function networkURL(value) { return globalThis.CurrentCore.resolveMediaURL(value, document.baseURI); }
  document.addEventListener('click', event => {
    if (!event.isTrusted || !event.altKey || event.button !== 0) return;
    const anchor = event.target?.closest?.('a[href]');
    const url = anchor && networkURL(anchor.href);
    if (url) send({action:'bypass-capture', url}).catch(() => {});
  }, true);
  function sources(element) {
    const candidates = [{url:element.currentSrc || element.src, mime:element.getAttribute('type') || ''}];
    for (const source of element.querySelectorAll('source[src]')) candidates.push({url:source.src, mime:source.type});
    const seen = new Set();
    return candidates.map(value => ({url:networkURL(value.url), mime:value.mime || (element.tagName === 'AUDIO' ? 'audio/unknown' : 'video/unknown'), label:element.getAttribute('title') || document.title}))
      .filter(value => value.url && !seen.has(value.url) && seen.add(value.url));
  }
  function position() {
    for (const [element, entry] of controls) {
      if (!element.isConnected) { entry.host.remove(); controls.delete(element); continue; }
      const rect = element.getBoundingClientRect();
      entry.host.style.display = rect.width >= 140 && rect.height >= 90 && rect.bottom > 0 && rect.top < innerHeight ? 'block' : 'none';
      entry.host.style.left = `${Math.max(8, Math.min(innerWidth - 184, rect.left + 10))}px`;
      entry.host.style.top = `${Math.max(8, rect.top + 10)}px`;
    }
  }
  function addControl(element) {
    if (controls.has(element)) return;
    const host = document.createElement('div');
    host.setAttribute('data-current-download', '');
    host.style.cssText = 'all:initial;position:fixed;z-index:2147483646;display:none;';
    const shadow = host.attachShadow({mode:'closed'});
    const style = document.createElement('style');
    style.textContent = 'button{font:600 12px -apple-system,BlinkMacSystemFont,sans-serif;color:#fff;background:#2161d5;border:1px solid #ffffff66;border-radius:7px;padding:8px 11px;cursor:pointer;box-shadow:0 2px 9px #0004}button:hover{background:#164dac}button:focus-visible{outline:3px solid #fff;outline-offset:2px}button:disabled{opacity:.8;cursor:wait}span{display:block;max-width:250px;background:#172238;color:white;font:12px/1.4 -apple-system,sans-serif;padding:7px;border-radius:5px;margin-top:4px}span:empty{display:none}';
    const button = document.createElement('button');
    button.type = 'button'; button.textContent = '↓ Download with Current';
    button.setAttribute('aria-label', 'Download this video with Current');
    const feedback = document.createElement('span');
    feedback.setAttribute('role', 'status');
    button.addEventListener('click', async event => {
      event.preventDefault(); event.stopPropagation();
      button.disabled = true; feedback.textContent = '';
      try {
        const values = sources(element);
        if (!values.length) throw new Error('Open the Current toolbar popup to choose detected stream media.');
        const response = await send({action:'add', urls:[values[0].url], kind:'media'});
        if (!response?.ok) throw new Error(response?.error || 'Current did not accept this video.');
        feedback.textContent = 'Added to Current';
      } catch (error) { feedback.textContent = error.message || String(error); }
      finally { button.disabled = false; }
    });
    shadow.append(style, button, feedback); document.documentElement.append(host);
    controls.set(element, {host});
  }
  async function scan() {
    scheduled = false;
    const entries = [];
    for (const element of [...document.querySelectorAll('video, audio')].slice(0, 60)) {
      const values = sources(element);
      entries.push(...values);
      if (element.tagName === 'VIDEO' && values.length) addControl(element);
      else if (controls.has(element)) { controls.get(element).host.remove(); controls.delete(element); }
    }
    position();
    const signature = JSON.stringify(entries.slice(0, 100));
    if (signature !== lastDiscovery) {
      lastDiscovery = signature;
      if (entries.length) await send({action:'discover-media', entries:entries.slice(0, 100)}).catch(() => {});
    }
  }
  function schedule() {
    if (!scheduled) { scheduled = true; setTimeout(() => scan().catch(() => {}), 300); }
  }
  new MutationObserver(schedule).observe(document.documentElement, {childList:true, subtree:true, attributes:true, attributeFilter:['src', 'type']});
  document.addEventListener('loadedmetadata', schedule, true);
  document.addEventListener('play', schedule, true);
  window.addEventListener('scroll', position, {passive:true});
  window.addEventListener('resize', position, {passive:true});
  api.runtime.onMessage.addListener((message, sender, respond) => {
    if (message.action === 'scan-media') { scan().then(() => respond({ok:true})); return true; }
    if (message.action !== 'collect-links') return;
    const selection = window.getSelection();
    const ranges = selection ? Array.from({length:selection.rangeCount}, (_, i) => selection.getRangeAt(i)) : [];
    const urls = [];
    for (const anchor of document.querySelectorAll('a[href]')) {
      if (!message.selected || ranges.some(range => { try { return range.intersectsNode(anchor); } catch { return false; } })) {
        const value = networkURL(anchor.href); if (value) urls.push(value);
      }
      if (urls.length >= 1000) break;
    }
    if (message.selected) for (const value of (selection?.toString() || '').match(/https?:\/\/[^\s<>"']+/g) || []) {
      const url = networkURL(value); if (url) urls.push(url);
    }
    respond({urls:[...new Set(urls)].slice(0, 101)});
  });
  schedule();
})();
