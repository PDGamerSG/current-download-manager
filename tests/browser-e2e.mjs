// Real isolated Chromium extension → native host → service → file tests.
import {chromium} from 'playwright';
import {spawn, execFileSync} from 'node:child_process';
import {mkdtemp, readFile, writeFile, mkdir, readdir, rm, chmod} from 'node:fs/promises';
import {tmpdir, homedir} from 'node:os';
import {resolve, join, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const cli = process.env.CURRENT_TEST_CLI || join(root,'.build/debug/currentctl');
const directory = await mkdtemp(join(tmpdir(),'current-browser-e2e-'));
const state = join(directory,'state');
const env = {...process.env,CURRENT_STATE_DIR:state};
const hostName = 'io.current.downloadmanager';
const manifestFolders = ['Google/Chrome','Google/Chrome Canary','Google/Chrome for Testing','Chromium','Microsoft Edge','BraveSoftware/Brave-Browser','Mozilla'];
const backups = new Map();
let fixture, service, browser;
let serviceLog = '';
const delay = ms => new Promise(resolve => setTimeout(resolve,ms));
async function until(fn, label, timeout = 20000) {
  const deadline = Date.now()+timeout; let last;
  while (Date.now()<deadline) { try { last = await fn(); if (last) return last; } catch (error) { last=error.message; } await delay(100); }
  throw new Error(`Timed out: ${label}; last=${JSON.stringify(last)}`);
}
async function stop(child) {
  if (!child || child.exitCode !== null) return;
  child.kill('SIGTERM');
  await Promise.race([new Promise(r=>child.once('exit',r)),delay(7000)]);
  if (child.exitCode === null) child.kill('SIGKILL');
}
try {
  fixture = spawn('python3',['-u',join(root,'tests/fixture.py')],{stdio:['ignore','pipe','pipe']});
  let fixtureURL = '';
  fixture.stdout.on('data',data=>{fixtureURL += data.toString();});
  fixture.stderr.on('data',data=>{serviceLog += `Fixture: ${data}`;});
  fixture.on('error',error=>{serviceLog += `Fixture process: ${error.message}\n`;});
  await until(()=>fixtureURL.includes('\n'),'fixture readiness'); fixtureURL=fixtureURL.trim();
  service = spawn(cli,['serve'],{env,stdio:['ignore','pipe','pipe']});
  service.stdout.on('data',data=>{serviceLog+=data;}); service.stderr.on('data',data=>{serviceLog+=data;});
  const descriptor = await until(async()=>JSON.parse(await readFile(join(state,'bridge.json'),'utf8')),'engine readiness');
  async function command(action,values={}) {
    const response = await fetch(`http://127.0.0.1:${descriptor.port}/v1/command`,{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${descriptor.token}`},body:JSON.stringify({action,...values})});
    const body = await response.json(); assert.equal(body.ok,true,JSON.stringify(body)); return body.result;
  }
  await command('settings',{settings:{downloadDirectory:join(directory,'files')}});
  for (const folder of manifestFolders) {
    const path = join(homedir(),'Library/Application Support',folder,'NativeMessagingHosts',hostName+'.json');
    backups.set(path,await readFile(path).catch(()=>null));
  }
  execFileSync(cli,['install-browser-host'],{env,stdio:'pipe'});
  // A custom user-data directory is used by some Chromium builds for host discovery.
  const userData = join(directory,'profile'); await mkdir(join(userData,'NativeMessagingHosts'),{recursive:true});
  const installed = await readFile(join(homedir(),'Library/Application Support/Chromium/NativeMessagingHosts',hostName+'.json'));
  await writeFile(join(userData,'NativeMessagingHosts',hostName+'.json'),installed);
  const extension = join(root,'extensions/chromium');
  let executablePath = process.env.CURRENT_TEST_CHROMIUM;
  if (!executablePath) {
    const cache=join(homedir(),'Library/Caches/ms-playwright');
    const revisions=(await readdir(cache)).filter(x=>/^chromium-\d+$/.test(x)).sort((a,b)=>Number(b.split('-')[1])-Number(a.split('-')[1]));
    for (const revision of revisions) {
      const candidate=join(cache,revision,'chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing');
      if (await readFile(candidate).then(()=>true,()=>false)) { executablePath=candidate; break; }
    }
  }
  browser=await chromium.launchPersistentContext(userData,{
    executablePath,headless:process.env.CURRENT_BROWSER_HEADLESS==='1',env,
    args:[`--disable-extensions-except=${extension}`,`--load-extension=${extension}`,'--enable-unsafe-extension-debugging','--no-first-run']
  });
  const worker=browser.serviceWorkers()[0] || await browser.waitForEvent('serviceworker',{timeout:15000});
  const extensionID=new URL(worker.url()).host;
  assert.equal(extensionID,'ljmcdchlnbjjjbeljjlhdinmdcimngmm');
  const native=await worker.evaluate(async()=>new Promise((resolve,reject)=>chrome.runtime.sendNativeMessage('io.current.downloadmanager',{action:'status'},reply=>chrome.runtime.lastError?reject(new Error(chrome.runtime.lastError.message)):resolve(reply))));
  assert.equal(native.ok,true,JSON.stringify(native));
  const page=browser.pages()[0] || await browser.newPage();
  await page.goto(fixtureURL+'/page');
  const popup=await browser.newPage();
  popup.on('pageerror',error=>{serviceLog+='Popup JS: '+error.message+'\n';});
  popup.on('console',message=>{if(message.type()==='error') serviceLog+='Popup console: '+message.text()+'\n';});
  await popup.goto(`chrome-extension://${extensionID}/popup.html`);
  await popup.locator('#connection').filter({hasText:'Connected'}).waitFor({timeout:15000}).catch(async error=>{serviceLog+='Popup state: '+await popup.locator('body').innerText()+'\n';throw error;});
  await popup.locator('#urls').fill(fixtureURL+'/tiny.bin'); await popup.locator('#add-button').click();
  await until(async()=>(await command('status')).jobs.find(j=>j.filename==='tiny.bin'&&j.status==='complete'),'popup download completes');
  let jobs=(await command('status')).jobs;
  const manual=jobs.find(j=>j.filename==='tiny.bin');
  const expected=Buffer.from('Current fixture\n'.repeat(4096));
  assert.equal(createHash('sha256').update(await readFile(join(manual.directory,manual.filename))).digest('hex'),createHash('sha256').update(expected).digest('hex'));
  // Enable the opt-in capture control using the real popup.
  await popup.locator('#capture').check();
  await until(()=>worker.evaluate(()=>chrome.storage.local.get('captureEnabled').then(v=>v.captureEnabled===true)),'capture preference saved');
  await page.bringToFront(); await page.locator('#download').click();
  const captured=await until(async()=>(await command('status')).jobs.find(j=>j.request.urls[0]===fixtureURL+'/slow.bin'),'automatic browser handoff');
  await until(async()=>(await command('status')).jobs.some(j=>j.id===captured.id&&j.status==='complete'),'captured file completes');
  const actual=await readFile(join(captured.directory,captured.filename));
  const pattern=Buffer.from(Array.from({length:256},(_,i)=>i));
  assert.equal(actual.length,12*1024*1024);
  for (let offset=0;offset<actual.length;offset+=256) assert.equal(actual.subarray(offset,offset+256).equals(pattern),true);
  const browserDownloads=await worker.evaluate(()=>chrome.downloads.search({}));
  assert.ok(browserDownloads.some(j=>j.url.endsWith('/slow.bin')&&j.state==='interrupted'),'browser transfer is cancelled after native acceptance');
  await browser.addCookies([{name:'session',value:'fixture',url:fixtureURL,httpOnly:true,sameSite:'Lax'}]);
  await page.locator('#cookie-download').click();
  const sessionJob=await until(async()=>(await command('status')).jobs.find(j=>j.request.urls[0]===fixtureURL+'/cookie-slow.bin'),'authenticated browser handoff');
  await until(async()=>(await command('status')).jobs.some(j=>j.id===sessionJob.id&&j.status==='complete'),'cookie/referer capture completes');
  const sessionData=await readFile(join(sessionJob.directory,sessionJob.filename));
  assert.equal(createHash('sha256').update(sessionData).digest('hex'),createHash('sha256').update(actual).digest('hex'));
  // DOM media discovery must reach the extension's per-tab list.
  const media=await until(()=>popup.evaluate(async()=>{
    const tabs=await chrome.tabs.query({}); const target=tabs.find(t=>t.url?.includes('/page'));
    return new Promise(resolve=>chrome.runtime.sendMessage({action:'snapshot',tabId:target?.id},reply=>resolve(reply?.media?.find(m=>m.url.endsWith('/video.mp4')))));
  }),'page media discovery');
  assert.ok(media.url.endsWith('/video.mp4'));
  console.log(JSON.stringify({passed:['stable extension identity','real native host connection','popup URL → native host → byte-verified file','opt-in browser takeover → native acceptance → browser cancellation → byte-verified file','HttpOnly cookie and referer handoff → authenticated byte-verified file','page media discovery'],count:6,browser:await browser.browser().version()},null,2));
} catch(error) {
  console.error(serviceLog); throw error;
} finally {
  await browser?.close(); await stop(service); await stop(fixture);
  for (const [path,data] of backups) {
    if (data) { await writeFile(path,data); await chmod(path,0o600); }
    else await rm(path,{force:true});
  }
  await rm(directory,{recursive:true,force:true});
}
