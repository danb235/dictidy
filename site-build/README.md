# Site build tooling

The marketing site (`site/index.html`) is a Claude Design "Standalone HTML"
export: a client-side React app. Crawlers that do not run JavaScript (GPTBot,
ClaudeBot, PerplexityBot, and Google's first indexing wave) would otherwise see
only a loading splash. `prerender.mjs` fixes that.

## What `prerender.mjs` does

1. Headless-renders the built site (Playwright/Chromium) and captures the real,
   post-React DOM.
2. Injects a sanitized, semantic copy of that content into the initial `<body>`
   so non-JS crawlers read the full page. Human browsers run JS, which replaces
   the whole document, so they never see it (it sits behind the existing splash
   and is discarded on `DOMContentLoaded`). Same content both ways: this is
   prerendering, not cloaking.
3. Injects JSON-LD (`SoftwareApplication`, `Organization`, `WebSite`,
   `FAQPage`) into the static `<head>` **and** into the bundler template head,
   so the structured data survives into the rendered DOM for Googlebot.
4. Adds a `<noscript>` rule so no-JS humans get the real content, not a splash.

It is **idempotent** (marker-delimited blocks) and safe to re-run.

## When to run it

After **every** Claude Design re-export of `site/index.html` (and after the
vendor surgery described in the repo README). The prerendered output is
committed, so no build step runs in CI.

```bash
cd site-build
npm install          # first time only (installs Playwright + Chromium)
npm run prerender    # rewrites ../site/index.html in place
node verify.mjs      # optional: confirms it still boots + schema is present
```

This tooling lives **outside** `site/` on purpose: the Cloudflare Pages deploy
uploads `site/` verbatim, so keeping the build scripts here means they are never
published to dictidy.com and never retrigger a deploy.

`verify.mjs` renders the built page and asserts: 0 console errors, `#dc-root`
populates, all four JSON-LD types are present in the rendered DOM, and the
`#__prerender` block is discarded for human (JS) visitors.

`node_modules/` is gitignored; `package-lock.json` is committed for reproducible
installs.
