# Roadmap

The order of work and why. Each step is tracked as a GitHub issue
(`gh issue list`); this file is the map, the issues are the list. When you
come back to the repo, start with the first open issue in the next unfinished
step. Keep the CLAUDE.md "Product" section in sync when priorities change.

## Where things stand (2026-11-02)

| Piece | State |
|---|---|
| `qot_core` | Done for v1: note model, tombstones, sync primitives, `qot_core::sync`. |
| CLI (`qot`) | Feature-complete for v1: add/get, list, delete, login/logout/sync, offline capture. Not distributed; defaults to `http://localhost:4000`. |
| Sync server | Feature-complete for v1 and deployed on Railway: staging deploys green pushes to `main`, production deploys `server-v*` tags. Sign-in email not working yet (no Resend key). |
| PWA | **Does not exist in this tree.** The old React + WASM client was removed on 2026-11-02 (it predates the current sync API); it is in git history before `ecdca61`. |
| iOS app | Not started. |
| Marketing page | Not started. |

## Launch v1: CLI + sync server

Done: release build and `/health`; host chosen (Railway, see
[records](records/2026-11-02-hosting-platform.md)); staging and production
with their own databases and secrets; deploy pipeline; secrets in fnox
([record](records/2026-11-02-secrets-management.md)).

### 1. Server in production
- #4 First production release (`server-v0.1.0` tag)
- #3 Back up the age key
- #5 Resend: verified domain and real keys (sign-in works after this)
- #20 Tighten DMARC once sign-in mail has been reliable for a while
- #6 Seal production's secrets in Railway
- #7 Rate-limit `POST /api/auth/device` (before anyone else uses it)
- #8 Postgres backups off Railway, and one tested restore
- #9 Error reporting and log retention
- #10 Custom domains (`api.` and `staging-api.quantumofthought.com`)
- #11 Smoke test after each deploy

### 2. CLI distribution
- #12 Default to the production server
- #13 `qot --version` and a versioned `User-Agent`
- #14 Release binaries from `cli-v*` tags (cargo-dist) and install paths
- #15 Sign and notarize the macOS binary

### 3. Before going public
- #16 Decide what is free and what will be paid ([go-to-market.md](go-to-market.md))
- #17 Privacy policy and terms
- #18 Account deletion and data export
- #19 Landing page with install instructions

## After v1

Direction, not yet split into issues; open issues when a piece starts.

- **iOS app**: `qot_core` via UniFFI; capture from the Action button,
  Control Center, Siri/App Intents, voice memo; background sync. Needs the
  Apple Developer account and TestFlight. Start fresh rather than from
  the 2024 prototype; reuse its bundle id `io.gatlin.qot` and Apple
  team `9XYH562BTD`. (The prototype and its repo were deleted.)
- **End-to-end encryption**: client-side encryption of change blobs;
  design key management (how a new device gets the key). Probably wanted
  before or alongside any paid tier, since it is the privacy promise.
- **Marketing / splash page**: what qot is, install, pricing.
- **Billing**, once the go-to-market plan is settled.
- **Mac app** (shares most of iOS).
- **Web client / PWA**: rebuild on `qot_core` compiled to WASM against
  the current sync API (the old one is in git history for reference).
