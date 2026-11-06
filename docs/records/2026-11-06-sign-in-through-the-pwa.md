# Sign-in through the PWA

Status: decided
Date: 2026-11-06
Question: How does a new user who signs in from the CLI end up signed in to
the PWA too, without a second email and code?

## Answer

**The emailed sign-in page moves into the PWA, and typing the right code there
signs in that browser as well as the device that asked.**

1. The CLI (or any device) starts a sign-in as today and shows the user code.
2. The email links to `https://app.quantumofthought.com/auth/device?token=…`
   (built from a new `APP_URL`; `PHX_HOST` stays the API host).
3. The PWA's page asks for the code and sends it with the link token to
   `POST /api/auth/device/approve`. A correct code approves the device that
   asked, and the response gives this browser its own tokens.
4. The page says "You're signed in. Return to your terminal; this browser is
   signed in too," with the notes list beside it. The first `qot get milk` in
   the terminal appears in the tab.

An "also sign in this browser" checkbox, on by default, covers a shared or
borrowed computer. Implementation: #51.

## Why

Onboarding is where qot shows what it is: capture anywhere, and it's
everywhere. Signing in once and then watching a note typed in the terminal
appear in a browser tab is the demonstration. With a PWA that is a separate
device, that moment costs a second email and a second code. When the iOS app
arrives, its sign-in can end the same way.

The domain record already noted that moving the sign-in page to `app.` is
"possible, but cheapest before launch" (`2026-11-04-domain-layout.md`). It is
before launch.

## Is it still safe?

The sign-in rules in CLAUDE.md stay true:

- **Opening the link approves nothing and returns nothing.** Tokens come only
  from a POST with the right code. Mail scanners that prefetch links get a
  page, not a session.
- **Someone who starts a sign-in with your address still can't get in.** They
  have the code but not the link, which is in your inbox. You opening their
  email gets you a form you can't fill.
- **Five wrong codes deny it; it expires after 15 minutes; it is used once.**

What is new: whoever holds both the link and the code gets a browser session,
not only the device that asked. Holding both already meant approving that
device, which is the whole account, so the browser session gives away nothing
new. If someone tricks you into typing their code, their device gets in (as
today) and the browser session lands with you, not them.

## Costs

- **Signing in needs the PWA up.** The page no longer comes from the API
  server. Mitigation: it's a static page behind a health check, and the old
  server page stays as a redirect, so a failed PWA deploy is visible at once.
- **A browser gets signed in that the person may not have wanted**, e.g. the
  email opened on a phone. The checkbox, and the success page saying so
  plainly, with a way to sign that browser out.
- **More moving parts in one flow**: CORS, the PWA, the API. Covered by the
  end-to-end check (CLI plus headless Chromium) that CLAUDE.md describes,
  moved to the PWA's page.

## Options considered

- **Keep the page on `api.` and add an "open the web app, signed in" button**
  that hands a one-time code to `app.` in the URL. Smaller server change, but
  a new kind of token in a URL (history, referrers, logs) to secure, and the
  page and the app would still look like two products.
- **The PWA signs in on its own, as a separate device.** No server change; a
  second email and code at the very moment that should feel effortless.
- **A cookie shared across `*.quantumofthought.com`.** Every client uses
  Bearer tokens precisely to avoid cookies and CSRF; turned down.
