# Quantum of Thought

A quick note capture tool: a thin feature set on a wide surface. Wherever you
are, capturing a note should be one natural gesture, and it should be on your
other devices by the time you look, even if you took it offline.

| Directory | What | Stack |
|---|---|---|
| `core/` | `qot_core`: the note model and its sync primitives, shared by every client | Rust, Automerge |
| `core_ffi/` | `qot_ffi`: `qot_core` for Swift (and later Kotlin) through UniFFI | Rust |
| `client_cli/` | `qot`, the command-line client (`qot get milk`) | Rust |
| `client_apple/` | The iPhone app (Watch, Mac and widgets later), plus `QotKit`, the Swift package they share | Swift, SwiftUI, XcodeGen |
| `server_web/` | Accounts, auth and note sync | Elixir, Phoenix, Postgres |

Tools and tasks are pinned in one root `mise.toml`
([mise](https://mise.jdx.dev)): run `mise install`, then `mise run test`.
Server secrets go in a gitignored `mise.local.toml` (see the comment at the
top of `mise.toml`).

## Try it locally

```sh
mise install
cd server_web && mix setup && mix phx.server   # emails are printed here
cargo run -p qot_cli -- login you@example.com   # open the printed link, type the code
cargo run -p qot_cli -- get milk
```

The iOS app (macOS with Xcode): `mise run gen:apple` builds the Rust core
for Apple and generates `client_apple/Qot.xcodeproj`; open it and run the
`Qot` scheme. Rerun `mise run build:apple-core` after changing Rust.

## Roadmap

Launch todos and what comes after: [docs/ROADMAP.md](docs/ROADMAP.md).
Pricing and the free/paid line: [docs/go-to-market.md](docs/go-to-market.md).
