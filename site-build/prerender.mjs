/**
 * Dictidy site prerender + structured-data build step.
 *
 * WHY: site/index.html is a Claude Design "Standalone HTML" export. It is a
 * client-side React app: on DOMContentLoaded the boot script does
 * `document.documentElement.replaceWith(...)` and renders the whole page with
 * JavaScript. Crawlers that DON'T run JS (GPTBot, ClaudeBot, PerplexityBot, and
 * Google's first indexing wave) therefore see only a loading splash and index
 * nothing. That makes Dictidy invisible to AI answer engines and hobbles SEO.
 *
 * WHAT THIS DOES (idempotent, safe to re-run after any re-export):
 *   1. Headless-renders the built site and captures the real, post-React DOM.
 *   2. Sanitizes it to clean semantic HTML and injects it into the INITIAL
 *      <body> (between markers). Non-JS crawlers now read full content. Human
 *      browsers run JS, which replaces the whole document, so they never see it
 *      (it sits behind the fixed splash and is discarded on DOMContentLoaded).
 *      Same content in both paths => this is prerendering, not cloaking.
 *   3. Injects JSON-LD (SoftwareApplication, Organization, WebSite, FAQPage)
 *      into the static <head> (for non-JS crawlers) AND into the bundler
 *      template <head> (so it survives into the rendered DOM for Googlebot).
 *   4. Adds a <noscript> rule so no-JS humans see the real content, not a splash.
 *
 * RUN:  npm install && npm run prerender   (from site-build/)
 * Re-run this after every Claude Design re-export + vendor surgery.
 */
import { chromium } from 'playwright';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const buildDir = path.dirname(fileURLToPath(import.meta.url));
const siteDir = path.resolve(buildDir, '..', 'site');
const indexPath = path.join(siteDir, 'index.html');
const SITE_URL = 'https://dictidy.com/';
const GH = 'https://github.com/danb235/dictidy';
const DOWNLOAD = `${GH}/releases/latest/download/Dictidy-macOS.zip`;

const mime = { '.html':'text/html','.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml','.png':'image/png','.woff2':'font/woff2','.json':'application/json','.xml':'application/xml','.txt':'text/plain' };

function serve(dir) {
  const server = http.createServer((req, res) => {
    let p = decodeURIComponent(req.url.split('?')[0]);
    if (p === '/') p = '/index.html';
    const fp = path.join(dir, p);
    if (!fp.startsWith(dir) || !fs.existsSync(fp) || fs.statSync(fp).isDirectory()) { res.writeHead(404); res.end('nf'); return; }
    res.writeHead(200, { 'content-type': mime[path.extname(fp)] || 'application/octet-stream' });
    fs.createReadStream(fp).pipe(res);
  });
  return server;
}

async function latestVersion() {
  try {
    const r = await fetch('https://api.github.com/repos/danb235/dictidy/releases/latest', { headers: { 'accept': 'application/vnd.github+json', 'user-agent': 'dictidy-build' } });
    if (!r.ok) return null;
    const j = await r.json();
    return (j.tag_name || '').replace(/^v/, '') || null;
  } catch { return null; }
}

// ---- render + extract -------------------------------------------------------
const server = serve(siteDir);
await new Promise(r => server.listen(0, r));
const port = server.address().port;

const browser = await chromium.launch();
const page = await browser.newPage();
await page.goto(`http://localhost:${port}/`, { waitUntil: 'networkidle' });
await page.waitForFunction(() => {
  const x = document.querySelector('#dc-root');
  return x && x.textContent && x.textContent.length > 3000;
}, { timeout: 30000 });
// let the hero typing animation settle on a stable frame
await new Promise(r => setTimeout(r, 1200));

const extracted = await page.evaluate(() => {
  const root = document.querySelector('#dc-root');
  const clone = root.cloneNode(true);

  // Turn FAQ accordions (button + hidden answer) into plain <h3>/<p> so the
  // questions and answers are readable text for crawlers.
  const faqSec = [...clone.querySelectorAll('section')].find(s => /questions, answered/i.test(s.textContent));
  const faqPairs = [];
  if (faqSec) {
    faqSec.querySelectorAll('button').forEach(btn => {
      const q = (btn.querySelector('span')?.textContent || btn.textContent || '').trim().replace(/\s+/g, ' ');
      // the answer is the text of the button's sibling container
      const item = btn.parentElement;
      const ans = [...item.querySelectorAll('p')].map(p => p.textContent.trim()).join(' ').replace(/\s+/g, ' ');
      if (q) faqPairs.push({ q, a: ans });
      const h3 = document.createElement('h3');
      h3.textContent = q;
      btn.replaceWith(h3);
    });
  }

  // Remove decorative / non-content nodes.
  clone.querySelectorAll('svg, style, script, noscript').forEach(el => el.remove());
  // Any remaining <button> -> unwrap to its text (e.g. "Copy").
  clone.querySelectorAll('button').forEach(btn => {
    const span = document.createElement('span');
    span.textContent = btn.textContent.trim();
    btn.replaceWith(span);
  });
  // Strip every attribute except href on links.
  clone.querySelectorAll('*').forEach(el => {
    [...el.attributes].forEach(a => { if (a.name !== 'href') el.removeAttribute(a.name); });
  });
  // Drop empty structural wrappers (keep table cells, br, links, headings).
  const keepEmpty = new Set(['TD','TH','BR','A','IMG','HR']);
  for (let pass = 0; pass < 3; pass++) {
    clone.querySelectorAll('div, span, p, li, ul, section, header, footer, nav').forEach(el => {
      if (!keepEmpty.has(el.tagName) && el.textContent.trim() === '' && el.children.length === 0) el.remove();
    });
  }

  return { html: clone.innerHTML, faq: faqPairs };
});

