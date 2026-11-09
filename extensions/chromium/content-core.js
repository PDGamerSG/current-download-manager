/* Generated from shared/core.mjs */
globalThis.CurrentCore = (() => {
/* Shared, browser-independent rules. This module is also imported by Node tests. */
const NETWORK_SCHEMES = new Set(['http:', 'https:', 'ftp:', 'sftp:']);
const WEB_SCHEMES = new Set(['http:', 'https:']);
const CONTROLS = /[\u0000-\u001f\u007f]/;

function normalizeURL(value, webOnly = false) {
  if (typeof value !== 'string' || CONTROLS.test(value)) return null;
  try {
    const url = new URL(value.trim());
    if (!(webOnly ? WEB_SCHEMES : NETWORK_SCHEMES).has(url.protocol) || !url.hostname || url.username || url.password) return null;
    url.hash = '';
    return url.href;
  } catch { return null; }
}

function normalizeURLs(values, limit = 100) {
  return [...new Set(values.map(value => normalizeURL(value)).filter(Boolean))].slice(0, limit);
}

function cookieHeader(rawURL, cookies) {
  const value = normalizeURL(rawURL, true);
  if (!value) return '';
  const url = new URL(value);
  return cookies.filter(cookie => {
    const domain = String(cookie.domain || '').toLowerCase().replace(/^\./, '');
    const host = url.hostname.toLowerCase();
    const path = cookie.path || '/';
    const domainMatches = cookie.hostOnly ? host === domain : host === domain || host.endsWith(`.${domain}`);
    const pathMatches = url.pathname === path || (url.pathname.startsWith(path) && (path.endsWith('/') || url.pathname[path.length] === '/'));
    return domain && domainMatches && pathMatches && (!cookie.secure || url.protocol === 'https:') &&
      typeof cookie.name === 'string' && !/[\s;=\u0000-\u001f\u007f]/.test(cookie.name) &&
      typeof cookie.value === 'string' && !/[;\u0000-\u001f\u007f]/.test(cookie.value);
  }).sort((a, b) => (b.path || '/').length - (a.path || '/').length)
    .map(cookie => `${cookie.name}=${cookie.value}`).join('; ');
}

async function requestForURL(rawURL, {pageURL, getCookies, filename, kind = 'file'} = {}) {
  const url = normalizeURL(rawURL);
  if (!url) throw new Error('Use a valid HTTP, HTTPS, FTP or SFTP URL without embedded credentials.');
  const headers = {};
  if (normalizeURL(url, true)) {
    const cookies = getCookies ? await getCookies({url}) : [];
    const cookie = cookieHeader(url, cookies);
    if (cookie) headers.Cookie = cookie;
    const page = normalizeURL(pageURL, true);
    if (page) {
      const source = new URL(page);
      const target = new URL(url);
      if (!(source.protocol === 'https:' && target.protocol === 'http:')) {
        headers.Referer = source.origin === target.origin ? source.href : `${source.origin}/`;
      }
    }
  }
  const request = {urls:[url], headers, kind:kind === 'media' ? 'media' : 'file'};
  if (typeof filename === 'string' && filename && filename.length <= 220 && !/[\u0000-\u001f\u007f/:\\]/.test(filename) && !['.', '..'].includes(filename)) request.filename = filename;
  return request;
}

function detectMedia({url:rawURL, responseHeaders = [], mime = '', label = ''}) {
  const url = normalizeURL(rawURL, true);
  if (!url) return null;
  const type = (mime || responseHeaders.find(header => header.name.toLowerCase() === 'content-type')?.value || '').split(';')[0].trim().toLowerCase();
  const path = new URL(url).pathname.toLowerCase();
  if (/\.(ts|m4s|cmfv|cmfa)$/.test(path) || type === 'video/mp2t') return null;
  const stream = /\.(m3u8|mpd)$/.test(path) || ['application/vnd.apple.mpegurl', 'application/x-mpegurl', 'audio/mpegurl', 'audio/x-mpegurl', 'application/dash+xml'].includes(type);
  const direct = /^(video|audio)\//.test(type) || /\.(mp4|webm|mov|m4v|mkv|avi|mp3|m4a|aac|ogg|oga|opus|wav|flac)$/.test(path);
  if (!stream && !direct) return null;
  let name = path.split('/').pop();
  try { name = decodeURIComponent(name); } catch { /* Keep the original path for invalid percent encoding. */ }
  return {url, kind:'media', format:stream ? 'stream' : 'direct', mime:type, label:(label || name || new URL(url).hostname).slice(0, 180)};
}

function mergeMedia(entries, entry, limit = 60) {
  const url = normalizeURL(entry?.url, true);
  if (!url) return entries;
  return [{...entry, url}, ...entries.filter(value => value.url !== url)].slice(0, limit);
}

function acceptedJobs(response, count = 1) {
  return response?.ok === true && Array.isArray(response.result) && response.result.length === count &&
    response.result.every(job => typeof job?.id === 'string' && job.id.length > 0);
}

async function handoffBrowserDownload(download, observedRequest, request, io) {
  const url = normalizeURL(download.finalUrl || download.url, true);
  if (!url || !normalizeURL(download.url, true) || observedRequest?.method !== 'GET' || download.state !== 'in_progress' || download.paused) return {status:'skipped'};
  if (!Array.isArray(request?.urls) || request.urls.length !== 1 || normalizeURL(request.urls[0], true) !== url) throw new Error('The native handoff source must match this browser download.');
  await io.pause(download.id);
  try {
    const response = await io.send({action:'add', requests:[request]});
    if (!acceptedJobs(response)) throw new Error(response?.error || 'Current did not acknowledge acceptance of this download.');
  } catch (error) {
    try { await io.resume(download.id); }
    catch (resumeError) { throw new Error(`${error.message || error} Browser download remains paused: ${resumeError.message || resumeError}`); }
    throw error;
  }
  try { await io.cancel(download.id); }
  catch (error) {
    if (typeof io.search === 'function') {
      try {
        const remaining = await io.search(download.id);
        if (Array.isArray(remaining) && remaining.length === 0) return {status:'accepted'};
      } catch { /* An unknown browser state must retain the cancellation error. */ }
    }
    return {status:'accepted-browser-paused', warning:`Current accepted the download. The browser copy remains paused: ${error.message || error}`};
  }
  return {status:'accepted'};
}

function resolveMediaURL(value, baseURL) {
  if (typeof value !== 'string' || !value.trim() || CONTROLS.test(value)) return null;
  try { return normalizeURL(new URL(value, baseURL).href, true); } catch { return null; }
}

function observeRequest(records, details, now = Date.now()) {
  const url = normalizeURL(details.url, true);
  if (!url) return;
  const previous = records.get(url);
  const unsafeUntil = details.method !== 'GET' ? now + 120000 : previous?.unsafeUntil || 0;
  records.delete(url);
  records.set(url, {method:details.method, tabId:details.tabId, pageURL:details.documentUrl || details.originUrl || details.initiator || '', time:now, unsafeUntil});
  for (const [key, value] of records) if (records.size > 500 || value.time < now - 120000) records.delete(key);
}

function captureObservation(download, records, now = Date.now()) {
  const original = normalizeURL(download.url, true);
  const final = normalizeURL(download.finalUrl || download.url, true);
  if (!original || !final) return null;
  for (const url of [original, final]) {
    const record = records.get(url);
    if (!record || record.method !== 'GET' || record.time < now - 120000 || record.unsafeUntil > now) return null;
  }
  return records.get(final);
}

return {resolveMediaURL};
})();
