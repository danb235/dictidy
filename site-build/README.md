# Site tooling

The marketing site is plain static HTML and CSS in `site/`. It needs no browser framework, compiler, hydration, prerender step, external fonts, or dependency installation. People and crawlers receive the same content.

- `npm run verify`: check metadata, structured data, internal links and anchors, image accessibility attributes, sitemap coverage, CSP, payload budgets, and accidental private/development files in the deployment directory. Fails on violations. This also runs before Cloudflare deployment.
- `npm run preview`: serve `site/` at `http://127.0.0.1:4173`, including extensionless URLs, security headers, and a real custom 404 response. Check desktop/mobile layouts and keyboard navigation in a browser.

`social-card.svg` is the editable source for the 1200×630 social preview. On macOS, regenerate it with `sips -s format png social-card.svg --out ../site/og-image.png`. Keep PNG metadata and page descriptions current when the proposition changes.

Only `site/` is published. Tooling stays outside it. Cloudflare injects its configured Web Analytics beacon in production; local preview does not include it.
