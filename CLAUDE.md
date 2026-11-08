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
real user volume (backups, pricing, error reporting) is deferred: those
issues are closed as not planned, to reopen when a launch makes them matter.

qot is an **Abstract Syntax LLC** product: every outside account (Apple,
Railway, later Stripe and the rest) belongs to the company, never to a
personal account, and identifiers follow it (`llc.abstractsyntax.*`).

## Where the work is

Todos are **GitHub issues**: code, ops and human-only tasks alike (`gh issue
list`, or in cloud sessions, which block GraphQL, `gh api
repos/aegatlin/qot/issues`; issues for a person say "Who: a person"). Open issues are the whole
backlog; there is no separate roadmap
(`docs/records/2026-11-08-issues-are-the-backlog.md`). `docs/records/` keeps
research and decisions. When a PR
finishes an issue, say `Fixes #N`. When work reveals a new todo, open an
issue rather than leaving a TODO comment or a note in a doc.

## Repo layout

| Directory | What |
|---|---|
| `core/` | `qot_core` (Rust): the note model and its sync primitives. Shared by every client. |
| `core_ffi/` | `qot_ffi` (Rust): `qot_core` for Swift/Kotlin via UniFFI. Adapts types only; no rules. |
| `core_wasm/` | `qot_wasm` (Rust): `qot_core` for the browser via wasm-bindgen. Adapts types only; no rules. |
| `client_cli/` | `qot` binary (Rust), uses `qot_core` directly. |
| `client_apple/` | Every Apple target in one committed Xcode project; `QotKit/` is the shared SwiftPM package. |
| `client_web/` | The PWA (`app.quantumofthought.com`): Vite + TypeScript + Preact over `qot_wasm`. |
| `site_web/` | The website (`www.quantumofthought.com`): Astro, static HTML and CSS. |
| `server_web/` | Phoenix server: accounts, device sign-in, note sync. |
| `docs/` | `go-to-market.md` and `records/`: dated research and decision records (see its README). |

Folders are **per build toolchain, not per device**: a new device is a new
target in an existing folder unless it needs a new toolchain
(`docs/records/2026-11-04-repo-layout-for-clients.md`). `core/`, `core_ffi/`,
`core_wasm/` and `client_cli/` form one Cargo workspace (root `Cargo.toml`,
one committed `Cargo.lock`, one `target/`).

## Tooling

One root `mise.toml` pins every tool (Rust, Erlang, Elixir, Node,
wasm-bindgen, binaryen) and holds every
task, named `<action>:<component>` with the bare action running all of them.
A new component adds its tools and tasks there. Server env vars are
deliberately not `required` in `mise.toml`, which would stop CLI tasks from
running without them; local overrides go in a gitignored `mise.local.toml`.

**Cloud sessions** (Claude Code on the web) come with mise, the pinned tools
and Postgres, so `mise run test` and `mise run lint` work as-is (tools run
through mise: `mise exec -- mix …`). If `pg_isready` says no response, run
`service postgresql start`. They have no `fnox` key and no `railway` CLI:
they can't decrypt secrets or deploy. Docker works after starting `dockerd`
in the background, but builds can't reach the network directly: build with
`--network host`, the proxy as `--build-arg HTTPS_PROXY=…`, and a scratch
copy of the Dockerfile that installs `/root/.ccr/ca-bundle.crt` (passed with
`--build-context ccr=/root/.ccr`) and switches apt to https. Never commit
those changes.

They also have a **headless Chromium with Playwright** (`require('playwright')`
works from any directory; `chromium.launch()` needs no options), so verify
changes end to end, not only with tests:

- **Server + PWA + CLI: `mise run e2e:web`** (Playwright, `client_web/e2e/`)
  starts the server with `APP_URL` pointing at the built PWA, signs in from
  the CLI by typing its code into the PWA's sign-in page, and checks notes
  moving both ways live, offline capture and a wrong code. Extend it rather
  than clicking through by hand.
