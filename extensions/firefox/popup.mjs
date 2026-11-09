import {api, callAPI} from './api.mjs';
import {normalizeURLs} from './core.mjs';
const $ = id => document.getElementById(id);
let currentTab;
let refreshing = false;
async function send(message) {
  const response = await callAPI(api.runtime, 'sendMessage', message);
  if (!response?.ok) throw new Error(response?.error || 'The extension could not complete this request.');
  return response;
}
function showError(error) { $('error-text').textContent = error.message || String(error); $('error').hidden = false; }
function feedback(message) { $('feedback').textContent = message; }
function infoRow(name, detail) {
  const li = document.createElement('li');
  const info = document.createElement('div'); info.className = 'item-info';
  const title = document.createElement('div'); title.className = 'item-name'; title.textContent = name; title.title = name;
  const sub = document.createElement('div'); sub.className = 'item-detail'; sub.textContent = detail;
  info.append(title, sub); li.append(info); return {li, info};
}
function actionButton(label, title, handler) {
  const button = document.createElement('button'); button.type = 'button'; button.className = 'small'; button.textContent = label; button.title = title; button.setAttribute('aria-label', title);
  button.addEventListener('click', async () => { button.disabled = true; try { await handler(); } catch (error) { showError(error); } finally { button.disabled = false; } });
  return button;
}
function bytes(value) {
  if (!value) return '0 B';
  const i = Math.min(3, Math.floor(Math.log(value) / Math.log(1024)));
  return `${(value / 1024 ** i).toFixed(i ? 1 : 0)} ${['B', 'KB', 'MB', 'GB'][i]}`;
}
function renderMedia(entries) {
  $('media-list').replaceChildren(); $('media-empty').hidden = entries.length > 0;
  $('media-count').textContent = entries.length ? String(entries.length) : '';
  for (const entry of entries) {
    const {li} = infoRow(entry.label || new URL(entry.url).hostname, `${new URL(entry.url).hostname} · ${entry.format === 'stream' ? 'HLS / DASH · media tools required' : 'Direct media'}`);
    li.append(actionButton('Download', `Download ${entry.label || 'media'}`, async () => {
      await send({action:'add', urls:[entry.url], kind:'media', pageURL:entry.pageURL || currentTab?.url}); feedback('Media added'); await refresh();
    }));
    $('media-list').append(li);
  }
}
function renderJobs(jobs) {
  $('downloads-list').replaceChildren(); $('downloads-empty').hidden = jobs.length > 0;
  $('downloads-count').textContent = jobs.length ? String(jobs.length) : '';
  for (const job of [...jobs].sort((a,b) => String(b.createdAt).localeCompare(String(a.createdAt))).slice(0, 8)) {
    const {li, info} = infoRow(job.filename, `${job.status} · ${bytes(job.completedBytes)}${job.totalBytes ? ` / ${bytes(job.totalBytes)}` : ''}${job.bytesPerSecond ? ` · ${bytes(job.bytesPerSecond)}/s` : ''}`);
    if (job.error) { const error = document.createElement('div'); error.className = 'item-detail'; error.textContent = job.error; info.append(error); }
    if (job.totalBytes && !['complete', 'cancelled'].includes(job.status)) {
      const progress = document.createElement('progress'); progress.max = job.totalBytes; progress.value = job.completedBytes; progress.setAttribute('aria-label', `${job.filename} progress`); info.append(progress);
    }
    const actions = document.createElement('div'); actions.className = 'job-actions';
    const run = async command => { await send({action:'job-action', command, id:job.id}); await refresh(); };
    if (['active', 'waiting'].includes(job.status)) actions.append(actionButton('Pause', `Pause ${job.filename}`, () => run('pause')));
    if (['paused', 'error', 'cancelled'].includes(job.status)) actions.append(actionButton('Resume', `Resume ${job.filename}`, () => run('resume')));
    if (!['complete', 'cancelled'].includes(job.status)) actions.append(actionButton('×', `Cancel ${job.filename}`, () => run('cancel')));
    li.append(actions); $('downloads-list').append(li);
  }
}
async function refresh() {
  if (refreshing) return;
  refreshing = true; $('refresh').disabled = true;
  try {
    const snapshot = await send({action:'snapshot', tabId:currentTab?.id});
    $('capture').checked = snapshot.captureEnabled;
    $('connection').textContent = snapshot.native?.ok ? 'Connected to the macOS app' : 'App connection unavailable';
    if (snapshot.lastError) showError(snapshot.lastError);
    renderMedia(snapshot.media || []);
    if (snapshot.native?.ok) renderJobs(snapshot.native.result?.jobs || []);
  } catch (error) { showError(error); $('connection').textContent = 'App connection unavailable'; }
  finally { refreshing = false; $('refresh').disabled = false; }
}
$('add-form').addEventListener('submit', async event => {
  event.preventDefault(); $('add-button').disabled = true;
  try {
    const values = $('urls').value.split(/\r?\n/).map(value => value.trim()).filter(Boolean);
    const urls = normalizeURLs(values, 101);
    if (!urls.length || values.some(value => !normalizeURLs([value]).length)) throw new Error('Enter valid network URLs, one per line.');
    await send({action:'add', urls, pageURL:currentTab?.url}); $('urls').value = ''; feedback(`${urls.length} download${urls.length === 1 ? '' : 's'} added`); $('error').hidden = true; await refresh();
  } catch (error) { showError(error); }
  finally { $('add-button').disabled = false; }
});
$('capture').addEventListener('change', async () => {
  const enabled = $('capture').checked;
  try { await send({action:'set-capture', enabled}); feedback(enabled ? 'Capture enabled' : 'Capture disabled'); }
  catch (error) { $('capture').checked = !enabled; showError(error); }
});
$('dismiss-error').addEventListener('click', async () => { try { await send({action:'clear-error'}); $('error').hidden = true; } catch (error) { showError(error); } });
$('refresh').addEventListener('click', refresh);
try {
  [currentTab] = await callAPI(api.tabs, 'query', {active:true, currentWindow:true});
  if (currentTab?.id) await callAPI(api.tabs, 'sendMessage', currentTab.id, {action:'scan-media'}).catch(() => {});
} catch (error) { showError(error); }
await refresh();
setInterval(refresh, 5000);
