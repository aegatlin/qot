# Quantum of Thought

A quick note capture tool: a thin feature set on a wide surface. Wherever you
are, capturing a note should be one natural gesture, and it should be on your
other devices by the time you look, even if you took it offline.

| Directory | What | Stack |
|---|---|---|
| `core/` | `qot_core`: the note model and its sync primitives, shared by every client | Rust, Automerge |
| `client_cli/` | `qot`, the command-line client (`qot get milk`) | Rust |
| `server_web/` | Accounts, auth and note sync | Elixir, Phoenix, Postgres |

Tools are pinned with [mise](https://mise.jdx.dev): run `mise install` at the
root, then `mise run test`. The server has its own `mise.toml` with its
toolchain, environment and tasks (`cd server_web && mise run test`).