- **Server + CLI, the whole sign-in and sync loop, by hand.** Start the server
  in the background (`cd server_web && mise exec -- mix setup`, then
  `mix phx.server` with its output to a log file). Run `qot login
  <any email> --server http://localhost:4000` in the background with a
  scratch `QOT_DATA_DIR`. Dev logs the email, so take the
  `/auth/device?token=…` link from the server log (in dev it points at the
  PWA's dev server, `mise run dev:web`) and the `XXXX-XXXX` code from the
  CLI's output, then open the link in Chromium, fill the code and submit. With
  no browser, approve it directly: `POST /api/auth/device/approve {token,
  user_code, sign_in_browser: false}`.
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
mise run test          # everything; or test:rust, test:wasm, test:web, test:site, test:server, test:apple
mise run lint          # lint:rust (rustfmt + clippy, also for wasm32), lint:web (tsc), lint:site (astro check)
mise run e2e:web       # PWA + server + CLI in headless Chromium (needs Postgres)
mise run dev:web       # alias: w; the PWA at http://localhost:5173 against the local server
mise run dev:site      # the website at http://localhost:4321
mise run server        # alias: s
mise run cli-install   # alias: ci; installs `qot`
mise run xcode         # builds the Apple core, opens the Xcode project
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
`qot_ffi`, the PWA through `qot_wasm`), so iOS and the PWA inherit
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
- **Shared test vectors** (`core/tests/vectors/sync.json`) pin these rules
  for every binding: `core/tests/sync_vectors.rs` (Rust, which also
  regenerates them), `SyncVectorTests` (Swift) and `core_wasm/tests/web.rs`
  (wasm) replay the same cases. Regenerate only when the rules change on
  purpose (`cargo test -p qot_core --test sync_vectors -- --ignored
  regenerate`); a new binding replays them too.

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

- Team Abstract Syntax LLC (`H88537CLVC`); bundle id
  `llc.abstractsyntax.qot`, App Group `group.llc.abstractsyntax.qot`; App
  Store Connect app "qot: Quantum of Thought", id `6831604070`. New targets
  are `llc.abstractsyntax.qot.<name>`. Xcode's automatic signing registers
  identifiers and capabilities. The `asc` CLI (`brew install asc`, key in the
  system keychain) reads App Store Connect; its key has the Developer role,
  so creating App IDs, groups or apps is done in Xcode or by a person.
- `scripts/build-apple-core` (`mise run build:apple-core`) compiles
  `qot_ffi` for iPhone, simulator and Mac, generates the Swift bindings with
  UniFFI and puts both in `QotKit/` (gitignored). Rerun it after any Rust
  change.
- **`Qot.xcodeproj` is committed and is the source of truth**, edited in
  Xcode or through the Xcode MCP tools, not by hand in the pbxproj
  (`docs/records/2026-11-08-apple-native-project.md`). Targets use
  synchronized folders, so adding a file doesn't touch the project. The
  `Qot` scheme is shared and archives. Signing: `Config/Signing.xcconfig`
  sets the team; a gitignored `Config/Local.xcconfig` overrides it. New
  targets (Mac, more extensions) come from File > New Target.
- **Xcode Cloud** builds for TestFlight; `ci_scripts/ci_post_clone.sh`
  installs the Rust pinned in `mise.toml` and builds the core first.
  GitHub Actions (`apple.yml`) stays the PR check, since Xcode Cloud
  doesn't build pull requests from forks. Workflows are configured in Xcode
  or App Store Connect, not in the repo.
- **QotKit** holds the logic as a plain SwiftPM package, tested with `swift
  test` (Swift Testing) on the Mac host against the real Rust core. App,
  widget and intent targets stay thin SwiftUI over it. `NoteStore` (files),
  `ServerAPI` (HTTP over an injectable `HTTPTransport`), `Syncer` (push then
  pull with `qot_core::sync`, state saved after every step), `Account`
  (device sign-in, sign-out, delete account), `LiveNudges` (the channel
  nudge over `URLSessionWebSocketTask`, Phoenix frames in `PhoenixFrame`),
  `KeychainCredentialStore`. Tests fake the server as a transport
  (`Tests/QotKitTests/FakeServer.swift`, the twin of the PWA's).
  `LiveServerTests` runs against a real dev server when
  `QOT_E2E_SERVER=http://localhost:4000` and `QOT_E2E_SERVER_LOG=<server
  log>` are set: two devices sign in (approving through the emailed link in
  the log), sync, and one is nudged live.
- **The store is in the App Group** (`AppGroup.store()`: `<group
  container>/qot/`), in the CLI's layout (`notes/<id>.note`, `sync.json`),
  so intents and widgets share it; notes from the app's old Application
  Support store are merged in on launch. Every process may write: note
  read-modify-writes hold `store.lock` and save by merging with what is on
  disk; a sync holds `sync.lock` (both `flock`). Tokens are in the Keychain
  with the App Group as access group, readable after first unlock.
- **Capture surfaces**: `AddNoteIntent` (app target; Siri phrases in
  `QotShortcuts`, also Shortcuts, the Action button and Spotlight) saves
  through `Capture` (QotKit: save, then a sync bounded to 3 s) without
  opening the app. `Shared/` is compiled into the app and the `QotWidgets`
  extension (`llc.abstractsyntax.qot.widgets`): `OpenCaptureIntent` (the
  Control Center control; opens the app ready to type). The extension also
  has a Lock Screen widget and a Home Screen "Latest Notes" widget, which
  read the App Group store; the app reloads widget timelines whenever its
  notes change. `qot://capture` opens the app ready to type. Dictation
  (`Dictation.swift`) transcribes on the device (`requiresOnDeviceRecognition`)
  into the draft for the person to check; audio is never kept or sent.
- The app syncs on launch and foreground, after every capture and delete
  (in the background; capture never waits), on pull-to-refresh, on the
  channel nudge while open, and in a `BGAppRefreshTask`
  (`llc.abstractsyntax.qot.sync`). The account sheet signs in against
  production, staging or any URL (`http://localhost:4000` from the
  simulator; ATS allows local networking only). Requests send `User-Agent:
  qot-ios/<version> (iOS <version>; <model>)`.
- The FFI is synchronous and UniFFI is pinned exactly. Network I/O belongs
  in Swift, not Rust. Automerge comes through `qot_ffi`, never
  automerge-swift: the rules live once, in `qot_core`
  (`docs/records/2026-11-08-why-not-automerge-swift.md`).
- `mise run test:apple` needs macOS and Xcode; elsewhere it reports itself
  skipped. CI runs it on macOS only when Apple or Rust paths change
  (`.github/workflows/apple.yml`).
- **The Watch** (`QotWatch`, `llc.abstractsyntax.qot.watchkitapp`, embedded
  in the iOS app) doesn't link `qot_core` in v1 (arm64_32 is a Tier 3 Rust
  target): it sends `{id, text}` to the iPhone with WatchConnectivity
  `transferUserInfo` (queued while apart), and the phone's `WatchReceiver`
  saves it through QotKit's `Inbox` (drops a transfer delivered twice, by
  id) and syncs. `QotWatchWidgets` is the complication / Smart Stack
  widget. Its App IDs (`…watchkitapp`, `…watchkitapp.widgets`) are
  registered. A new target's App ID must exist before Xcode Cloud can
  export: cloud signing can't register one, and a local archive won't
  either (targets without capabilities get the wildcard development
  profile). Register it with Distribute App > Custom > App Store Connect >
  Export from a local archive, or on developer.apple.com.

