# Roadmap

What stands between today and a public launch, and what comes after. Check
items off here as they land; keep the CLAUDE.md "Product" section in sync
when priorities change.

## Where things stand (2026-11-02)

| Piece | State |
|---|---|
| `qot_core` | Done for v1: note model, tombstones, sync primitives, `qot_core::sync`. |
| CLI (`qot`) | Feature-complete for v1: add/get, list, delete, login/logout/sync, offline capture. Not distributed; defaults to `http://localhost:4000`. |
| Sync server | Feature-complete for v1: device sign-in, push/pull, nudge channel, CI. Never deployed; no release build. |
| PWA | **Does not exist in this tree.** The old React + WASM client was removed on 2026-11-02 (it predates the current sync API); it is in git history before `ecdca61`. |
| iOS app | Not started. |
| Marketing page | Not started. |

## Launch v1: CLI + sync server

### Server: make it deployable
- [x] Release build: `mix release` and a multi-stage `Dockerfile`;
      migrations run as a pre-deploy step (`bin/migrate`, i.e.
      `Qot.Release.migrate/0`) rather than on boot.
- [x] `GET /health` (DB reachable) for the platform's health checks.
- [ ] Rate-limit `POST /api/auth/device` per IP and per email. Today anyone
      can make the server send unlimited sign-in emails to any address, which
      burns the Resend quota and the sending domain's reputation.
- [ ] Resend: verified sending domain (SPF/DKIM), a real `from` address.
- [ ] Error reporting and log retention (e.g. Sentry or the host's logs).
- [ ] Postgres backups, and one tested restore.

### Deploy pipeline: staging and prod, auto-deploy
- [x] Pick a host. Railway, in an Abstract Syntax workspace, with
      Railway Postgres; Fly.io is the runner-up. See
      [records/2026-11-02-hosting-platform.md](records/2026-11-02-hosting-platform.md).
- [x] Two environments, two databases, two secret sets: `staging` and `production`.
- [ ] GitHub Actions: on green CI for `main` → deploy staging
      automatically; on a `v*` tag (or a manual approval in a `production`
      environment) → deploy prod. Start with both automatic if that's
      simpler, but keep prod gated on CI.
- [ ] DNS + TLS: `api.<domain>` (prod), `staging-api.<domain>`.
- [ ] Smoke test after deploy: hit `/health`, run a scripted
      `qot login` against staging with a test inbox (later).

### CLI: distribution
- [ ] Default server becomes the prod URL (keep `--server` / `$QOT_SERVER`
      for staging and self-hosting).
- [ ] `qot --version`, and a sensible `User-Agent` so the server can
      see client versions (needed later to deprecate old ones).
- [ ] Release workflow on `v*` tags that builds binaries for
      macOS (arm64, x86_64), Linux (x86_64, arm64, musl) and Windows, and
      attaches them to a GitHub Release. [`cargo-dist`](https://opensource.axo.dev/cargo-dist/)
      generates exactly this, plus the installers below.
- [ ] Install paths, in order of effort:
  1. `curl -fsSL https://<domain>/install.sh | sh` (cargo-dist generates it)
  2. Homebrew tap: `brew install aegatlin/tap/qot` (cargo-dist can publish it)
  3. `cargo install qot` / `cargo binstall qot` (needs a crates.io name;
     `qot_core` would have to be published too)
  4. Later: homebrew-core, winget, scoop, AUR.
- [ ] macOS: sign and notarize the binary so Gatekeeper doesn't block a
      downloaded (non-Homebrew) build. Needs the Apple Developer account
      the iOS app needs anyway.

### Before going public
- [ ] Go-to-market decision (see [go-to-market.md](go-to-market.md)): at
      minimum, decide what is free and what will be paid, so v1 doesn't make
      promises we have to walk back.
- [ ] Privacy policy and terms (the server stores email addresses and, until
      E2EE ships, readable note changes).
- [ ] Account deletion (delete user + change log), and a data export
      (the CLI already has every note locally).
- [ ] Landing page with install instructions (can be minimal at first).

## After v1

- [ ] **iOS app**: `qot_core` via UniFFI; capture from the Action button,
      Control Center, Siri/App Intents, voice memo; background sync. Needs the
      Apple Developer account and TestFlight. Start fresh rather than from
      the 2024 prototype; reuse its bundle id `io.gatlin.qot` and Apple
      team `9XYH562BTD`. (The prototype and its repo were deleted.)
- [ ] **End-to-end encryption**: client-side encryption of change blobs;
      design key management (how a new device gets the key). Probably wanted
      before or alongside any paid tier, since it is the privacy promise.
- [ ] **Marketing / splash page**: what qot is, install, pricing.
- [ ] **Billing**, once the go-to-market plan is settled.
- [ ] **Mac app** (shares most of iOS).
- [ ] **Web client / PWA**: rebuild on `qot_core` compiled to WASM against
      the current sync API (the old one is in git history for reference).
