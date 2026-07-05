# Website operations (maintainers)

> Internal maintainer notes for the marketing site. This is deliberately kept
> **out of the product README and release notes**, which stay product-only.

The marketing site at **[dictidy.com](https://dictidy.com)** lives in [`site/`](site/) and deploys to
**Cloudflare Pages** (project `dictidy`) via [`.github/workflows/deploy-site.yml`](.github/workflows/deploy-site.yml).

## Layout

- **`site/index.html`** is a single self-contained file (fonts and everything inlined, no external
  dependencies), exported from Claude Design as "Standalone HTML". To update the design, edit it there
  and re-export over `site/index.html`. `site/_headers` (security + cache headers), `robots.txt`,
  `sitemap.xml`, `favicon.svg`, and `og-image.png` round out the deploy.
- **`site-build/`** holds build tooling and lives **outside** `site/` so it is never uploaded to
  Cloudflare Pages and never retriggers a deploy.

## Prerender for SEO / AI crawlers

The export is a client-side React app, so crawlers that do not run JavaScript (GPTBot, ClaudeBot,
PerplexityBot, Google's first wave) would see only a splash. [`site-build/prerender.mjs`](site-build/README.md)
headless-renders the page and injects a static, crawlable copy of the content plus JSON-LD structured
data into `index.html`.

**Re-run it after every re-export** (and after the vendor surgery below):

```sh
cd site-build && npm install && npm run prerender   # rewrites ../site/index.html in place
node verify.mjs                                      # optional: asserts it still boots + schema present
```

The prerendered output is committed, so nothing runs in CI.

## Self-contained vendoring

`site/index.html` must have zero third-party requests. The Claude Design export loads
React/ReactDOM/Babel from unpkg.com (the URLs are gzip-compressed inside the bundler manifest), so after
each re-export you must re-vendor them into `site/vendor/` and rewrite those URLs to same-origin. See the
project memory notes for the exact surgery.

## Deploys

Deploys run only when `site/**` changes: push to `main` -> production (dictidy.com); a PR that touches
`site/` -> a preview URL commented on the PR. No build step in CI (the committed file is already
prerendered and vendored).

## One-time setup

Create a Cloudflare Pages project named `dictidy` (Direct Upload) and a **scoped API token**
(`Account -> Cloudflare Pages -> Edit`, nothing else). Add them as **Environment secrets** on the
`production` and `preview` GitHub environments: `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`.
Attach the custom domain `dictidy.com` (plus a `www` -> apex redirect) in the Pages project.

## Security (public repo)

GitHub secrets are write-only and are withheld from forked-PR runs; the workflow uses `pull_request`
(never `pull_request_target`) and guards the deploy job to same-repo branches, so a fork PR can never run
with the token. `main` is protected (PR + review, no direct pushes), the `production` environment is
restricted to `main` with a required reviewer, `v*` tags are protection-ruled to maintainers, and
[`CODEOWNERS`](.github/CODEOWNERS) requires review on `.github/workflows/**` and `site/_headers`. The
token is least-privilege (Pages-only) and revocable.
