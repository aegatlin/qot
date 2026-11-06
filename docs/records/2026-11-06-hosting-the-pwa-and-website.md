# Hosting the PWA and the website

Status: decided
Date: 2026-11-06
Question: Where do the PWA (`app.quantumofthought.com`) and the website
(`www.quantumofthought.com`) run: on the Phoenix server that serves the API,
or somewhere else?

## Answer

**Each is its own small static service in the existing Railway project**, next
to `server` and `Postgres`:

| Service | Folder | Hosts | Releases |
|---|---|---|---|
| `server` | `server_web/` | `api.`, `staging-api.` | `server/v*` tags (unchanged) |
| `web` | `client_web/` | `app.`, `staging-app.` | `web/v*` tags |
| `site` | `site_web/` | `www.` (canonical), `staging-www.`; the apex redirects to `www.` | `site/v*` tags |

Each image is a static build behind a small file server (Caddy), with its own
health check, watch patterns on staging and release workflow for production,
mirroring the server's (`release-server.yml`: a tag on `main` moves a
production branch that Railway deploys). Railway's environments already pair
the services, so `staging-app.` talks to `staging-api.` with no extra setup.

This settles the question the domain record left open ("PWA served by Phoenix
on `app.`: still open", `2026-11-04-domain-layout.md`).

Issues: #53 (the PWA's image and release workflow), #54 (the Railway service
and DNS), #19 (the website).

## Why not Phoenix

Serving the PWA from the API server looks like one deploy and one host, but:

- **The build gets heavy.** The server image is built from `server_web/` with
  Elixir only. The PWA needs Rust (`qot_core` compiled to WASM) and Node to
  build, so the server image would need both, and its build context would
  become the repo root.
- **Releases couple.** A PWA fix would need a `server/v*` tag to reach
  production, and every server release would redeploy the PWA.
- **Staging would miss PWA changes.** Staging redeploys only when
  `server_web/` changes; the watch pattern would have to grow.
- **One app, two sites.** Phoenix would route by host and need different
  security headers for each (the PWA wants a CSP built for a single-page app;
  the API wants none of that).
- **Little is saved.** CORS is needed either way, because `app.` and `api.`
  are different origins whoever serves them.

Separate services make the PWA's host a detail. Its origin (`app.`) is what
must never change; moving it later to a CDN is a DNS change, not an origin
change.

## Why the website is the same shape, not GitHub Pages

GitHub Pages was the first suggestion (free, the repo is public, and it gives A
records for the apex). It was turned down because the website is going to grow
into the place where people install every client and find the privacy
policy, terms and support page that the App Store asks for. A static site
generator gives it that structure on any host; what tips it to Railway is one
pattern for every web property: the same image shape, staging environment,
release workflow and smoke test as the PWA, in one place. Nothing the website
needs (install pages, policies, support) needs a server; if something ever
does (a contact form, a waitlist), it belongs on the API.

The one cost is the apex domain: Railway gives a CNAME target, and the apex
can't be a CNAME. So `www.` is canonical, and the apex redirects to it, either
with Squarespace's domain forwarding (not verified that it keeps the other DNS
records intact) or by moving DNS to a provider with CNAME flattening
(Cloudflare), carrying over the Resend and DMARC records. Decided in #19, by a
person.

## Options considered

- **Phoenix serves the PWA.** Turned down, above.
- **A CDN host for the PWA (Cloudflare Pages, Netlify, Vercel).** Fast,
  previews per PR, free tiers. Turned down for now: another vendor and account
  to manage while dogfooding, and its staging story would need wiring to
  Railway's. Still an easy move later, since the origin doesn't change.
- **GitHub Pages for the website.** Turned down, above. Also: one site per
  repo, so staging would need a second repo or a different host.
- **One static service serving both `app.` and `www.`.** Saves a service, but
  ties the website's releases to the PWA's, and the two have different
  headers and caching. Not worth it.

## Not verified

- Railway's price for two small always-on static services (expected to be
  small: a static server idles at a few MB of memory).
- Squarespace domain forwarding for the apex alongside the existing records.
