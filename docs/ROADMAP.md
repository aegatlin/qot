# Roadmap

The order of work and why. Each step is tracked as a GitHub issue
(`gh issue list`); this file is the map, the issues are the list. When you
come back to the repo, start with the first open issue in the next unfinished
step. Keep the CLAUDE.md "Product" section in sync when priorities change.

## Where things stand (2026-11-04)

| Piece | State |
|---|---|
| `qot_core` | Done for v1: note model, tombstones, sync primitives, `qot_core::sync`. |
| CLI (`qot`) | Feature-complete for v1: add/get, list, delete, login/logout/sync, offline capture, `--version`. Not distributed; signs in to production by default (#12). |
| Sync server | Feature-complete for v1 and live at `api.quantumofthought.com` (staging: `staging-api.`); staging deploys green pushes to `main`, production deploys `server-v*` tags. Sign-in email works. Rate limits, account deletion and export, post-deploy smoke test. |
| PWA | **Does not exist in this tree.** The old React + WASM client was removed on 2026-11-02 (it predates the current sync API); it is in git history before `ecdca61`. |
| iOS app | Started 2026-11-04: `client_apple` (XcodeGen), QotKit over `qot_ffi`; local capture, list and delete in the simulator. No sync yet. |
| Marketing page | Not started, and not planned for now. |

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

- #14 Release binaries from `cli-v*` tags: the `curl … | sh` installer,
  maybe a Homebrew tap

### iOS app

Dogfooding on the phone too: capture there is the point. Layout and why:
[records/2026-11-04-repo-layout-for-clients.md](records/2026-11-04-repo-layout-for-clients.md).
Bundle id `io.gatlin.qot`, Apple team `9XYH562BTD` (reused from the deleted
2024 prototype).

- #26 Apple Developer account, App Store Connect, TestFlight (a person)
- #27 Device sign-in and sync
- #28 Share the store through an App Group
- #29 Capture with App Intents (Siri, Shortcuts, Action button, Spotlight)
- #30 Control Center control and Lock Screen widget
- #31 Capture by voice
- #32 TestFlight builds from `ios-v*` tags
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
- #17 Privacy policy and terms
- #19 Landing page with install instructions

## After dogfooding

Direction, not yet split into issues; open issues when a piece starts.

- **End-to-end encryption**: client-side encryption of change blobs;
  design key management (how a new device gets the key). Probably wanted
  before or alongside any paid tier, since it is the privacy promise.
- **Marketing / splash page**: what qot is, install, pricing.
- **Billing**, once the go-to-market plan is settled.
- **Mac app**: a macOS target in `client_apple` (shares QotKit and most
  of iOS).
- **Web client / PWA**: rebuild on `qot_core` compiled to WASM against
  the current sync API (the old one is in git history for reference).
