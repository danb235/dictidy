import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
const site = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../site');
const files = fs.readdirSync(site, {recursive:true}).map(String);
const pages = files.filter(f => f.endsWith('.html'));
const sources = new Map(pages.map(f => [f, fs.readFileSync(path.join(site, f), 'utf8')]));
const titles = new Set(), descriptions = new Set();
let links = 0;
for (const f of files) {
  const full = path.join(site, f);
  assert(!fs.lstatSync(full).isSymbolicLink(), `Symlink cannot be deployed: ${f}`);
  assert(!/(^|\/)(\.|node_modules|marketing|cov)|\.(pem|key|p12|pfx|mobileprovision|map|log)$/i.test(f), `Private or development file in deploy directory: ${f}`);
  if (!fs.statSync(full).isFile()) continue;
  const content = fs.readFileSync(full, 'utf8');
  assert(!/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bsk-(?:ant-api\w*-|proj-)[A-Za-z0-9_-]{20,}|\bgh[pousr]_[A-Za-z0-9]{30,}/.test(content), `Potential credential in ${f}`);
}
const attrs = tag => Object.fromEntries([...tag.matchAll(/([\w:-]+)\s*=\s*["']([^"']*)["']/g)].map(m => [m[1], m[2]]));
for (const [f, html] of sources) {
  assert.match(html, /<html lang="en">/, `${f}: language`);
  assert.equal((html.match(/<h1\b/g)||[]).length, 1, `${f}: one H1`);
  assert.equal((html.match(/<main\b/g)||[]).length, 1, `${f}: one main`);
  assert.match(html, /class="skip-link" href="#main"/, `${f}: skip link`);
  const title = html.match(/<title>(.*?)<\/title>/s)?.[1];
  assert(title && !titles.has(title), `${f}: unique title`); titles.add(title);
  const metas = [...html.matchAll(/<meta\b[^>]*>/g)].map(m => attrs(m[0]));
  const meta = name => metas.find(m => m.name === name || m.property === name)?.content;
  const description = meta('description');
  assert(description && !descriptions.has(description), `${f}: unique description`); descriptions.add(description);
  assert(meta('viewport'), `${f}: viewport`);
  if (f !== '404.html') {
    const expected = 'https://dictidy.com/' + (f === 'index.html' ? '' : f.replace(/\.html$/, ''));
    assert(html.includes(`rel="canonical" href="${expected}"`), `${f}: canonical`);
    for (const name of ['og:title','og:description','og:image','og:image:alt','twitter:card','twitter:image','twitter:image:alt']) assert(meta(name), `${f}: ${name}`);
    assert(html.includes('releases/latest/download/Dictidy-macOS.zip'), `${f}: working download destination`);
  } else assert.equal(meta('robots'), 'noindex');
  assert.match(html, /rel="icon"/, `${f}: favicon`);
  assert(!/<style\b|\sstyle=|\son\w+=/i.test(html), `${f}: inline CSS or handlers violate CSP`);
  for (const [,tag,body] of html.matchAll(/(<script\b[^>]*>)([\s\S]*?)<\/script>/g)) {
    assert.equal(attrs(tag).type, 'application/ld+json', `${f}: executable script is unexpected`);
    JSON.parse(body);
  }
  for (const m of html.matchAll(/<img\b[^>]*>/g)) {
    const a=attrs(m[0]); assert('alt' in a, `${f}: image alt`); assert(a.width && a.height, `${f}: image dimensions`);
  }
  const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]);
  assert.equal(ids.length, new Set(ids).size, `${f}: duplicate ID`);
  for (const m of html.matchAll(/<(?:a|link|img)\b[^>]*>/g)) {
    const a=attrs(m[0]), dest=a.href || a.src;
    if (!dest) continue;
    assert(!dest.startsWith('http:'), `${f}: insecure link`);
    const url = new URL(dest, 'https://dictidy.com/' + (f === 'index.html' ? '' : f.replace(/\.html$/, '')));
    if (url.origin !== 'https://dictidy.com') continue;
    let target = decodeURIComponent(url.pathname).replace(/^\//,'') || 'index.html';
    if (!path.extname(target)) target += '.html';
    assert(fs.existsSync(path.join(site,target)), `${f}: missing ${dest}`);
    if (url.hash) assert(sources.get(target)?.includes(`id="${url.hash.slice(1)}"`), `${f}: missing anchor ${dest}`);
    links++;
  }
}
const sitemap = fs.readFileSync(path.join(site,'sitemap.xml'),'utf8');
for (const f of pages.filter(p=>p!=='404.html')) assert(sitemap.includes(`<loc>https://dictidy.com/${f==='index.html'?'':f.replace(/\.html$/,'')}</loc>`), `${f}: missing from sitemap`);
assert(!sitemap.includes('404'), '404 must not be indexed');
const headers = fs.readFileSync(path.join(site,'_headers'),'utf8');
assert(!/unsafe-inline|unsafe-eval|\bblob:/.test(headers), 'Unsafe CSP exception');
for (const h of ['Content-Security-Policy','Strict-Transport-Security','X-Content-Type-Options','Permissions-Policy']) assert(headers.includes(h), `Missing ${h}`);
const home=fs.readFileSync(path.join(site,'index.html'));
const css=fs.readFileSync(path.join(site,'styles.css'));
assert(home.length < 40000 && css.length < 20000, 'Static homepage performance budget exceeded');
console.log(`PASS: ${pages.length} pages; ${links} internal links/assets/anchors; metadata, structured data, sitemap, security and deploy file checks.`);
console.log(`Homepage ${home.length} bytes (${zlib.gzipSync(home).length} gzip); CSS ${css.length} bytes (${zlib.gzipSync(css).length} gzip).`);