await browser.close();
server.close();

// ---- normalize the captured HTML -------------------------------------------
let content = extracted.html
  .replace(/\s+/g, ' ')                 // collapse whitespace
  .replace(/>\s+</g, '><')              // trim between tags
  .replace(/<span>([^<]*)<\/span>/g, '$1') // unwrap leaf spans -> plain text
  .replace(/<span>([^<]*)<\/span>/g, '$1') // second pass for nested
  .trim();

// ---- structured data --------------------------------------------------------
const version = await latestVersion();
const description = 'Dictidy is a free, open-source macOS app that turns your voice into clean, finished text anywhere you type, and rewrites text you have already written, all from one keyboard shortcut. Dictation runs on-device with Whisper; cleanup runs on-device or with your own Claude API key.';

const softwareApp = {
  '@context': 'https://schema.org',
  '@type': 'SoftwareApplication',
  name: 'Dictidy',
  operatingSystem: 'macOS 13.3+ (Apple Silicon)',
  applicationCategory: 'UtilitiesApplication',
  applicationSubCategory: 'Dictation and voice-to-text',
  url: SITE_URL,
  downloadUrl: DOWNLOAD,
  ...(version ? { softwareVersion: version } : {}),
  description,
  isAccessibleForFree: true,
  license: 'https://opensource.org/licenses/MIT',
  offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
  author: { '@type': 'Person', name: 'Daniel Bohannon', url: GH },
  sameAs: [GH],
};
const organization = {
  '@context': 'https://schema.org',
  '@type': 'Organization',
  name: 'Dictidy',
  url: SITE_URL,
  logo: 'https://dictidy.com/favicon.svg',
  sameAs: [GH],
};
const website = {
  '@context': 'https://schema.org',
  '@type': 'WebSite',
  name: 'Dictidy',
  url: SITE_URL,
};
const faqPage = {
  '@context': 'https://schema.org',
  '@type': 'FAQPage',
  mainEntity: extracted.faq.map(({ q, a }) => ({
    '@type': 'Question',
    name: q,
    acceptedAnswer: { '@type': 'Answer', text: a },
  })),
};

const schemas = [softwareApp, organization, website, faqPage];
// Escape < so the JSON can never contain a literal </script>.
const ldScripts = schemas
  .map(s => `<script type="application/ld+json">${JSON.stringify(s).replace(/</g, '\\u003c')}</script>`)
  .join('\n  ');

// ---- assemble injected blocks ----------------------------------------------
const HEAD_START = '<!--DICTIDY:SEO:START-->';
const HEAD_END = '<!--DICTIDY:SEO:END-->';
const BODY_START = '<!--DICTIDY:PRERENDER:START-->';
const BODY_END = '<!--DICTIDY:PRERENDER:END-->';

// Note on visibility: the prerendered content sits in normal flow but is
// covered by the pre-existing opaque fixed splash (#__bundler_thumbnail,
// inset:0, z-index:9999), so human browsers never see it, and on
// DOMContentLoaded the boot script replaces the whole document (removing it).
// We deliberately do NOT use a 1px/offscreen/display:none hide, which Google's
// raw-HTML heuristics can read as hidden-text cloaking. For no-JS humans the
// <noscript> rule below drops the splash so they get the real content.
const headBlock =
`${HEAD_START}
  ${ldScripts}
  <noscript><style>#__bundler_thumbnail,#__bundler_loading{display:none!important}</style></noscript>
  ${HEAD_END}`;

const bodyBlock =
`${BODY_START}
<main id="__prerender">
${content}
</main>
${BODY_END}`;

// ---- inject into index.html (idempotent) -----------------------------------
let doc = fs.readFileSync(indexPath, 'utf8');

// 1) static <head> block
if (doc.includes(HEAD_START)) {
  doc = doc.replace(new RegExp(HEAD_START.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '[\\s\\S]*?' + HEAD_END.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), headBlock);
} else {
  doc = doc.replace('</head>', `  ${headBlock}\n</head>`);
}

// 2) initial <body> prerender block (right after the opening <body> tag)
if (doc.includes(BODY_START)) {
  doc = doc.replace(new RegExp(BODY_START.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '[\\s\\S]*?' + BODY_END.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), bodyBlock);
} else {
  doc = doc.replace(/<body>/, `<body>\n${bodyBlock}`);
}

// 3) schema into the bundler template <head> (survives JS render for Googlebot)
doc = doc.replace(/(<script type="__bundler\/template">\s*)([\s\S]*?)(\s*<\/script>)/, (m, open, jsonStr, close) => {
  let template = JSON.parse(jsonStr);
  const tHeadStart = '<!--DICTIDY:SEO:START-->';
  const tHeadEnd = '<!--DICTIDY:SEO:END-->';
  const tBlock = `${tHeadStart}${ldScripts}${tHeadEnd}`;
  if (template.includes(tHeadStart)) {
    template = template.replace(new RegExp(tHeadStart.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '[\\s\\S]*?' + tHeadEnd.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')), tBlock);
  } else {
    template = template.replace('</head>', `${tBlock}</head>`);
  }
  // Re-encode; escape </ so the embedded HTML can't close the outer <script>.
  const encoded = JSON.stringify(template).replace(/<\//g, '<\\/');
  return open + encoded + close;
});

fs.writeFileSync(indexPath, doc);

console.log('Prerender complete.');
console.log('  content chars :', content.length);
console.log('  FAQ pairs     :', extracted.faq.length);
console.log('  version       :', version || '(none)');
console.log('  schemas       :', schemas.map(s => s['@type']).join(', '));