## Web (`client_web`)

- The PWA: capture, list, delete, sync, the device sign-in page, and deleting the account (`deleteAccount` in `session.ts`, like `qot delete-account`: the email typed again, the session forgotten, notes kept). Same
  rules as every client: `qot_wasm` (`core_wasm/`) wraps `qot_core`;
  `scripts/build-wasm-core` (`mise run build:wasm-core`) compiles it and
  generates the JS bindings into `client_web/src/core/` (gitignored); rerun
  after any Rust change. `--release` uses Cargo's `wasm-release` profile and
  `wasm-opt` (~510 KB gzipped). wasm-bindgen's CLI is pinned in `mise.toml`
  and must equal the crate version.
- Layout: pure logic in `notes.ts`, `session.ts`, `config.ts` and the core;
  the shell is `api.ts` (HTTP), `store.ts` (IndexedDB, the CLI's layout:
  notes by id, `sync` and `credentials` in `meta`), `sync.ts` (push then
  pull, state saved after each step), `live.ts` (the Phoenix channel nudge),
  `app.tsx` (Preact). Errors are `Result` values (`result.ts`).
- Tabs share one IndexedDB: Web Locks (`lock.ts`) serialise syncs and every
  read-modify-write of a note; a `BroadcastChannel` tells other tabs to
  reload.
- Offline: `src/sw.js` is the service worker template; `vite.config.ts`
  fills in the build's files. It precaches the build and `config.json`,
  serves pages network-first and hashed assets cache-first (`ignoreVary`:
  servers send `Vary: Origin` and module scripts carry an `Origin`).
- Config is runtime, not build time: `/config.json` `{apiUrl}`, written by
  the image at start (`API_URL`), served by Vite's dev and preview servers
  from `QOT_API_URL` (default `http://localhost:4000`). One build runs in
  staging and production.
- Tests: `vitest` (`client_web/tests/`) against the real core, IndexedDB
  from `fake-indexeddb`, the server faked as a `fetch` (`fake-server.ts`);
  Playwright e2e in `client_web/e2e/` (see Tooling). `qot_wasm` itself is
  tested natively and in Node (`mise run test:wasm`).
- **Deploys** (`docs/records/2026-11-06-hosting-the-pwa-and-website.md`):
  Railway service `web`, built from `client_web/Dockerfile` with the repo
  root as context (Rust, Node and Caddy stages; versions must match
  `mise.toml`, which CI checks). `bin/web` checks `API_URL` and starts
  Caddy (`client_web/Caddyfile`): SPA fallback, `/health` `{status,
  commit}`, `/config.json`, immutable `/assets/*`, `no-cache` elsewhere, a
  CSP whose `connect-src` is the API and its `wss:`, `Referrer-Policy:
  no-referrer` (sign-in links carry a token). Staging deploys green pushes
  to `main` touching `client_web/`, `core/`, `core_wasm/` or `Cargo.lock`;
  production deploys the `production-web` branch, which
  `.github/workflows/release-web.yml` moves to a `web/v*` tag (a person
  pushes it) and then smoke-tests (`scripts/smoke-test-web <app> <api>
  [<sha>]`, also run for staging by `smoke-web.yml`; it checks the API's
  CORS for the app too).

