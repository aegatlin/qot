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
| `server_web/` | Phoenix server: accounts, magic-link auth, note sync. |

`core/` and `client_cli/` form one Cargo workspace (root `Cargo.toml`, one
committed `Cargo.lock`, one `target/`). The iOS app will reach `qot_core`
through UniFFI. A web client existed (React + the core compiled to WASM) and
was removed on 2026-11-02 while CLI and iOS come first; it is in git history.

## Tooling

Tools are pinned with mise. The root `mise.toml` pins Rust and holds the
workspace tasks; `server_web/mise.toml` pins Erlang/Elixir and declares the
server's environment, and mise layers it on top of the root config inside
that directory. Secrets go in a gitignored `mise.local.toml`. A new component
in another language gets its own `mise.toml` the same way, so working on one
component never requires another's toolchain or secrets.

```sh
mise run test          # Rust workspace tests
mise run lint          # rustfmt check + clippy -D warnings
mise run cli-install   # alias: ci; installs `qot`
cd server_web && mise run test
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
  `apply_changes(bytes)` (idempotent). The protocol on top of these is the
  server's job; the automerge-repo sync stack is deliberately not used while
  it is being rebuilt around Subduction.

## Server (`server_web`)

- **Auth**: passwordless magic links (15 min) issue a JWT access token (1 h,
  `user_id` claim) and a refresh token (30 days, hashed in the database).
  `RequireAuth` checks Bearer tokens for HTTP; WebSocket connect params carry
  the JWT, verified before channel join.
- **Contexts**: `Qot.Accounts` (users, magic links, tokens), `Qot.Notes`
  (notes, always scoped by `user_id`).
- **Per-user isolation**: every storage call takes `user_id`; PubSub topics
  and channels are `notes:user:#{user_id}`, joinable only by that user.
- **Storage**: `Qot.Storage.Adapter` behaviour, currently `EtsAdapter`
  (in memory, keys `{user_id, note_id}`). **Notes are lost on restart** until
  this moves to Postgres, which is the next server task.
- Note payloads are Automerge binary, base64 over the wire.
- Tests: `Ecto.Adapters.SQL.Sandbox`; Swoosh test adapter for emails;
  helpers in `test/support/` (`DataCase`, `ConnCase`, `ChannelCase`,
  `AuthHelpers`). ETS needs manual cleanup: `:ets.delete_all_objects(:qot_notes)`.
- Env (see `server_web/mise.toml`): `DATABASE_URL`, `FRONTEND_URL`,
  `JWT_SECRET_KEY`, `RESEND_API_KEY`.
