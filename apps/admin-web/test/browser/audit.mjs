import { createRequire } from 'node:module';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:http';
import assert from 'node:assert/strict';
const require = createRequire(import.meta.url);
const { build } = require('esbuild');
const { chromium } = process.env.AUDIT_TEST_TOOLS
  ? createRequire(path.join(process.env.AUDIT_TEST_TOOLS, 'package.json'))('playwright')
  : require('playwright');
const temp = await mkdtemp(path.join(tmpdir(), 'voiid-admin-browser-'));
const directory = path.dirname(fileURLToPath(import.meta.url));
await build({ entryPoints: [path.join(directory, 'harness.jsx')], bundle: true, outfile: path.join(temp, 'test.js'), jsx: 'automatic', define: { 'process.env.NODE_ENV': '"development"', 'process.env.NEXT_PUBLIC_API_BASE': '"https://example.invalid"' }, plugins: [{ name: 'next-router-test-boundary', setup(b) {
  b.onResolve({ filter: /^next\/(link|navigation)$/ }, args => ({ path: args.path, namespace: 'router' }));
  b.onLoad({ filter: /.*/, namespace: 'router' }, args => ({ contents: args.path.endsWith('link')
    ? `import React from 'react'; export default function Link({href,children,...props}) { return React.createElement('a',{...props,href,onClick:e=>{e.preventDefault();history.pushState({},'',href);dispatchEvent(new Event('popstate'));}},children); }`
    : `import {useSyncExternalStore} from 'react'; const router={replace(){}}; export const useRouter=()=>router; export const usePathname=()=>useSyncExternalStore(cb=>{addEventListener('popstate',cb);return()=>removeEventListener('popstate',cb)},()=>location.pathname,()=>'/');`, resolveDir: path.resolve(directory, '../..') }));
} }] });
const server = createServer(async (req, res) => {
  const asset = req.url === '/test.js' ? 'test.js' : req.url === '/test.css' ? 'test.css' : null;
  res.setHeader('Content-Type', asset?.endsWith('js') ? 'text/javascript' : asset ? 'text/css' : 'text/html');
  res.end(asset ? await readFile(path.join(temp, asset)) : '<html><head><link rel="stylesheet" href="/test.css"><style>:root{--dur-base:180ms;--ease-out:cubic-bezier(.16,1,.3,1)}.srOnly{position:absolute;width:1px;height:1px;overflow:hidden}</style></head><body><div id="root"></div><script src="/test.js"></script></body></html>');
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const browser = await chromium.launch({ headless: true, ...(process.env.AUDIT_BROWSER_EXECUTABLE ? { executablePath: process.env.AUDIT_BROWSER_EXECUTABLE } : {}) });
const base = `http://127.0.0.1:${server.address().port}`;
let failures = 0;
async function check(name, fn) {
  const page = await browser.newPage({ viewport: { width: 800, height: 900 } });
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  try { await fn(page); assert.deepEqual(errors, []); console.log(`PASS ${name}`); }
  catch (e) { failures++; console.error(`FAIL ${name}: ${e.stack}; browser errors: ${errors.join('; ')}`); }
  finally { await page.close(); }
}
const count = (page, n) => page.waitForFunction(n => window.requests.length >= n, n);
const state = page => page.locator('#state').textContent().then(JSON.parse);
const finish = (page, index, ids, cursor = null) => page.evaluate(({index,ids,cursor}) => window.finish(index,{ items: ids.map(id=>({id})), next_cursor:cursor }), {index,ids,cursor});
const settles = page => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
await check('StrictMode setup accepts responses after cleanup', async p => {
  await p.goto(base); await count(p,1); await finish(p,0,['A'],'a'); await settles(p);
  assert.deepEqual((await state(p)).rows,[{id:'A'}]); assert.equal((await state(p)).loading,false);
});
await check('filter change invalidates response and cursor before debounce fires', async p => {
  await p.goto(base+'/?mode=plain'); await count(p,1);
  await p.getByRole('textbox').fill('B'); await finish(p,0,['stale'],'old'); await settles(p);
  assert.deepEqual((await state(p)).rows,[]); assert.equal((await state(p)).cursor,null);
  assert.equal(await p.evaluate(()=>window.requests[0].init.signal.aborted),true);
  await count(p,2); await finish(p,1,['B'],'b'); await settles(p); assert.deepEqual((await state(p)).rows,[{id:'B'}]);
});
await check('obsolete errors/finally cannot clear current loading', async p => {
  await p.goto(base+'/?mode=plain'); await count(p,1); await p.getByRole('textbox').fill('B');
  await p.evaluate(()=>window.fail(0)); await settles(p);
  assert.equal((await state(p)).error,null); assert.equal((await state(p)).loading,true);
});
await check('more is serialized and obsolete finally cannot unlock a newer append', async p => {
  await p.goto(base+'/?mode=plain'); await count(p,1); await finish(p,0,['A'],'a'); await settles(p);
  await p.evaluate(()=>{window.list.more();window.list.more()}); await count(p,2);
  assert.equal(await p.evaluate(()=>window.requests.length),2);
  await p.evaluate(()=>{void window.list.reload()}); await count(p,3); await finish(p,2,['B'],'b'); await settles(p);
  await p.evaluate(()=>{void window.list.more()}); await count(p,4); await finish(p,1,['old'],'old'); await settles(p);
  await p.evaluate(()=>{void window.list.more()}); assert.equal(await p.evaluate(()=>window.requests.length),4);
  await finish(p,3,['B','C']); await settles(p); assert.deepEqual((await state(p)).rows,[{id:'B'},{id:'C'}]);
});
const reports = ['one','two'].map(id=>({id,target_type:'clip',target_id:id,reason:id,note:null,has_evidence:false,status:'open',created_at:'2026-09-05T00:00:00Z',resolved_at:null,resolution:null,reporter_username:'tester'}));
async function openReports(p) {
  await p.goto(base+'/?mode=reports');
  await p.waitForFunction(()=>window.requests.some(r=>r.url.includes('/reports?')));
  await p.evaluate(reports=>{window.requests.filter(r=>r.url.includes('/reports?')).forEach(r=>r.resolve({reports,next_cursor:null}));}, reports);
  await p.locator('select').first().waitFor({timeout:1500});
}
await check('actual report Cancel/Escape resets selection and sends no mutation', async p => {
  await openReports(p);
  for (let i=0;i<2;i++) {
    p.once('dialog', d=>d.dismiss()); await p.locator('select').first().selectOption('removed');
    assert.equal(await p.locator('select').first().inputValue(),'');
  }
  assert.equal(await p.evaluate(()=>window.requests.filter(r=>r.init.method==='POST').length),0);
});
await check('actual report empty note posts once; busy blocks duplicates and retry stays on row', async p => {
  await openReports(p); p.once('dialog',d=>d.accept('')); await p.locator('select').first().selectOption('removed');
  assert.equal(await p.locator('select').nth(1).isDisabled(),true);
  const mutation = await p.evaluate(()=>window.requests.findIndex(r=>r.init.method==='POST'));
  const sent = await p.evaluate(i=>({url:window.requests[i].url,body:JSON.parse(window.requests[i].init.body)}),mutation);
  assert.ok(sent.url.endsWith('/reports/one/resolve')); assert.deepEqual(sent.body,{resolution:'removed',note:''});
  await p.evaluate(i=>window.fail(i),mutation); await p.getByText(/server failure/).waitFor();
  assert.equal(await p.locator('select').first().inputValue(),'');
  p.once('dialog',d=>d.accept('retry')); await p.locator('select').first().selectOption('removed');
  assert.equal(await p.evaluate(()=>window.requests.filter(r=>r.init.method==='POST').length),2);
  assert.ok(await p.evaluate(()=>window.requests.at(-1).url.endsWith('/reports/one/resolve')));
});
await check('mobile nav hidden from keyboard/AX; Escape restores focus', async p => {
  await p.goto(base+'/?mode=nav'); const toggle=p.locator('button[aria-controls="site-nav"]'); await toggle.waitFor();
  await toggle.focus(); await p.keyboard.press('Tab'); assert.equal(await p.locator('#outside').evaluate(e=>e===document.activeElement),true);
  assert.equal(await p.getByRole('navigation').count(),0);
  await toggle.click(); assert.equal(await toggle.getAttribute('aria-expanded'),'true');
  await p.getByRole('link',{name:'Get Voiid'}).focus(); await p.keyboard.press('Escape');
  assert.equal(await toggle.getAttribute('aria-expanded'),'false'); assert.equal(await toggle.evaluate(e=>e===document.activeElement),true, 'toggle focus: '+await p.evaluate(()=>document.activeElement.outerHTML));
});
await check('route close and desktop/mobile resize retain visible focus', async p => {
  await p.goto(base+'/?mode=nav'); const toggle=p.locator('button[aria-controls="site-nav"]'); await toggle.click();
  await p.getByRole('link',{name:'Get Voiid'}).click(); await settles(p);
  assert.equal(await toggle.evaluate(e=>e===document.activeElement),true, 'toggle focus: '+await p.evaluate(()=>document.activeElement.outerHTML));
  await p.setViewportSize({width:1300,height:900}); await settles(p);
  assert.equal(await p.locator('#site-nav').getAttribute('inert'),null);
  await p.getByRole('link',{name:'Get Voiid'}).focus(); await p.setViewportSize({width:800,height:900}); await settles(p);
  assert.equal(await toggle.evaluate(e=>e===document.activeElement),true, 'toggle focus: '+await p.evaluate(()=>document.activeElement.outerHTML));
  await toggle.focus(); await p.setViewportSize({width:1300,height:900}); await settles(p);
  assert.equal(await p.evaluate(()=>document.activeElement.getAttribute('aria-label')),'Voiid — home');
});
await browser.close(); await new Promise(resolve=>server.close(resolve)); await rm(temp,{recursive:true,force:true});
process.exitCode = failures ? 1 : 0;
