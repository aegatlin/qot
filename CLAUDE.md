# CLAUDE.md

## Product

Quantum of Thought (qot) is a quick note capture tool. The feature set is
deliberately thin (capture, list, delete, sync); the surface area is wide:
anywhere you are, capturing a note should be one natural gesture (`qot get
milk` in a terminal; the Action button, a Control Center control, Siri or a
voice memo on iOS). Notes taken offline must be on your other devices by the
time you look, without opening the app.

Clients, in priority order: the CLI, then the PWA (`app.`), then iOS; a Mac
app next. The PWA comes early for onboarding: sign in once from the CLI and
land on the PWA already signed in, watching notes typed in the terminal
appear there. The website (`www.`: install every client, privacy policy,
terms, support) comes after the PWA and before iOS reaches the App Store.

The current goal is dogfooding (the developer and a few friends using it
daily), not a public launch. Work that only matters for strangers or at
real user volume (backups, pricing, error reporting) is deferred;
`docs/ROADMAP.md` lists it.

## Where the work is

Todos are **GitHub issues**: code, ops and human-only tasks alike (`gh issue
list`, or in cloud sessions, which block GraphQL, `gh api
repos/aegatlin/qot/issues`; issues for a person say "Who: a person"). `docs/ROADMAP.md` orders
them into steps; `docs/records/` keeps research and decisions. When a PR
finishes an issue, say `Fixes #N`. When work reveals a new todo, open an
issue rather than leaving a TODO comment or a note in a doc.

## Repo layout

| Directory | What |
|---|---|
| `core/` | `qot_core` (Rust): the note model and its sync primitives. Shared by every client. |
| `core_ffi/` | `qot_ffi` (Rust): `qot_core` for Swift/Kotlin via UniFFI. Adapts types only; no rules. |
| `client_cli/` | `qot` binary (Rust), uses `qot_core` directly. |
| `client_apple/` | Every Apple target in one XcodeGen project; `QotKit/` is the shared SwiftPM package. |
| `server_web/` | Phoenix server: accounts, device sign-in, note sync. |
| `docs/` | `ROADMAP.md`, `go-to-market.md`, and `records/`: dated research and decision records (see its README). |

Folders are **per build toolchain, not per device**: a new device is a new
target in an existing folder unless it needs a new toolchain
(`docs/records/2026-11-04-repo-layout-for-clients.md`). `core/`, `core_ffi/`
and `client_cli/` form one Cargo workspace (root `Cargo.toml`, one committed
`Cargo.lock`, one `target/`). A web client existed (React + the core compiled to WASM) and
was removed on 2026-11-02 while CLI and iOS come first; it is in git history.

## Tooling

One root `mise.toml` pins every tool (Rust, Erlang, Elixir, XcodeGen) and holds every
task, named `<action>:<component>` with the bare action running all of them.
A new component adds its tools and tasks there. Server env vars are
deliberately not `required` in `mise.toml`, which would stop CLI tasks from
running without them; local overrides go in a gitignored `mise.local.toml`.

**Cloud sessions** (Claude Code on the web) come with mise, the pinned tools
and Postgres, so `mise run test` and `mise run lint` work as-is (tools run
through mise: `mise exec -- mix …`). If `pg_isready` says no response, run
`service postgresql start`. They have no `fnox` key and no `railway` CLI:
they can't decrypt secrets or deploy.

They also have a **headless Chromium with Playwright** (`require('playwright')`
works from any directory; `chromium.launch()` needs no options), so verify
changes end to end, not only with tests:

- **Server + CLI, the whole sign-in and sync loop, locally.** Start the server
  in the background (`cd server_web && mise exec -- mix setup`, then
  `mix phx.server` with its output to a log file). Run `qot login
  <any email> --server http://localhost:4000` in the background with a
  scratch `QOT_DATA_DIR`. Dev logs the email, so take the
  `/auth/device?token=…` link from the server log and the `XXXX-XXXX` code
  from the CLI's output, open the link in Chromium, fill the code and submit.
  The CLI then signs in; a second `QOT_DATA_DIR` signed in the same way is a
  second device, which shows sync working (`qot get …` on one, `qot list` on
  the other).
- **Web pages** (the device sign-in page, a future PWA): load them from the
  local server and screenshot or read them.

