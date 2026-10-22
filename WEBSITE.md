# Website operations and audit

The marketing site at [dictidy.com](https://dictidy.com) lives in `site/` and deploys to the existing Cloudflare Pages project `dictidy` through `.github/workflows/deploy-site.yml`.

## Editing and deployment

The site is static HTML plus one shared stylesheet. Edit the HTML directly; there is no framework, bundler, font download, or prerender step. All content works without JavaScript. The only production script is the existing Cloudflare-injected Web Analytics beacon.

- `site/index.html`: homepage; three workflows, features, privacy summary, costs, setup, FAQ, and guides.
- Six guide pages retain their existing extensionless URLs.
- `privacy.html`, `terms.html`, `contact.html`: data handling, MIT license/use terms, verified project contact channels.
- `404.html`: real missing-page handling; prevents Pages' default SPA fallback from returning the homepage for unknown paths.
- `styles.css`, `favicon.svg`, `og-image.png`: shared assets. Social-card source lives in `site-build/social-card.svg`.
- `_headers`, `robots.txt`, `sitemap.xml`: hosting headers and discovery. Hostname redirects are configured in Cloudflare zone-level Redirect Rules, outside the Pages deployment.

Run `node site-build/verify.mjs`. Preview with `node site-build/serve.mjs` (default `http://127.0.0.1:4173`; set `DICTIDY_PREVIEW_PORT` if occupied). Check representative desktop and mobile layouts, keyboard navigation, FAQ disclosure, internal links, and no JavaScript errors. The verification script also runs before uploads and rejects hidden/development files, symlinks, and common credential patterns in `site/`.

A same-repository PR produces a Cloudflare preview. Merge to `main` triggers production, subject to repository review and the production environment's required reviewer. Use the established review flow; do not weaken branch or environment protections. After deployment, verify apex HTTPS, HTTP/www redirects, 404 status, security headers, and the analytics beacon. The public download always points to the latest GitHub release rather than a hardcoded version.

Cloudflare Pages `_redirects` supports path sources only; a source such as `https://www.dictidy.com/*` is ignored. The active zone-level Single Redirect is named `Dictidy www to apex`: match `(http.host eq "www.dictidy.com")`, target `concat("https://dictidy.com", http.request.uri.path)`, status 301, Preserve query string enabled. Follow [Cloudflare's www-to-apex guide](https://developers.cloudflare.com/pages/how-to/www-redirect/) and verify the actual HTTP status and `Location` header on both the root and a nested URL. Verified live on October 22, 2026: HTTP and HTTPS www requests redirect to the apex with the original path and query string; apex requests remain 200. Future `_redirects` files are allowed for path redirects, and the deploy verifier rejects domain sources.

Keep API tokens only in GitHub environment secrets (`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`). Only `site/` is uploaded; `.env` files must never enter that directory. Production is restricted to `main`; preview secrets are withheld from fork PRs.

## Marketing strategy — reviewed October 22, 2026

The accurate proposition is **free, open-source Mac dictation and text rewriting, right where you type**. The key distinction must remain visible near the first download button: **speech transcription runs on your Mac; AI cleanup/rewriting uses your Anthropic or OpenAI API key, with provider charges**.

Lead with the outcome and demonstrate it. Then explain the three actions separately: Dictate, Dictate + Clean, and selected-text rewriting. Emphasize configurable instructions/models, local audio, and recovery/history. Keep the single primary conversion action **Download for Mac**; setup, documentation, source, and comparisons support that decision.

Do not restore obsolete local-Qwen cleanup, fully offline rewriting, automatic provider fallback, one-minute setup, unlimited recording length, universal app compatibility, or unique selected-text rewriting claims. Do not imply a chat subscription includes API billing. Do not claim open source proves installation is safe. The app is currently self-signed and not Apple-notarized.

Research showed competing apps now also rewrite selected text, and some provide local transcription free. Comparisons therefore explain fit and tradeoffs rather than unsupported superiority or brittle price tables. Exact competitor features/prices should be rechecked when editing.

### Source references

- [Wispr Flow product updates / Transforms](https://wisprflow.ai/whats-new): selected-text rewriting is no longer a unique Dictidy feature.
- [superwhisper plans](https://superwhisper.com/docs/billing/plans): local dictation and plan tradeoffs.
- [Apple Dictation](https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac) and [Writing Tools](https://support.apple.com/guide/mac-help/writing-tools-write-improve-summarize-mchldcd6c260/mac): distinguish speech input from rewriting.
- [VoiceInk](https://tryvoiceink.com/): additional open-source alternative with text rewriting.
- [Google descriptive page titles and metadata](https://developers.google.com/search/docs/fundamentals/get-started-developers) and [snippets](https://developers.google.com/search/docs/appearance/snippet): unique, descriptive metadata and visible crawlable content.
- [Web accessibility color/contrast](https://web.dev/articles/color-and-contrast-accessibility): readable text, focus and interaction cues.
- [Cloudflare Pages headers](https://developers.cloudflare.com/pages/configuration/headers/) and [serving Pages](https://developers.cloudflare.com/pages/configuration/serving-pages/): scoped headers and custom 404 behavior.
- [Cloudflare Analytics FAQ](https://developers.cloudflare.com/web-analytics/faq/) and [beacon collection](https://developers.cloudflare.com/speed/observatory/rum-beacon/): CSP origins, aggregate metrics and no cookie/browser-storage tracking.
- [ICO storage/access technologies guidance](https://ico.org.uk/for-organisations/direct-marketing-and-privacy-and-electronic-communications/guide-to-pecr/cookies-and-similar-technologies/): reassess privacy notice and consent if browser storage or additional tracking is introduced; a generic banner is not a substitute for evaluating actual technology.

## Checklist decisions

Duplicate checklist entries are combined below. These decisions cover the public marketing site, not a full penetration test of the native app or hosting account.

| Requested item | Decision for this app/site |
|---|---|
| Privacy policy | Added. Separates local audio, online rewriting, Keychain keys, default-on plaintext history, provider policies, hosting logs and website analytics. |
| Terms & conditions | Added plain-language use terms with the existing MIT license and its warranty terms, AI review guidance and provider billing. No invented jurisdiction or new license restrictions. |
| Real contact address | Added verified GitHub maintainer, support and private security-report channels. No support email or postal address is documented; do not invent one. Publish one if the maintainer supplies it. |
| Frontend secrets / secure API keys / never hardcode secrets | No app/provider keys in website. App uses macOS Keychain. Hosting token stays in GitHub secrets. Deploy check rejects common key patterns. |
| Hide all .env files | Added broad `.env`, credential and private-key ignores; deploy validation also rejects hidden files because ignored files can otherwise still be uploaded. |
| Check Git history for secrets | Targeted scan of tracked files and reachable historical blobs, including the old compressed manifest, found no matching secrets. Pattern-based scan is not an exhaustive guarantee. |
| Enforce HTTPS | Existing HTTP-to-HTTPS redirect verified; added one-year HSTS without preload/subdomain scope. www-to-apex is enforced by an active Cloudflare Single Redirect; HTTP/HTTPS, root/nested paths and query preservation were verified. Pages `_redirects` cannot implement domain redirects. |
| Security headers / restrict CORS | Strict CSP removes inline/eval/blob execution; denies frames, objects and forms; limits capabilities. Only the existing Cloudflare analytics origins are permitted. Public static files do not need private-API CORS rules; CORS is not authorization. |
| Cookie consent banner | Omitted for current no-cookie/no-browser-storage analytics. No advertising pixels. Reassess actual legal/consent requirements before adding different tracking. |
| Analytics installed | Existing Cloudflare-injected Web Analytics discovered and allowed by scoped CSP; policy discloses it. Use aggregate traffic/referrers/Core Web Vitals and GitHub release downloads. No custom click/session tracking or cookie identifiers. Dashboard receipt is an account-side check. |
| Meta title / description every page | Unique titles and descriptions on all 11 HTML pages; 404 is noindex. |
| Social/Open Graph preview | New 1200×630 PNG and consistent OG/Twitter metadata with descriptive image alt text. |
| Favicon | Retained branded SVG, consistently referenced. |
| Sitemap and robots.txt | Updated sitemap includes ten indexable pages, excludes 404, uses canonical URLs. Robots points to sitemap. |
| Image alt text | Decorative brand icons use empty alt beside visible brand text; social image has descriptive alt metadata. Dimensions prevent layout shifts. |
| Image compression | Removed the giant bundled page/runtime; SVG icons and system fonts; compact PNG social card is not downloaded by normal page visits. |
| Page load speed | Static HTML/CSS replaces ~3.8 MB of old homepage + runtime source. Homepage + CSS are ~30 KB raw / ~9 KB gzip, before favicon and analytics. No app-rendering JS, spinner, hydration or font dependencies. Browser checks are lab checks, not a field Core Web Vitals claim. |
| Color contrast | Higher-contrast text, darker primary button, visible focus rings, non-color interaction cues. Primary/secondary text and button palette meet WCAG AA text thresholds. |
| Mobile responsiveness / breakpoints | Responsive single-column layout, scrollable comparison tables, viewport metadata, safe-area spacing and desktop/mobile visual checks. |
| Sticky mobile CTA | Added a persistent download action with Mac compatibility context; content/footer has bottom space. |
| CTA above fold / single clear CTA | Consistent Download for Mac in header, hero, installation and mobile bar; same latest-release destination. |
| Custom 404 | Added helpful recovery links and noindex; true 404 status checked with preview/live response. |
| Broken links | Internal links, fragments, sitemap paths and assets checked automatically. Official research links checked; latest release asset used for download. |
| Loading states | No client-rendered loading state required. HTML content arrives directly; links use browser-native navigation/download behavior. |
| Form validation / errors / thank-you page | Not applicable: no site forms or submissions. Support is handled on GitHub. |
| Spam protection | No public submission endpoint. No CAPTCHA added to a download website. |
| Add authentication / protect admin routes | Not applicable: public read-only website has no accounts/admin app. Hosting and repository access remain authenticated and protected. |
| Server-side permission checks / do not trust frontend IDs | No user IDs, protected API or authorization decisions in website. Required if such services are introduced later. |
| Isolate user data / lock database / Firebase / Supabase / storage | No website database, user records, Firebase, Supabase or user storage buckets. Do not create these merely to satisfy a checklist. |
| Validate inputs server-side / sanitize content / SQL and NoSQL injection | No server processing of visitor content and no database queries. Content is maintained in source control. |
| Secure uploads | No visitor upload capability. Only reviewed static deployment files are published. |
| Rate-limit login and signup | No login/signup endpoints. Hosting platform protections remain in place. |
| Disable debug / hide detailed errors | No production application debug mode/source maps. Static 404 reveals no stack traces. Tooling stays outside deploy directory. |
| Test as an untrusted visitor | Public page, direct URLs, 404, secret-file paths, navigation, mobile and security-header checks. No account needed. |

Policies describe the current implementation; they are not a claim of regulatory certification. Update the policy and checks when data flows change.
