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
One exception, decided 2026-11-20: **cloud transcription is the first paid
feature** (the server transcribes a recording a client sends, for clients
that can't; opt-in, gated by a plan, billed with Stripe), because qot
presumes nothing about which clients someone has
(`docs/records/2026-11-20-paid-transcription.md`). The endpoint and `qot
record --transcribe` are built (#111) but no provider is configured
anywhere; billing is not built (#112).

**qot does not launch without voice memos that sync**: one gesture on the
iPhone records a memo, and both the recording and its text reach every
client that can show them (#78). Notes hold media as attachments, audio
first; the design, and what it asks of end-to-end encryption, is
`docs/records/2026-11-19-attachments-and-voice-memos.md`. Being built, in
#78's order: the core knows attachments (#96), the server stores blobs
(#97), the CLI lists, exports, plays and records them (#98, #108) and the PWA shows and plays
them (#99), and the iPhone app records, transcribes and plays them (#100).
The iPhone part is built and was checked in the simulator only (record in
the app, save, play back): starting from Control Center with the app
closed, on-device transcription and the upload after the phone is pocketed
are **not verified on a phone yet**, and #100 stays open until they are.

qot is an **Abstract Syntax LLC** product: every outside account (Apple,
Railway, later Stripe and the rest) belongs to the company, never to a
personal account, and identifiers follow it (`llc.abstractsyntax.*`).

## Where the work is

Todos are **GitHub issues**: code, ops and human-only tasks alike (`gh issue
list`, or in cloud sessions, which block GraphQL, `gh api
repos/aegatlin/qot/issues`; issues for a person say "Who: a person"). Open issues are the whole
backlog; there is no separate roadmap
(`docs/records/2026-11-08-issues-are-the-backlog.md`). `docs/records/` keeps
research and decisions. When work reveals a new todo, open an
issue rather than leaving a TODO comment or a note in a doc.

Before starting an issue, re-read it (it may have closed since you listed
it) and check the open PRs for one that names it (`gh api
'repos/aegatlin/qot/pulls?state=open'`, then search the bodies for `#N`).
A commit that finishes an issue says `Fixes #N`.

## Repo layout

| Directory | What |
|---|---|
| `core/` | `qot_core` (Rust): the note model and its sync primitives. Shared by every client. |
| `core_ffi/` | `qot_ffi` (Rust): `qot_core` for Swift/Kotlin via UniFFI. Adapts types only; no rules. |
| `core_wasm/` | `qot_wasm` (Rust): `qot_core` for the browser via wasm-bindgen. Adapts types only; no rules. |
| `core_nif/` | `qot_nif` (Rust): `qot_core` for the server (Elixir) via Rustler. Adapts types only; no rules. |
| `client_cli/` | `qot` binary (Rust), uses `qot_core` directly. |
| `client_apple/` | Every Apple target in one committed Xcode project; `QotKit/` is the shared SwiftPM package. |
| `client_web/` | The PWA (`app.quantumofthought.com`): Vite + TypeScript + Preact over `qot_wasm`. |
| `site_web/` | The website (`www.quantumofthought.com`): Astro, static HTML and CSS. |
| `server_web/` | Phoenix server: accounts, device sign-in, note sync. |
| `docs/` | `go-to-market.md` and `records/`: dated research and decision records (see its README). |

Folders are **per build toolchain, not per device**: a new device is a new
target in an existing folder unless it needs a new toolchain
(`docs/records/2026-11-04-repo-layout-for-clients.md`). `core/`, `core_ffi/`,
`core_wasm/`, `core_nif/` and `client_cli/` form one Cargo workspace (root `Cargo.toml`,
one committed `Cargo.lock`, one `target/`).

## Tooling

One root `mise.toml` pins every tool (Rust, Erlang, Elixir, Node,
wasm-bindgen, binaryen, cargo-dist) and holds every
task, named `<action>:<component>`; the bare `test` and `lint` run all of
their components.
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
  moving both ways live, offline capture, a wrong code and deleting the
  account from the browser. `e2e/voice-memo.spec.ts` plays the phone (it
  makes a memo with the wasm core in Node, syncs it through a CLI device and
  uploads the recording) and checks that the PWA shows it, plays it, and
  deletes it everywhere. Extend it rather
  than clicking through by hand. Locally it needs Playwright's browser once:
  `cd client_web && npx playwright install chromium`.
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
(a test inbox was part of #11, deferred), and agents don't create accounts on production.

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
mise run build:web     # or build:site, build:wasm-core, build:apple-core
mise run server        # alias: s
mise run cli-install   # alias: ci; installs `qot`
mise run xcode         # builds the Apple core, opens the Xcode project
```

## Conventions

- **TDD.** Write the failing test first, then the code.
- **Docs change with the code.** Agents act on what CLAUDE.md, the READMEs,
  `docs/records/` and comments say, so stale text is a bug. A change that
  makes any of them wrong fixes them in the same PR (records: mark the old
  part superseded, see `docs/records/README.md`), and a retired file is
  deleted, not left behind.
- **Functional core, imperative shell.** Logic lives in pure functions over
  immutable values that are tested without I/O; storage, network and UI are a
  thin shell around them. In `qot_core` every operation on a `Note` returns a
  new `Note` rather than mutating one.
- **License: AGPL-3.0-only**, sole copyright held by Abstract Syntax LLC (no outside code until there is
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
  creation time), `content` (Automerge text), `deleted`, and any
  attachments.
- **Attachments** (`attachment.rs`; a recording, later images and video):
  each is a map at the note's root under `attachment:<id>` (`kind`,
  `media_type`, `size`, `duration_ms`, `text`), never one shared map, which
  two devices could both create and lose an attachment in the merge. The
  bytes are a blob with the same id, outside the note. `attach`, `detach`
  (keeps the text), `fill_text` (writes a `pending` transcript into the
  content, once). A note with an attachment and no text is a note:
  "empty" is `is_empty()`, no text and no attachments. A kind or field
  this code doesn't know is listed (`label()`: `audio 0:42`, `image, 2 MB`)
  and survives every edit.
- **Delete is a tombstone**, never removing the document: a removed note
  would be resurrected by the next sync from a device that still has it.
  Clients hide tombstones.
- **Every `Note` holds a fully committed document.** An uncommitted edit gets
  committed with a fresh timestamp whenever heads are read, so the same note
  would report different heads on every call and incremental sync would break.
- **Every edit starts on a fresh actor** (`branch()`), so two edits made
  from the same `Note` value merge instead of failing with "duplicate seq".
  Commits carry their time (Unix seconds), which is `updated_at_ms()`.
- Sync primitives: `heads()`, `changes_since(heads)` (empty heads = the whole
  note; unknown heads are an error, not "send everything") and
  `apply_changes(bytes)` (idempotent). The automerge-repo sync stack is
  deliberately not used while it is being rebuilt around Subduction.

## Sync and end-to-end encryption

**Direction changed 2026-11-20**
(`docs/records/2026-11-20-pipelines-before-encryption.md`): the server is
to become a peer that reads and **edits** notes, for pipelines a person
sets up (triggers such as a leading `#appidea` send a note to a service
that adds to it; cloud transcription is the first). That vision ranks
above end-to-end encryption, which is still wanted but must be designed
around pipelines (#72). The server can run `qot_core` (`Qot.Core`, the
Rustler NIF in `core_nif/`, #113) but nothing calls it yet: appending its
own changes to the log, and the first pipeline (transcription, #114), are
not built.

**What the code does today**: the server doesn't read note content. It
keeps a per-user, append-only log of opaque change blobs and relays them;
clients do all merging with `qot_core`. The privacy policy says nothing we
run reads notes, so it changes before any pipeline runs in production
(#116). A
pipeline runs only because the person set it up or turned it on.

- `POST /api/sync/push` `{changes: [{note_id, data}]}` (data base64) appends
  and returns `{cursor}`. Optional `deleted_blobs: [id]` deletes those blobs
  in the same transaction: the server can't see in a change that an
  attachment went, so the client says so.
- `GET /api/sync/pull?since=N&limit=M` returns `{changes: [{seq, note_id,
  data}], cursor, more}`. A client stores `cursor` and pulls from it next.
- The `notes:user:#{user_id}` channel only nudges (`"changed"` with the new
  cursor); data always moves through pull, so there is one path.
- **Seqs are per user and gap-free**: a push reserves its range by
  incrementing `users.change_seq` under that row's lock. A global sequence
  would let a reader at cursor N miss a slower transaction that commits a seq
  below N later. `Qot.SyncConcurrencyTest` pins this.
- Request parsing is pure (`Qot.Sync.Batch`); `Qot.Sync` is the I/O shell.
- **Blobs** (`Qot.Blobs`; attachments' bytes) are as opaque as changes: no
  media type is stored and the bytes are never inspected. `PUT
  /api/blobs/:id?note_id=` takes the raw body whatever its `content-type`
  (the endpoint skips `Plug.Parsers` for `/api/blobs`, which would consume
  or reject it) and is idempotent: 204, 413 `too_large`, 403
  `quota_exceeded`, 410 `deleted`. `GET /api/blobs/:id` answers
  `application/octet-stream`, 404 when it isn't there or isn't yours. Ids
  are the attachment's, unique per user. A deleted blob keeps its row
  without the bytes, and an id deleted before it was uploaded gets one too,
  so a late upload from a device that was offline is refused. Limits
  (`:blob_limits`; 25 MB a blob, 1 GB an account; `BLOB_MAX_BYTES`,
  `BLOB_QUOTA_BYTES`) are checked under the user row's lock. In Postgres
  for now; the record says when to move the bytes to a bucket.

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
- **Blobs** (attachments' bytes) move beside the change log. `plan_push`
  names, per note, the blobs to delete with that push (`deleted_blobs`:
  attachments it had at the heads last pushed and has no more, or the note
  is a tombstone). `plan_blobs(notes, state, local)` says what to do with
  the blob files a device holds: upload those whose attachment has been
  pushed (note first, bytes after) and aren't in `SyncState.uploaded`, and
  discard those no live note refers to, which is how a delete made
  elsewhere removes the file here. `mark_uploaded` after an upload or a
  download; `forget_blobs` after a discard. A recording in progress is kept
  out of `local` until its note is saved. `plan_blobs` also discards a
  blob the state remembers as uploaded once no live note has it, so
  `SyncState.uploaded` doesn't grow.
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
  JSON (`id`, `created_at` from the UUIDv7, `content`, and `attachments`
  when a note has any): the data export, since a synced device has
  everything the server has. `qot export --dir <dir>` writes `notes.json`
  and each attachment's bytes (`attachments/<id>.m4a`, named in the JSON as
  `file`), fetched from the server, so it needs a sign-in when there are
  attachments; one the server doesn't have is named and the command fails,
  with the notes still written. `qot delete-account`
  asks for the email to be typed, then deletes the account on the server;
  notes stay on the device. `qot status` shows the account, the server
  (labelled production, staging, local or custom), live notes and how many
  have changes not pushed yet, the data dir and the version; offline, and
  never prints tokens. Every request sends `User-Agent:
  qot-cli/<version> (<os>; <arch>)`.
- `qot edit <n>` (alias `e`) opens note `n` (numbered as in `qot list`)
  in `$VISUAL`, else `$EDITOR`, else `vi`, run through `sh` so values like
  `code --wait` work. The edit is made against the version the editor was
  shown and merged into the note on disk, so a change synced in meanwhile is
  kept. Unchanged text saves nothing; emptied text is refused (deleting is
  `qot delete`'s job) unless the note has an attachment, which is then
  kept without text; a failing editor leaves the note alone. Rules in
  `edit.rs` (pure), tests in `tests/edit_test.rs`.
- `qot web` (alias `w`) opens the web app: the `app_url` the server gave
  at sign-in (kept in `credentials.json`), else the known app for qot's
  own servers (production, staging, local), signed out included; another
  server signed in to before 0.4.0 says to sign in again. It prints the
  address, then runs `$BROWSER`, else `open` (macOS) or `xdg-open`. Rules
  in `web.rs` (pure), tests in `tests/web_test.rs`.
- **Attachments**: `qot record [words]` (alias `r`; 0.5.0) records a
  voice memo with the machine's own recorder until Enter or Ctrl-C and
  saves it as a new note (the words, if any, are its text): `$QOT_RECORDER`
  (a command line run through `sh`, given the file; told to stop with `q`
  on its input, then an interrupt), else `ffmpeg` on macOS (avfoundation)
  and Linux (PulseAudio, which PipeWire answers for); anywhere else, or
  without ffmpeg, it says what to install. AAC in an .m4a, mono, 64 kbps,
  30 minutes at most, like the iPhone's; its text status is `none`,
  since the CLI doesn't transcribe. The file is written to
  `recordings/`, then becomes `blobs/<attachment id>` just before its note
  is saved. A sync is push, pull, then blobs (`plan_blobs`): upload (`PUT
  /api/blobs/:id`; a 410 "deleted" drops the file), and remove files no
  live note has; `delete` removes them too. The CLI keeps blob files only
  for recordings made on it. `qot play <n>` (alias `p`) plays note `n`'s
  recordings: one made here from its file, others fetched from the server
  (so those need a sign-in; one not uploaded yet says so) to a
  temporary file. It runs the machine's player and waits until it
  ends: `$QOT_PLAYER` (a command line, run through `sh` like the editor),
  else the first installed of `afplay` (macOS), `ffplay` and `mpv`. No
  audio library is linked: it would need the system's sound libraries,
  which the musl builds don't have. Rules in `record.rs` and `play.rs`
  (pure), tests in `tests/record_test.rs`. The CLI doesn't transcribe;
  `qot record --transcribe` (`-t`, or `$QOT_TRANSCRIBE=1`; never
  otherwise) sends the recording to the server's `POST
  /api/transcriptions` after the sync and writes the text into the note
  (`fill_text`, under any words given), then syncs again. The attachment
  is `pending` meanwhile; a refusal (no paid plan, allowance used, a
  server that doesn't transcribe) is printed as `(no text: …)` and marks
  it done, the memo kept.
  A note's line (`qot list`, and what `edit` and `delete` print) starts
  with a marker per attachment, `[audio 0:42]`, from the core's `label()`,
  so kinds it doesn't know show too. Deleting a note that has a recording
  sends `deleted_blobs` with the push (`tests/attachments_test.rs`).
- Capture never waits on the network: `add` (and the bare form, `qot get
  milk`), `delete`, `list` and `export` run a best-effort sync with a 3 s timeout when signed in, and print
  `(not synced: …)` to stderr when offline. The note is saved first.
- Store layout under the data dir: `notes/<id>.note` (Automerge bytes),
  `sync.json` (`SyncState`), `credentials.json` (tokens, mode 0600),
  `blobs/<id>` (recordings made here) and `recordings/` (one being made).
- Sync rules live in `qot_core::sync`; `service.rs` and `api.rs` are the
  I/O shell. Integration tests run the binary against `httpmock`
  (`tests/sync_test.rs`).
- **Releasing** is [dist](https://axodotdev.github.io/cargo-dist/): bump
  `version` in `client_cli/Cargo.toml`, merge, then push a `cli/vX.Y.Z`
  tag on that merge commit. **Who pushes release tags** (every component:
  `cli/v*`, `server/v*`, `web/v*`, `site/v*`): a person, or an agent on
  the owner's own machine that the repo owner has authorized to release,
  in that session or in memory
  (`docs/records/2026-11-19-agents-may-release.md`); without that, agents
  don't push tags or move the production branches. **Cloud sessions never
  release**: Anthropic's GitHub proxy allows branch pushes only, so they
  can't push tags, and they don't move the production branches either.
  Check the tag
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
- **Xcode Cloud** builds for TestFlight on pushes to `main`, and is how
  iOS releases are made (no `ios/v*` tags or Actions uploads). Its start
  condition is "any file in `client_apple/`, `core/` or `core_ffi/`", and
  a push of several commits started no build when only an earlier commit
  touched them (2026-11-19: `54d9699` got none), so check that a build of
  an Apple change arrived (`asc xcode-cloud build-runs`) and, if not,
  start one in Xcode or push an Apple commit on its own.
  `ci_scripts/ci_post_clone.sh` stays minimal: rustup at the Rust version
  pinned in `mise.toml` (no mise there), then `scripts/build-apple-core
  --release`.
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
- **Voice memos, the logic** (QotKit): `NoteStore.addMemo` moves a finished recording
  into `blobs/<attachment id>` and saves its note in one locked step
  (transcript nil = `pending`, filled in later by `fillTranscript`;
  `pendingTranscripts` lists what waits). `removeAttachment` keeps the
  text; `delete` and it sweep blob files no live note has. `Syncer.sync`
  is push, pull, then blobs: it uploads what `plan_blobs` says (a 410
  "deleted" is dropped, not an error) and reports `uploaded`;
  `Syncer.blob(id)` returns a recording's file, fetching and keeping it,
  or throws `BlobError.notOnServerYet`. `Capture.addMemo` is the save then
  bounded sync for intents. `NoteItem.attachments`, `NoteItem.isEmpty` (no
  text and no attachments: what the editor discards) and
  `NoteList.title(of: NoteItem)` ("Voice Memo 0:42" for a recording with
  no text). Swift Testing has its own `Attachment`, so tests write
  `QotKit.Attachment`. A recording in progress is written to the store's
  `recordings/` (`newRecordingURL`), which no sync looks at;
  `strandedRecordings` finds ones a killed app left. `Capture.finishMemo`
  is what happens when a recording stops, in the order that loses least
  if the app is suspended part-way: save the memo with its text `pending`,
  sync (the note and the audio go up), transcribe through an injected
  closure, write the text in, sync again. The closure returns nil when
  this device can't transcribe (the memo is marked done with no text) and
  throws to be asked again (`transcribePending`, at the next launch; only
  for recordings whose file is here, so only on the device that made
  them). Tests: `VoiceMemoTests`, `MemoFlowTests`.
- **Voice memos, the app** (#100; simulator-checked, not yet verified on
  a phone): `MemoRecorder` (one per process; `AVAudioRecorder`, AAC in an
  .m4a, mono, 64 kbps, stops itself at 30 minutes, and stops and saves on
  an interruption such as a call) starts a Live Activity
  (`MemoAttributes`; iOS stops an intent-started recording without one),
  and on stop hands the file to `Capture.finishMemo` under a UIKit
  background task. `Transcriber` is `SpeechAnalyzer` + `SpeechTranscriber`
  over the file, on the device. At launch `MemoRecorder.launch()` takes
  the intents' calls, saves stranded recordings and retries transcripts.
  `Shared/MemoRecording.swift` (app and widget extension): `ToggleMemoIntent`
  (the "Voice Memo" Control Center toggle, `MemoControl`),
  `StartMemoIntent` and `StopMemoIntent` (Siri phrases in `QotShortcuts`,
  Shortcuts; stop is also the Live Activity's button). They are
  `AudioRecordingIntent`s, which iOS runs in the app's process, launching
  it in the background; they reach the recorder through
  `MemoRecording.set`, which only the app sets. The control's state is a
  flag in the App Group's `UserDefaults`. `start()` requests the Live
  Activity before it takes the microphone. **Starting in the background
  is not working on a phone yet** (2026-11-20, build 28: with qot not in
  front, the control fails with `cannotInterruptOthers`, 560557684, at
  `setActive`; in front it works). `activateSession` now tries a
  recording-only session, then a mixable `playAndRecord` one, and the
  error says whether the Live Activity started; untested. An intent that fails can show nothing in
  Control Center, so `MemoRecording.run` keeps why (`lastFailure`, App
  Group) and the app shows it when next opened. The microphone question can only
  be asked with the app in front, so the first memo must be recorded in
  the app. In the app: the list's microphone button (`RecordButton`), and
  in the editor a player above the text (`AttachmentList`, `RecordingRow`:
  fetched on first open through `Syncer.blob`, "Audio on its way" retried
  every 10 s) and More → Remove Audio. `Info.plist`: the `audio`
  background mode and `NSSupportsLiveActivities`. The upload is the
  ordinary sync, not a background `URLSession` (#103). Export notes
  doesn't include the audio files (#104).
- **The store is in the App Group** (`AppGroup.store()`: `<group
  container>/qot/`), in the CLI's layout (`notes/<id>.note`, `sync.json`,
  `blobs/<id>`), so intents and widgets share it; notes from the app's old Application
  Support store are merged in on launch. Every process may write: note
  read-modify-writes hold `store.lock` and save by merging with what is on
  disk; a sync holds `sync.lock` (both `flock`). Tokens are in the Keychain
  with the App Group as access group, readable after first unlock.
- **The app is Notes-shaped** (`NotesView`, `NoteEditor`): notes grouped by
  last edit (Today, Yesterday, …; the rules are `NoteList` in QotKit, title =
  first line), search, swipe to delete, compose in the bottom toolbar; the
  editor saves as you type (`NoteStore.update`, sync after a pause) and
  discards a note left empty. HIG controls only.
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
  Its callbacks run off the main thread, so they are made in `nonisolated`
  functions: a closure written in a main-actor method crashes there
  (Swift 6 checks it). A
  voice memo (above) is the separate gesture that keeps its recording.
- The app syncs on launch and foreground, after every capture and delete
  (in the background; capture never waits), on pull-to-refresh, on the
  channel nudge while open, and in a `BGAppRefreshTask`
  (`llc.abstractsyntax.qot.sync`). The account sheet signs in against
  production, staging or any URL (`http://localhost:4000` from the
  simulator; ATS allows local networking only). Requests send `User-Agent:
  qot-ios/<version> (iOS <version>; <model>)`.
- **Sign in with Apple** is the account sheet's main sign-in
  (`SignInWithAppleButton`, email scope, a nonce whose SHA-256 goes to
  Apple; `Account.signInWithApple` posts the token, and Apple's
  authorization code for revoking on deletion, to `/api/auth/apple`); the
  email device sign-in stays below it. The App ID needs the Sign in with
  Apple capability (`com.apple.developer.applesignin` in
  `App/Qot.entitlements`) before Xcode Cloud can export.
- **App icon**: `AppIcon.icon` (Icon Composer: one icon for every Apple
  platform; layers are SVGs, the PWA's icon split into ring and dot). Each
  target folder carries its own copy (`App/`, `Watch/`, later the Mac);
  keep them identical. Edit in Icon Composer, then copy it over the others.
- **Export compliance**: `App/Info.plist` sets
  `ITSAppUsesNonExemptEncryption` to `NO` (only HTTPS and the Keychain, both
  Apple's), so TestFlight doesn't ask per build. End-to-end encryption (#72)
  changes that answer.
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

- The PWA: capture, list, delete, sync, the device sign-in page, Sign in with Apple, and deleting the account (`deleteAccount` in `session.ts`, like `qot delete-account`: the email typed again, the session forgotten, notes kept). Same
  rules as every client: `qot_wasm` (`core_wasm/`) wraps `qot_core`;
  `scripts/build-wasm-core` (`mise run build:wasm-core`) compiles it and
  generates the JS bindings into `client_web/src/core/` (gitignored); rerun
  after any Rust change. `--release` uses Cargo's `wasm-release` profile and
  `wasm-opt` (~510 KB gzipped). wasm-bindgen's CLI is pinned in `mise.toml`
  and must equal the crate version.
- Layout: pure logic in `notes.ts`, `session.ts`, `config.ts` and the core;
  the shell is `api.ts` (HTTP), `store.ts` (IndexedDB, the CLI's layout:
  notes by id, `sync` and `credentials` in `meta`, and `blobs` by
  attachment id), `local.ts` (capture, edit, delete, remove an attachment:
  each a read-modify-write under the store lock), `sync.ts` (push then
  pull, state saved after each step), `blobs.ts` (an attachment's bytes,
  fetched when its note is first opened), `live.ts` (the Phoenix channel
  nudge), `app.tsx` (Preact). Errors are `Result` values
  (`result.ts`).
- The UI is a header (brand left; right, "Sign in" when signed out, else
  the sync status and the account's initial, whose menu has the email,
  Settings and Sign out) over a Notes-style list (a one-line capture field,
  search, title = first line, preview, newest edit first) and an editor at
  `/notes/<id>` (two panes when wide). Pages: `/sign-in` (Apple, then the
  email sign-in), `/settings` (sync now, sign out, delete account),
  `/auth/device` (an emailed link). Everything else routes to the list.
  **Copy takes no view of which clients someone uses**: the PWA never
  mentions the CLI, a terminal or other apps ("the device you're signing
  in", not "your terminal"). Edits save as you type (debounced) as the editor's diff from
  the version it was typed over, merged into the stored note
  (`applyEdit`), so a change synced in meanwhile is kept; the editor shows
  the stored note again once it has no unsaved typing. Leaving an emptied
  note deletes it.
- **Attachments** show above a note's text. A recording is a "Voice memo
  0:42" with the browser's own audio controls; the PWA plays but doesn't
  record yet (#101). Its bytes are fetched when the note is opened
  (`loadBlob`), kept in IndexedDB so it then plays offline, and marked as
  on the server in the sync state. Until the device that recorded it has
  uploaded it, the note says "Audio on its way" and asks again every 10 s.
  "Remove audio" keeps the text; clearing the text keeps the recording (a
  note is discarded only when it has neither, `shouldDiscard`); deleting
  the note takes both. A push carries `deleted_blobs`, and blobs no live
  note refers to are deleted here by `discardBlobs`, after a local delete
  and at the end of every sync. A kind this build doesn't know is named
  and left alone. Tests: `tests/attachments.test.ts`.
- **Sign in with Apple** (#87; `apple.ts`): Apple's JS SDK, loaded from
  Apple only when the sign-in card shows, in popup mode, with the Services
  ID `llc.abstractsyntax.qot.web` (return URL `<origin>/auth/apple`,
  registered for `app.` and `staging-app.` only, so the button shows only
  there). The SDK is set up with the nonce's SHA-256 before the click (Safari
  blocks a window opened after an await); the identity token, raw nonce and
  authorization code go to `/api/auth/apple` like iOS. The CSP allows
  `appleid.cdn-apple.com` scripts and `appleid.apple.com` frames for it.
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
  CSP whose `connect-src` is the API and its `wss:` (scripts: self and
  Apple's SDK; `media-src blob:` for recordings, which play from bytes the
  app fetched), `Referrer-Policy:
  no-referrer` (sign-in links carry a token). Staging deploys green pushes
  to `main` touching `client_web/`, `core/`, `core_wasm/` or `Cargo.lock`;
  production deploys the `production-web` branch, which
  `.github/workflows/release-web.yml` moves to a `web/v*` tag (pushed by a
  person or an authorized agent, see the CLI's Releasing) and then smoke-tests (`scripts/smoke-test-web <app> <api>
  [<sha>]`, also run for staging by `smoke-web.yml`; it checks the API's
  CORS for the app too).

## Website (`site_web`)

- `www.quantumofthought.com`: what qot is, `/install` (every client),
  `/iphone` (every way to capture on iPhone and Apple Watch; keep it in step
  with the app's intents, widgets and Siri phrases),
  `/support` (contact, export, account deletion, FAQ), `/privacy` and
  `/terms` (approved 2026-11-17, #17; plain-language texts with no lawyer's
  review yet. They state facts about the code, so a change to what the server
  stores, who handles data or where export and delete live changes them and
  their `updated` date in the same commit; `draft: true` in the frontmatter
  shows a banner on a new, unapproved text). The Abstract Syntax site
  (`aegatlin/abstract_syntax`, `www.abstractsyntax.llc`) links here.
- **Astro**, built to plain HTML and CSS with **no JavaScript of its own**: pages in
  `src/pages/` (`.astro`, or `.mdx` with `layouts/Prose.astro` for long text).
  The shadcn/ui components (`src/components/ui/`) and `lib/utils.ts` are
  copied from the Abstract Syntax site and render at build time only through
  `@astrojs/react`; the config deletes the client bundle it emits anyway. The
  theme in `src/styles/global.css` keeps shadcn's token names with qot's
  palette (the PWA's), light and dark from `prefers-color-scheme`.
- `build.format: "file"`: `/privacy` is `privacy.html`, so the server must
  try `<path>.html`. `compressHTML` is off because it ate the space before
  inline tags.
- **Plausible** counts page views (#61,
  `docs/records/2026-11-10-website-analytics.md`): one `<script>` in
  `layouts/Base.astro`, proxied by Caddy from this origin (`/js/script.js`,
  `/api/event`); events go to Plausible only for the `www.` host, else Caddy
  answers 202. Website only: the PWA and the other clients send nothing to
  Plausible, and the privacy policy says so. No other scripts, fonts or
  trackers. `tests/site.test.mjs` (`mise run test:site`) checks the build:
  every page and internal link, no `<script>` but Plausible's, no JS files,
  nothing loaded from another origin, and the facts the install, support and
  privacy pages must state.
- **Deploys**: the PWA's shape. Railway service `site`, built from
  `site_web/Dockerfile` with the repo root as context (Node, then Caddy;
  `NODE_VERSION` must match `mise.toml`, which CI checks). `bin/site` starts
  Caddy (`site_web/Caddyfile`): `/health` `{status, commit}`, clean URLs
  (`/privacy` serves `privacy.html`; `.html` and trailing slashes redirect),
  `404.html`, immutable `/_astro/*`, `no-cache` elsewhere, the Plausible
  proxy, and a CSP that allows scripts and connections to this origin only. Staging (`staging-www.`) deploys green pushes to `main`
  touching `site_web/`; production (`www.`) deploys the `production-site`
  branch, which `.github/workflows/release-site.yml` moves to a `site/v*` tag
  (pushed by a person or an authorized agent, see the CLI's Releasing), then smoke-tests (`scripts/smoke-test-site <url>
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
  the JWT, verified before channel join. Both also check the user still
  exists, so a deleted account's tokens (valid up to an hour) get 401. The pure rules live in
  `Qot.Accounts.DeviceLogin` (status, code checks).
- **Sign in with Apple** (`docs/records/2026-11-08-sign-in-with-apple.md`):
  `POST /api/auth/apple {identity_token, nonce}` (the raw nonce) returns the
  device sign-in's tokens. The server checks the token itself (RS256 against
  Apple's keys, `iss`, `aud` in `APPLE_CLIENT_IDS`, `exp`, `nonce` = SHA-256
  hex of the raw one), then signs in the user with that `users.apple_sub`,
  else links the account with the same verified email (case-insensitive),
  else creates one. Pure rules in `Qot.Accounts.AppleIdentity`; Apple's keys
  are cached by `Qot.Accounts.AppleKeys` (refetched for an unknown `kid`, at
  most once a minute). Tests sign tokens with `Qot.AppleTestKeys`
  (`test/support/`), never Apple. No email, so no rate limit. Errors: 401
  `invalid_token`, 409 `email_in_use` (unverified email or an account linked
  to another Apple ID), 422 `email_required`, 503 `apple_unavailable`.
  An optional `authorization_code` is exchanged at Apple's `/auth/token` for
  Apple's refresh token, kept on the user (`apple_refresh_token`,
  `apple_client_id`) only so deleting the account can revoke it (#88; App
  Review 5.1.1(v)). Both calls sign a client secret (ES256, 5 minutes) with
  the Sign in with Apple key (`APPLE_SIWA_KEY`, `APPLE_SIWA_KEY_ID`);
  `Qot.Accounts.AppleTokens`, faked in tests by `Qot.AppleTestTokens`. Both
  are best effort: a failed exchange or revoke is logged, never blocking a
  sign-in or a deletion.
- **Cloud transcription** (`Qot.Transcription`; #111,
  `docs/records/2026-11-20-paid-transcription.md`): `POST
  /api/transcriptions[?duration_ms=]`, one recording as the raw body
  (read like a blob, under the blob size limit; `content-type` only picks
  the file name the provider sees), answers `{text}`. The server keeps
  neither the audio nor the text, only seconds used per account and month
  (`transcription_usage`), and never touches notes: the client writes the
  text in. Refusals: 402 `plan_required` (`users.plan` must be `plus`;
  set by hand with `Qot.Release.set_plan/2` until billing exists, #112),
  429 `allowance_used` (seconds are reserved under the user row's lock
  before the provider is asked, given back if it fails; a recording
  counts for what the client states but at least its size at 128
  kbit/s), 503 `transcription_unavailable` (no provider configured), 502
  `provider_failed`. The provider is `Qot.Transcription.Provider`: any
  service with OpenAI's `/v1/audio/transcriptions` shape, by Req; tests
  use `Qot.TestTranscriber`. **No environment has a provider key yet, and
  none may get one before the privacy policy names the provider and says
  that it and the server hear a recording sent this way.** No real
  provider has been called.
- **Account deletion**: `DELETE /api/account {confirm: <the account's
  email>}` removes the user, refresh tokens, change log, blobs, transcription usage and sign-ins
  (`Qot.Accounts.delete_user/1`), revokes its Apple token if it has one, and
  closes the user's sockets. A
  server-side export would only be opaque change blobs, so export is the
  client's job.
- **`Qot.Core`** is `qot_core` as a NIF (Rustler; crate `qot_nif` in
  `core_nif/`), so the server reads and edits notes with the clients'
  rules. A note is passed as its changes from the account's log, in order
  (`Note::from_changes`): `read(changes)` gives `%{id, content, deleted,
  heads, attachments}`; `fill_text(changes, attachment_id, text)` gives
  the change to append, or `nil` when the attachment wasn't waiting for
  text. Errors are `{:error, message}`, never a crash; calls run on dirty
  CPU schedulers. `core/tests/vectors/server.json` (generated by
  `core/tests/server_vectors.rs`, regenerate with `-- --ignored
  regenerate`) is replayed by the core and by `Qot.CoreTest`. In dev and
  test Rustler compiles the crate with the local Rust (`mix compile` needs
  it; the result is `priv/native/`, gitignored). Add a function in
  `core_nif/src/lib.rs` and its stub in `lib/qot/core.ex` together.
- **Contexts**: `Qot.Accounts` (users, device sign-in, Sign in with Apple, tokens), `Qot.Sync`
  (the change log, always scoped by `user_id`), `Qot.Blobs` (attachments'
  bytes, the same).
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
  `server_web/`, `core/`, `core_nif/` or `Cargo.lock` (watch patterns). Production deploys the `production` branch,
  which `.github/workflows/release-server.yml` moves to a `server/v*` tag
  after CI passes. Production has **no watch pattern** on purpose: Railway
  checks only the files the pushed commit changed, so a tag on a docs-only
  commit would be skipped. The tag is pushed by a person, or by an agent
  the repo owner has authorized to release (see the CLI's Releasing).
  **The promote job pushes with a deploy key** (all three release
  workflows): `RELEASE_DEPLOY_KEY`, a secret of the `production` GitHub
  environment, is the private half of the deploy key "release workflows
  (promote job)" (write access, this repo only; no expiry), handed to
  `actions/checkout` as `ssh-key`. The workflow's `GITHUB_TOKEN` can't move
  the branch: GitHub refuses a push from it that brings workflow file
  changes, and it can't be given the `workflows` permission. To rotate:
  `ssh-keygen -t ed25519`, `gh repo deploy-key add <pub> --allow-write`,
  `gh secret set RELEASE_DEPLOY_KEY --env production < <private>`, delete
  the old deploy key and the local files. If a release workflow can't
  run, the same thing by hand is `git push --force origin
  <sha>:refs/heads/production` (or `production-web`, `production-site`),
  then the smoke workflow with `-f environment=production -f sha=<sha>`.
- **Smoke test** after every deploy (`.github/workflows/smoke.yml`, running
  `scripts/smoke-test <url> [<sha>]`): waits until `/health` reports the
  deployed commit (`commit`, from Railway's `RAILWAY_GIT_COMMIT_SHA`), then
  checks that the API answers. Read-only and sends no email, so it is safe
  against production. `release-server.yml` runs it for production after
  promoting. For staging, all three smoke workflows (`smoke.yml`,
  `smoke-web.yml`, `smoke-site.yml`) run on the GitHub deployment status
  Railway posts for "qot / staging", **never as `workflow_run` after CI**:
  Railway's "wait for CI" waits for every Actions run on the commit, so a
  smoke run waiting for the deploy deadlocked it and Railway skipped the
  deploy (#68). Each checks that staging runs the last commit that changed
  its service (or a later one), so a skipped deploy fails the next run.
- CI (`.github/workflows/ci.yml`) runs on every PR: Rust, server, the
  PWA (wasm, tests, e2e), the website, and the three Docker images, reading
  tool versions from `mise.toml`.
- Dev logs every email (sign-in links included) to the server's console.
- Production env: `DATABASE_URL`, `JWT_SECRET_KEY`, `RESEND_API_KEY`,
  `SECRET_KEY_BASE`, `PHX_HOST`, `APP_URL` (the PWA, e.g.
  `https://app.quantumofthought.com`: sign-in links open it and its origin is
  the one browser origin allowed; dev defaults to `http://localhost:5173`).
  Optional: `APPLE_CLIENT_IDS` (comma-separated client ids an Apple identity
  token may be for; default `llc.abstractsyntax.qot`; staging and production
  set `llc.abstractsyntax.qot,llc.abstractsyntax.qot.web` for the PWA), `APPLE_SIWA_KEY` and
  `APPLE_SIWA_KEY_ID` (the Sign in with Apple .p8 and its id, both or
  neither, in fnox; without them deleting can't revoke Apple tokens),
  `APPLE_TEAM_ID` (default `H88537CLVC`),
  `BLOB_MAX_BYTES` and `BLOB_QUOTA_BYTES` (the blob limits),
  `STT_API_KEY` with `STT_API_URL` and `STT_MODEL` (the transcription
  provider; all three or none) and `STT_MONTHLY_SECONDS` (each account's
  allowance, default 18000),
  `CLIENT_IP_HEADER` (default `x-real-ip`), `DATABASE_SSL=false` (a database on the host's private network; TLS with
  certificate verification is the default), `ECTO_IPV6=true`, `POOL_SIZE`,
  `PORT`. Dev and test need none.
- **Release**: `server_web/Dockerfile`, built **from the repo root**
  (`docker build -f server_web/Dockerfile .`; its ignore file is
  `server_web/Dockerfile.dockerignore`), compiles the NIF in a Rust stage,
  then builds a `mix release` with `QOT_NIF_PREBUILT=1`, which tells
  `Qot.Core` to load `priv/native/qot_nif.so` instead of compiling (Rust,
  Elixir and Erlang versions match `mise.toml`, which CI checks for Rust;
  bump them together). Railway's `server` service therefore needs root
  directory `/` and Dockerfile path `server_web/Dockerfile`, and staging's
  watch patterns `/server_web/**`, `/core/**`, `/core_nif/**`,
  `/Cargo.lock`: set on staging 2026-11-20; **production still has root
  `/server_web` and must be changed before the next `server/v*` tag**, or
  that deploy's build fails (the running version stays up). `bin/server` starts
  it; `bin/migrate` runs migrations and is the platform's pre-deploy step, so
  a failed migration fails the deploy instead of crash-looping the app.
  `GET /health` is 200 (`{status, commit}`) when the database answers, else
  503.