## Website (`site_web`)

- `www.quantumofthought.com`: what qot is, `/install` (every client),
  `/support` (contact, export, account deletion, FAQ), `/privacy` and
  `/terms` (drafts until a person approves them, #17; `draft: true` in the
  frontmatter shows a banner). The Abstract Syntax site
  (`aegatlin/abstract_syntax`, `www.abstractsyntax.llc`) links here.
- **Astro**, built to plain HTML and CSS with **no JavaScript**: pages in
  `src/pages/` (`.astro`, or `.mdx` with `layouts/Prose.astro` for long text).
  The shadcn/ui components (`src/components/ui/`) and `lib/utils.ts` are
  copied from the Abstract Syntax site and render at build time only through
  `@astrojs/react`; the config deletes the client bundle it emits anyway. The
  theme in `src/styles/global.css` keeps shadcn's token names with qot's
  palette (the PWA's), light and dark from `prefers-color-scheme`.
- `build.format: "file"`: `/privacy` is `privacy.html`, so the server must
  try `<path>.html`. `compressHTML` is off because it ate the space before
  inline tags.
- No third-party scripts, fonts or trackers; Plausible is a separate decision
  (#61). `tests/site.test.mjs` (`mise run test:site`) checks the build: every
  page and internal link, no `<script>`, no JS files, nothing loaded from
  another origin, and the facts the install, support and privacy pages must
  state.
- **Deploys**: the PWA's shape. Railway service `site`, built from
  `site_web/Dockerfile` with the repo root as context (Node, then Caddy;
  `NODE_VERSION` must match `mise.toml`, which CI checks). `bin/site` starts
  Caddy (`site_web/Caddyfile`): `/health` `{status, commit}`, clean URLs
  (`/privacy` serves `privacy.html`; `.html` and trailing slashes redirect),
  `404.html`, immutable `/_astro/*`, `no-cache` elsewhere, and a CSP that
  allows no scripts. Staging (`staging-www.`) deploys green pushes to `main`
  touching `site_web/`; production (`www.`) deploys the `production-site`
  branch, which `.github/workflows/release-site.yml` moves to a `site/v*` tag
  (a person pushes it), then smoke-tests (`scripts/smoke-test-site <url>
  [<sha>]`, also run for staging by `smoke-site.yml` and on the image in CI).

## Server (`server_web`)

- **Auth is a device sign-in** (like `gh auth login`), for every client:
  1. The device calls `POST /api/auth/device {email}` and gets a
     `device_code` (secret, kept on the device) and a `user_code`
     (`XXXX-XXXX`, shown to the person).
  2. The server emails a link to the PWA's `/auth/device?token=…` page
     (`APP_URL`) where the person **types the user code**. Opening the link approves
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
  **Sign-in through the PWA**
  (`docs/records/2026-11-06-sign-in-through-the-pwa.md`): the PWA's page
  reads `GET /api/auth/device/link?token=` (which account; approves
  nothing), then `POST /api/auth/device/approve {token, user_code,
  sign_in_browser}`: a correct code approves the asking device and, unless
  `sign_in_browser` is false, returns tokens for that browser too, in the
  same transaction. `POST /api/auth/device` returns `app_url` so `qot login`
  can point to the PWA. The server's own `/auth/device` (where links pointed
  before the PWA) only redirects to the PWA's, so old links never break.
  **Browser origins**: `QotWeb.AppOrigin` (from `APP_URL`, read at runtime)
  is the one origin CORS (`QotWeb.Plugs.CORS`, no credentials) and the
  socket's `check_origin` accept; native clients send no `Origin`.
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
  `SECRET_KEY_BASE`, `PHX_HOST`, `APP_URL` (the PWA, e.g.
  `https://app.quantumofthought.com`: sign-in links open it and its origin is
  the one browser origin allowed; dev defaults to `http://localhost:5173`).
  Optional: `CLIENT_IP_HEADER` (default `x-real-ip`), `DATABASE_SSL=false` (a database on the host's private network; TLS with
  certificate verification is the default), `ECTO_IPV6=true`, `POOL_SIZE`,
  `PORT`. Dev and test need none.
- **Release**: `server_web/Dockerfile` builds a `mix release` (Elixir and
  Erlang versions match `mise.toml`; bump them together). `bin/server` starts
  it; `bin/migrate` runs migrations and is the platform's pre-deploy step, so
  a failed migration fails the deploy instead of crash-looping the app.
  `GET /health` is 200 (`{status, commit}`) when the database answers, else
  503.
