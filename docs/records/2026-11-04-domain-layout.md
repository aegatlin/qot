# Domain layout

Status: decided; where `app.` and `www.` run is settled in
`2026-11-06-hosting-the-pwa-and-website.md`, and sign-in links move to `app.`
in `2026-11-06-sign-in-through-the-pwa.md`
Date: 2026-11-04
Question: How should `quantumofthought.com` be split between the sync API, a
future PWA, the marketing page and mail?

## Answer

One hostname per job, so each can live on whatever host suits it and move
without touching the others:

| Host | What | Runs on |
|---|---|---|
| `quantumofthought.com` (and `www`) | Marketing page | Any static host |
| `app.quantumofthought.com` | PWA | Static files, or the Phoenix server |
| `api.quantumofthought.com` | Sync API, WebSocket, the device sign-in page | Railway `server`, production |
| `staging-api.quantumofthought.com` | Same, staging | Railway `server`, staging |
| `staging-app.quantumofthought.com` | PWA, staging (when it exists) | Like `app.` |
| `mail.quantumofthought.com` | Resend sending domain | Resend (set up in #5) |

Staging names are flat (`staging-api`, not `api.staging`): one label each.
The Railway-generated `*.up.railway.app` hosts keep working alongside the
custom ones, which costs nothing and keeps a fallback.

## Why separate hosts are cheap here

Every client authenticates with a Bearer token, not a cookie. A PWA on `app.`
calling `api.` is a plain cross-origin setup: no shared cookie domain, no
CSRF. The server will need CORS for `https://app.quantumofthought.com` and
must accept that origin in the WebSocket `check_origin`. Native clients (CLI,
iOS) send no `Origin` and are unaffected.

Keeping the marketing page off the API host means it can be rebuilt on
anything, including a site builder, without risk to the API.

## Hard to change later

1. **The PWA's origin is permanent.** IndexedDB, the service worker and
   home-screen installs belong to one origin. Moving the PWA later would
   strand unsynced offline notes and break installs. It is `app.`, decided
   now, before the PWA exists.
2. **Sign-in links point at the API host.** Emailed links go to
   `https://api.quantumofthought.com/auth/device?token=…` (built from
   `PHX_HOST`). They expire in 15 minutes, so moving the sign-in page to
   `app.` later is possible, but cheapest before launch.
3. **iOS associated domains.** Universal Links (e.g. a sign-in link opening
   the app) need `/.well-known/apple-app-site-association` on one of these
   hosts. Use `app.` or `api.`, not a host that might be handed to a
   third-party site builder.
4. **The apex can't be a CNAME.** PaaS hosts, Railway included, give a
   CNAME target. For the marketing page (#19), either use a host that gives
   A records (GitHub Pages, Squarespace itself) or move DNS to a provider
   with CNAME flattening or ALIAS records (e.g. Cloudflare). Not verified:
   whether Squarespace DNS supports ALIAS. `api.` and `app.` are ordinary
   CNAMEs and don't care.

## Options considered

- **One host, paths for each job** (`quantumofthought.com/api`, `/app`):
  needs a reverse proxy in front of everything, ties the marketing page to
  the server's deploys, and makes the PWA's origin the same as the marketing
  page's, so third-party scripts on the marketing page would share its
  storage. Turned down.
- **PWA served by Phoenix on `app.`**: still open. It means one deploy and one
  host, and CORS still applies because the origin differs. Moving it to a
  static host or CDN later is a DNS change, not an origin change.

## Today

DNS is hosted by Squarespace (nameservers `ns-cloud-d*.googledomains.com`).
`api.` and `staging-api.` are #10. The rest waits until its client exists.
