# Analytics on the website, not the apps

Status: decided
Date: 2026-11-10
Question: Should qot count visits with Plausible (as `www.abstractsyntax.llc`
does), and where: the website, the PWA, both?

## Answer

**The website only.** `www.quantumofthought.com` counts page views with
Plausible, in the company's Plausible account. The PWA and every other client
send nothing to Plausible, and the privacy policy says so (#61).

Plausible is proxied through the site's own origin by its Caddyfile
(`/js/script.js` and `/api/event` to `plausible.io`), so:

- nothing loads from another origin, and the CSP only gains
  `script-src 'self'; connect-src 'self'`;
- blockers of `plausible.io` don't skew the counts;
- only production counts: Caddy forwards events only for the
  `www.quantumofthought.com` host and answers `202` elsewhere (staging, local,
  CI), so one image serves both without configuration;
- Plausible sees the visitor's IP (from `X-Real-IP`, set by Railway's edge)
  only to tell visitors apart for a day; it sets no cookies.

## Why not the PWA

- **Its URLs carry secrets and identifiers.** `/auth/device?token=…` is a
  sign-in token and `/notes/<id>` names a note. Plausible's script sends
  `location.href`, so every route would need a scrubbed URL, or those leak to
  a third party.
- **The promise is worth more than the numbers.** For note capture meant to
  be end-to-end encrypted by default, "the apps send nothing to analytics" is
  simple and checkable.
- **Little to learn while dogfooding**: a handful of known users, and the
  server already sees active devices through `User-Agent`. If PWA analytics
  matter at launch, that is a new issue: proxied like the site, scrubbed URLs,
  `app.` as its own Plausible site, and the privacy policy changed to match.

## Options considered

- **Plausible's script from `plausible.io` directly.** One line, but a
  third-party origin in the CSP and counts lost to blockers.
- **No analytics.** The site was built that way; knowing whether anyone reads
  `/install` is worth one first-party script.

## Sources

- Plausible, proxying through Caddy: <https://plausible.io/docs/proxy/guides/caddy>
  (not re-verified against Caddy 2.10; the config was tested locally).
- Plausible's data policy: <https://plausible.io/data-policy>.
