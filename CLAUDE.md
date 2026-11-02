# CLAUDE.md

## Product

Quantum of Thought (qot) is a quick note capture tool. The feature set is
deliberately thin (capture, list, delete, sync); the surface area is wide:
anywhere you are, capturing a note should be one natural gesture (`qot get
milk` in a terminal; the Action button, a Control Center control, Siri or a
voice memo on iOS). Notes taken offline must be on your other devices by the
time you look, without opening the app.

Clients, in priority order: CLI and iOS now; a Mac app next; web later.

## Repo layout

| Directory | What |
|---|---|
| `core/` | `qot_core` (Rust): the note model and its sync primitives. Shared by every client. |
| `client_cli/` | `qot` binary (Rust), uses `qot_core` directly. |
| `server_web/` | Phoenix server: accounts, device sign-in, note sync. |

`core/` and `client_cli/` form one Cargo workspace (root `Cargo.toml`, one
committed `Cargo.lock`, one `target/`). The iOS app will reach `qot_core`
through UniFFI. A web client existed (React + the core compiled to WASM) and
was removed on 2026-11-02 while CLI and iOS come first; it is in git history.

## Tooling

One root `mise.toml` pins every tool (Rust, Erlang, Elixir) and holds every
task, named `<action>:<component>` with the bare action running all of them.
A new component adds its tools and tasks there. Server secrets go in a
gitignored `mise.local.toml`; they are deliberately not `required` in
`mise.toml`, which would stop CLI tasks from running without them.

```sh
mise run test          # everything; or test:rust, test:server
mise run lint          # lint:rust (rustfmt check + clippy -D warnings)
mise run server        # alias: s
mise run cli-install   # alias: ci; installs `qot`
```

## Conventions

- **TDD.** Write the failing test first, then the code.
- **Functional core, imperative shell.** Logic lives in pure functions over
  immutable values that are tested without I/O; storage, network and UI are a
  thin shell around them. In `qot_core` every operation on a `Note` returns a
  new `Note` rather than mutating one.
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
  `RequireAuth` checks Bearer tokens for HTTP; WebSocket connect params carry
  the JWT, verified before channel join. The pure rules live in
  `Qot.Accounts.DeviceLogin` (status, code checks).
- **Contexts**: `Qot.Accounts` (users, device sign-in, tokens), `Qot.Sync`
  (the change log, always scoped by `user_id`).
- **Per-user isolation**: every sync call takes `user_id` from the token;
  channels are `notes:user:#{user_id}`, joinable only by that user.
- Mail: Swoosh's own Resend adapter with the Req client (no `resend`,
  `tesla` or `hackney`).
- Tests: `Ecto.Adapters.SQL.Sandbox`; Swoosh test adapter for emails;
  helpers in `test/support/` (`DataCase`, `ConnCase`, `ChannelCase`,
  `AuthHelpers`). `mix test` creates and migrates the test database.
- CI (`.github/workflows/ci.yml`) runs Rust and server checks on every PR,
  reading tool versions from `mise.toml`.
- Production env: `DATABASE_URL`, `JWT_SECRET_KEY`, `RESEND_API_KEY`,
  `SECRET_KEY_BASE`, `PHX_HOST` (sign-in links are built from it). Dev and
  test need none.