Not against staging or production: signing in there needs a real inbox
(#11), and agents don't create accounts on production.

**Secrets** for deployed environments live in `fnox.toml`, age-encrypted and
committed, one profile per environment (`staging`, `production`). Decrypting
needs the age key at `~/.config/fnox/age.txt`, which cloud sessions don't
have, by design. fnox is the source of truth; `mise run
secrets:push:<env>` copies a profile to Railway and redeploys. To add or rotate
one: `fnox -P <env> set KEY` (reads stdin), then push. Never print values.

```sh
mise run test          # everything; or test:rust, test:server, test:apple
mise run lint          # lint:rust (rustfmt check + clippy -D warnings)
mise run server        # alias: s
mise run cli-install   # alias: ci; installs `qot`
mise run gen:apple     # alias: xcode; builds the Apple core, generates the Xcode project
```

## Conventions

- **TDD.** Write the failing test first, then the code.
- **Functional core, imperative shell.** Logic lives in pure functions over
  immutable values that are tested without I/O; storage, network and UI are a
  thin shell around them. In `qot_core` every operation on a `Note` returns a
  new `Note` rather than mutating one.
- **License: AGPL-3.0-only**, sole copyright (no outside code until there is
  a CLA; `CONTRIBUTING.md`). Every dependency must be AGPL-compatible
  (permissive or MPL-2.0; no GPL-2.0-only, no proprietary). Gate paid
  features on the server, never in a client
  (`docs/records/2026-11-04-open-source-or-closed.md`).
- Errors are values. Never turn a failure into an empty or default note; that
  silently loses a user's data.
- Rust: unit tests beside the code (`#[cfg(test)]`), CLI integration tests in
  `client_cli/tests/`. CLI tests run against a temporary store through
  `QOT_DATA_DIR` and must never touch the real one.

## The note model (`qot_core`)

- One note is one small Automerge document: `id` (UUIDv7, so ids sort by
  creation time), `content` (Automerge text) and `deleted`.
- **Delete is a tombstone**, never removing the document: a removed note
  would be resurrected by the next sync from a device that still has it.
  Clients hide tombstones.
- **Every `Note` holds a fully committed document.** An uncommitted edit gets
  committed with a fresh timestamp whenever heads are read, so the same note
  would report different heads on every call and incremental sync would break.
- Sync primitives: `heads()`, `changes_since(heads)` (empty heads = the whole
  note; unknown heads are an error, not "send everything") and
  `apply_changes(bytes)` (idempotent). The automerge-repo sync stack is
  deliberately not used while it is being rebuilt around Subduction.

## Sync and end-to-end encryption

End-to-end encryption is the intended default, so **the server never reads
note content**. It keeps a per-user, append-only log of opaque change blobs
and relays them; clients do all merging with `qot_core`. Encryption is then a
client-only addition (encrypt each blob before pushing), with no server
change. Key management (how a new device gets the key) is not designed yet.
Anything that needs the server to read notes (e.g. future note pipelines)
must be an explicit opt-in and must not weaken this default.

- `POST /api/sync/push` `{changes: [{note_id, data}]}` (data base64) appends
  and returns `{cursor}`.
- `GET /api/sync/pull?since=N&limit=M` returns `{changes: [{seq, note_id,
  data}], cursor, more}`. A client stores `cursor` and pulls from it next.
- The `notes:user:#{user_id}` channel only nudges (`"changed"` with the new
  cursor); data always moves through pull, so there is one path.
- **Seqs are per user and gap-free**: a push reserves its range by
  incrementing `users.change_seq` under that row's lock. A global sequence
  would let a reader at cursor N miss a slower transaction that commits a seq
  below N later. `Qot.SyncConcurrencyTest` pins this.
- Request parsing is pure (`Qot.Sync.Batch`); `Qot.Sync` is the I/O shell.

## Client sync (`qot_core::sync`)

Every client syncs with the same pure functions (Swift reaches them through
`qot_ffi`), so iOS and the PWA inherit
the rules the CLI is tested with:

- `SyncState` (persisted per device): `cursor`, the last server seq applied,
  and per note the heads last pushed.
- A sync is **push, then pull**: `plan_push` (what moved since last pushed;
  the whole note if never pushed or if the saved heads are unknown) →
  send → `mark_pushed`; then pull pages from `cursor` and `apply_pulled`
  until `more` is false. Save state after every step: an interrupted sync
  resumes, and anything repeated is harmless.
- `apply_pulled` moves a note's "pushed" heads only if nothing local was
  waiting, so local edits made before a pull still go up next time.
- A device pulls back its own pushes; applying them is a no-op.

## CLI (`client_cli`)

- `qot login <email> [--server URL]` runs the device sign-in (server from
  `--server`, else `$QOT_SERVER`, else production,
  `https://api.quantumofthought.com`), then syncs. Against a local server:
  `--server http://localhost:4000`, or `QOT_SERVER` in `mise.local.toml`.
  `qot logout` revokes and forgets credentials and sync state; notes stay.
  `qot sync` syncs and reports errors. `qot export` prints live notes as
  JSON (`id`, `created_at` from the UUIDv7, `content`): the data export,
  since a synced device has everything the server has. `qot delete-account`
  asks for the email to be typed, then deletes the account on the server;
  notes stay on the device. `qot status` shows the account, the server
  (labelled production, staging, local or custom), live notes and how many
  have changes not pushed yet, the data dir and the version; offline, and
  never prints tokens. Every request sends `User-Agent:
  qot-cli/<version> (<os>; <arch>)`.
- Capture never waits on the network: `add`/`get …`, `delete` and `list`
  run a best-effort sync with a 3 s timeout when signed in, and print
  `(not synced: …)` to stderr when offline. The note is saved first.
- Store layout under the data dir: `notes/<id>.note` (Automerge bytes),
  `sync.json` (`SyncState`), `credentials.json` (tokens, mode 0600).
- Sync rules live in `qot_core::sync`; `service.rs` and `api.rs` are the
  I/O shell. Integration tests run the binary against `httpmock`
  (`tests/sync_test.rs`).
- **Releasing** is [dist](https://axodotdev.github.io/cargo-dist/): bump
  `version` in `client_cli/Cargo.toml`, merge, then push a `cli/vX.Y.Z`
  tag on that merge commit. A person pushes release tags by hand
  (`docs/records/2026-11-06-release-tags-by-hand.md`). Cloud sessions
  can't push tags at all: Anthropic's GitHub proxy allows branch pushes
  only, and agents don't push tags anywhere else either. Check the tag
  matches the version, since dist fails on a mismatch (dist parses `cli/`,
  not `cli-`; the namespace keeps `server/v*` tags from triggering it).
  `.github/workflows/cli-release.yml`
  builds macOS (arm64, x86_64) and Linux (arm64, x86_64, glibc and musl)
  with the Rust pinned in `mise.toml` (`.github/cli-release-setup.yml`),
  publishes a GitHub Release with `qot_cli-installer.sh`, and pushes the
  `qot` formula to `aegatlin/homebrew-tap` with the `HOMEBREW_TAP_TOKEN`
  secret (a fine-grained token, Contents read/write on that repo only,
  renewed yearly). The workflow is generated: edit `dist-workspace.toml`,
  then run `dist generate` (dist is pinned in `mise.toml`; keep
  `cargo-dist-version` equal). On PRs it runs `dist plan` only.

## Apple (`client_apple`)

- `scripts/build-apple-core` (`mise run build:apple-core`) compiles
  `qot_ffi` for iPhone, simulator and Mac, generates the Swift bindings with
  UniFFI and puts both in `QotKit/` (gitignored). Rerun it after any Rust
  change. `project.yml` is the source of the Xcode project; the
  `.xcodeproj` is generated and gitignored, so edit `project.yml`.
- **QotKit** holds the logic (store, and later API and sync shell) as a
  plain SwiftPM package, tested with `swift test` (Swift Testing) on the Mac
  host against the real Rust core. App, widget and intent targets stay thin
  SwiftUI over it. The generated bindings are internal to QotKit, which
  exposes its own types (`NoteStore`, `NoteItem`).
- The store uses the CLI's layout (`notes/<id>.note`, Automerge bytes),
  currently under the app's Application Support directory.
- The FFI is synchronous and UniFFI is pinned exactly. Network I/O belongs
  in Swift, not Rust.
- `mise run test:apple` needs macOS and Xcode; elsewhere it reports itself
  skipped. CI runs it on macOS only when Apple or Rust paths change
  (`.github/workflows/apple.yml`).
- The Watch doesn't link `qot_core` in v1 (arm64_32 is a Tier 3 Rust
  target); it hands captures to the iPhone (#35).

## Server (`server_web`)

- **Auth is a device sign-in** (like `gh auth login`), for every client:
  1. The device calls `POST /api/auth/device {email}` and gets a
     `device_code` (secret, kept on the device) and a `user_code`
     (`XXXX-XXXX`, shown to the person).
  2. The server emails a link to `/auth/device?token=…`, a small HTML page
     where the person **types the user code**. Opening the link approves
     nothing, so mail scanners that prefetch links are harmless, and someone
     who starts a sign-in with your address can't get in by you clicking an
     email you didn't expect. The code is never in the email. Five wrong codes
     deny the sign-in; it expires after 15 minutes.
  3. The device polls `POST /api/auth/device/token {device_code}` (400
     `authorization_pending` until approved) and receives, once, a JWT access
     token (1 h, `user_id` claim) and a refresh token (30 days, stored
     hashed). `POST /api/auth/refresh` renews the access token.
  Starting a sign-in sends an email, so it is **rate-limited** per address
  (5/hour, case-insensitive) and per client IP (20/hour; IPv6 per /64): a
  429 with `Retry-After`. The rules are pure (`Qot.Accounts.SignInLimit`);
  `SignInLimiter` holds the history in memory, which is fine for one
  instance (several would each allow the full limit). The client IP comes
  from `X-Real-IP` in production (Railway's edge sets it;
  `QotWeb.Plugs.ClientIP`, `CLIENT_IP_HEADER` to change it).
  **Decided, not built yet** (#51,
  `docs/records/2026-11-06-sign-in-through-the-pwa.md`): the emailed page
  moves into the PWA at `app.`, and a correct code there also signs in that
  browser. Hosting of the PWA and website:
  `docs/records/2026-11-06-hosting-the-pwa-and-website.md`.
  `RequireAuth` checks Bearer tokens for HTTP; WebSocket connect params carry
  the JWT, verified before channel join. The pure rules live in
  `Qot.Accounts.DeviceLogin` (status, code checks).
- **Account deletion**: `DELETE /api/account {confirm: <the account's
  email>}` removes the user, refresh tokens, change log and sign-ins
  (`Qot.Accounts.delete_user/1`) and closes the user's sockets. A
  server-side export would only be opaque change blobs, so export is the
  client's job.
- **Contexts**: `Qot.Accounts` (users, device sign-in, tokens), `Qot.Sync`
  (the change log, always scoped by `user_id`).
- **Per-user isolation**: every sync call takes `user_id` from the token;
  channels are `notes:user:#{user_id}`, joinable only by that user.
- Mail: Swoosh's own Resend adapter with the Req client (no `resend`,
  `tesla` or `hackney`).
- Tests: `Ecto.Adapters.SQL.Sandbox`; Swoosh test adapter for emails;
  helpers in `test/support/` (`DataCase`, `ConnCase`, `ChannelCase`,
  `AuthHelpers`). `mix test` creates and migrates the test database.
- **Deploys: Railway**, project `qot` in the Abstract Syntax workspace (why:
  `docs/records/2026-11-02-hosting-platform.md`). Services `server` (built
  from `server_web/Dockerfile`) and `Postgres`; environments `production`
  (`https://api.quantumofthought.com`) and `staging`
  (`https://staging-api.quantumofthought.com`), each with its own database
  and secrets. The Railway hosts (`server-production-0969.up.railway.app`,
  `server-staging-b1ea.up.railway.app`) still answer; `PHX_HOST` is the
  custom one. Domain layout: `docs/records/2026-11-04-domain-layout.md`. Pre-deploy `bin/migrate`, health check `/health`, `DATABASE_URL`
  is a reference to the private-network Postgres (`DATABASE_SSL=false`,
  `ECTO_IPV6=true`). The config lives in Railway, not in the repo: read it with
  the Railway MCP or `railway environment config --json`.
- **Releasing**: staging deploys every green push to `main` that touches
  `server_web/` (watch pattern). Production deploys the `production` branch,
  which `.github/workflows/release-server.yml` moves to a `server/v*` tag
  after CI passes. Production has **no watch pattern** on purpose: Railway
  checks only the files the pushed commit changed, so a tag on a docs-only
  commit would be skipped. Agents can't deploy production; a person pushes
  the tag.
- **Smoke test** after every deploy (`.github/workflows/smoke.yml`, running
  `scripts/smoke-test <url> [<sha>]`): waits until `/health` reports the
  deployed commit (`commit`, from Railway's `RAILWAY_GIT_COMMIT_SHA`), then
  checks that the API answers. Read-only and sends no email, so it is safe
  against production. Staging runs it after CI passes on `main`;
  `release-server.yml` runs it for production after promoting.
- CI (`.github/workflows/ci.yml`) runs Rust and server checks on every PR,
  reading tool versions from `mise.toml`.
- Dev logs every email (sign-in links included) to the server's console.
- Production env: `DATABASE_URL`, `JWT_SECRET_KEY`, `RESEND_API_KEY`,
  `SECRET_KEY_BASE`, `PHX_HOST` (sign-in links are built from it). Optional:
  `CLIENT_IP_HEADER` (default `x-real-ip`), `DATABASE_SSL=false` (a database on the host's private network; TLS with
  certificate verification is the default), `ECTO_IPV6=true`, `POOL_SIZE`,
  `PORT`. Dev and test need none.
- **Release**: `server_web/Dockerfile` builds a `mix release` (Elixir and
  Erlang versions match `mise.toml`; bump them together). `bin/server` starts
  it; `bin/migrate` runs migrations and is the platform's pre-deploy step, so
  a failed migration fails the deploy instead of crash-looping the app.
  `GET /health` is 200 (`{status, commit}`) when the database answers, else
  503.
