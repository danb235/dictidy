import { chromium } from 'playwright';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const siteDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'site');
const mime = { '.html':'text/html','.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml','.png':'image/png','.woff2':'font/woff2','.json':'application/json','.xml':'application/xml','.txt':'text/plain' };
const server = http.createServer((req, res) => {
  let p = decodeURIComponent(req.url.split('?')[0]);
  if (p === '/') p = '/index.html';
  const fp = path.join(siteDir, p);
  if (!fp.startsWith(siteDir) || !fs.existsSync(fp) || fs.statSync(fp).isDirectory()) { res.writeHead(404); res.end('nf'); return; }
  res.writeHead(200, { 'content-type': mime[path.extname(fp)] || 'application/octet-stream' });
  fs.createReadStream(fp).pipe(res);
});
await new Promise(r => server.listen(0, r));
const port = server.address().port;
const browser = await chromium.launch();
const page = await browser.newPage();
const logs = [];
page.on('console', m => { if (m.type() === 'error') logs.push('console.error: ' + m.text()); });
page.on('pageerror', e => logs.push('PAGEERROR: ' + e.message));
await page.goto(`http://localhost:${port}/`, { waitUntil: 'networkidle' });
await page.waitForFunction(() => { const x = document.querySelector('#dc-root'); return x && x.textContent.length > 3000; }, { timeout: 30000 }).catch(() => logs.push('RENDER TIMEOUT: #dc-root did not populate'));
await new Promise(r => setTimeout(r, 1500));
const res = await page.evaluate(() => {
  const ld = [...document.querySelectorAll('script[type="application/ld+json"]')].map(s => { try { return JSON.parse(s.textContent)['@type']; } catch { return 'PARSE_ERROR'; } });
  return {
    dcRootTextLen: document.querySelector('#dc-root')?.textContent.length || 0,
    renderedHasH1: !!document.querySelector('#dc-root h1'),
    h1: document.querySelector('#dc-root h1')?.textContent.trim() || null,
    ldTypesInRenderedDOM: ld,
    prerenderStillPresent: !!document.querySelector('#__prerender'),
    title: document.title,
  };
});
console.log('CONSOLE ERRORS:', logs.length);
logs.forEach(l => console.log('  ' + l));
console.log(JSON.stringify(res, null, 2));
await browser.close();
server.close();
