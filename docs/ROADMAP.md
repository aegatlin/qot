# Roadmap

The order of work and why. Each step is tracked as a GitHub issue
(`gh issue list`); this file is the map, the issues are the list. When you
come back to the repo, start with the first open issue in the next unfinished
step. Keep the CLAUDE.md "Product" section in sync when priorities change.

## Where things stand (2026-11-06)

| Piece | State |
|---|---|
| `qot_core` | Done for v1: note model, tombstones, sync primitives, `qot_core::sync`. |
| CLI (`qot`) | Feature-complete for v1: add/get, list, delete, login/logout/sync, offline capture, `--version`. Not distributed; signs in to production by default (#12). |
| Sync server | Feature-complete for v1 and live at `api.quantumofthought.com` (staging: `staging-api.`); staging deploys green pushes to `main`, production deploys `server/v*` tags. Sign-in email works. Rate limits, account deletion and export, post-deploy smoke test. |
| PWA | Built 2026-11-06 (`client_web`, `core_wasm`): capture, list, delete, live sync, offline, sign-in through the PWA, the deploy image and workflows. Not deployed yet: #54 (Railway service and DNS, a person). |
| iOS app | Started 2026-11-04: `client_apple` (XcodeGen), QotKit over `qot_ffi`; capture, list, delete, device sign-in and sync (live while open, background refresh), sign-out, delete account and export; the store is in the App Group (#27, #28). Not on TestFlight yet (#32). |
| Website | Not started; planned after the PWA and before the iOS app goes to the App Store (#19, #17). |

## Now: dogfood the CLI and sync

The goal is a platform the developer and a few friends use every day, not a
public launch. Launch is not on the horizon, so work that only matters at
real user volume or for strangers waits (see "Deferred" below).

Done: release build and `/health`; host chosen (Railway, see
[records](records/2026-11-02-hosting-platform.md)); staging and production
with their own databases and secrets; deploy pipeline; secrets in fnox
([record](records/2026-11-02-secrets-management.md)); first production
release (#4); age key backed up (#3); sign-in email (#5), DMARC
`p=quarantine` (#20); custom domains
(#10, [layout](records/2026-11-04-domain-layout.md)); rate limits (#7);
`qot --version` (#13); account deletion and export (#18); post-deploy
`/health` smoke test (#11, first part); the CLI signs in to
production by default (#12).

Next, so a friend can install the CLI and sign in without help:

- #14 Release binaries from `cli/v*` tags: the `curl … | sh` installer,
  maybe a Homebrew tap

### PWA

The second client a new user sees, and the onboarding moment: sign in once
from the CLI, land on the PWA already signed in, and watch a note typed in the
terminal appear in the tab. Hosting:
[records/2026-11-06-hosting-the-pwa-and-website.md](records/2026-11-06-hosting-the-pwa-and-website.md);
sign-in: [records/2026-11-06-sign-in-through-the-pwa.md](records/2026-11-06-sign-in-through-the-pwa.md).
Lives at `app.quantumofthought.com`, an origin that must never change
([domain layout](records/2026-11-04-domain-layout.md)).

- #48 `core_wasm`: `qot_core` in the browser
- #49 `client_web` app shell, installable and offline
- #52 Server accepts the PWA's origin (CORS, WebSocket), per environment
- #50 Notes in IndexedDB, capture/list/delete, live sync
- #51 Sign-in through the PWA: approving a device signs in the browser too
- #53 Deploy the PWA: image, `web/v*` releases, smoke test
- #54 Railway `web` service and `app.` DNS (a person)

### Website

`www.quantumofthought.com`: what qot is, how to install each client, and the
privacy policy, terms and support page the App Store asks for. So it comes
before the iOS app ships, not after launch. Same hosting shape as the PWA.

- #19 The website
- #17 Privacy policy and terms (a person; an agent can draft)

### iOS app

Dogfooding on the phone too: capture there is the point. Layout and why:
[records/2026-11-04-repo-layout-for-clients.md](records/2026-11-04-repo-layout-for-clients.md).
Bundle id `llc.abstractsyntax.qot` and App Group
`group.llc.abstractsyntax.qot`, in the Abstract Syntax LLC team
(`H88537CLVC`) with the company's other apps (moved from a personal team on
2026-11-06); App Store Connect app `6831604070`. Xcode's automatic signing registers identifiers; the `asc` CLI's
API key has the Developer role, so it reads App Store Connect but can't
create App IDs or apps.

- #26 Apple Developer account, App Store Connect, TestFlight (a person)
- #29 Capture with App Intents (Siri, Shortcuts, Action button, Spotlight)
- #30 Control Center control and Lock Screen widget
- #31 Capture by voice
- #32 TestFlight builds from `ios/v*` tags
- #33 Run QotKit's tests on Linux (cloud sessions)
- #34 Shared sync test vectors for every binding
- #35 watchOS capture through the iPhone

## Deferred

Closed as not planned on 2026-11-04 while dogfooding; reopen when a public
launch or real user volume makes them matter:

- #6 Seal production's secrets in Railway
- #8 Postgres backups off Railway, and one tested restore
- #9 Error reporting and log retention
- #11 The rest of the smoke test (scripted `qot login` with a test inbox)
- #15 Sign and notarize the macOS binary (Gatekeeper doesn't block
  `curl | sh` or Homebrew installs)
- #16 Decide what is free and what will be paid ([go-to-market.md](go-to-market.md))

(#17 and #19, privacy policy and terms and the website, were reopened on
2026-11-06; see "Website" above.)

## After dogfooding

Direction, not yet split into issues; open issues when a piece starts.

- **End-to-end encryption**: client-side encryption of change blobs;
  design key management (how a new device gets the key). Probably wanted
  before or alongside any paid tier, since it is the privacy promise.
- **Billing, and pricing on the website**, once the go-to-market plan is
  settled.
- **Mac app**: a macOS target in `client_apple` (shares QotKit and most
  of iOS).
