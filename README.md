# Quantum of Thought

A quick note capture tool: a thin feature set on a wide surface. Wherever you
are, capturing a note should be one natural gesture, and it should be on your
other devices by the time you look, even if you took it offline.

| Directory | What | Stack |
|---|---|---|
| `core/` | `qot_core`: the note model and its sync primitives, shared by every client | Rust, Automerge |
| `core_ffi/` | `qot_ffi`: `qot_core` for Swift (and later Kotlin) through UniFFI | Rust |
| `core_wasm/` | `qot_wasm`: `qot_core` for the browser through wasm-bindgen | Rust |
| `client_cli/` | `qot`, the command-line client (`qot get milk`) | Rust |
| `client_apple/` | The iPhone app, its widgets and the Watch app (Mac later), plus `QotKit`, the Swift package they share | Swift, SwiftUI |
| `client_web/` | The web app (`app.quantumofthought.com`) | TypeScript, Preact, `qot_core` as WASM |
| `site_web/` | The website (`www.quantumofthought.com`) | Astro, static |
| `server_web/` | Accounts, auth and note sync | Elixir, Phoenix, Postgres |
| `docs/` | Decision records and go-to-market notes | Markdown |

Tools and tasks are pinned in one root `mise.toml`
([mise](https://mise.jdx.dev)): run `mise install`, then `mise run test`.
Server secrets go in a gitignored `mise.local.toml` (see the comment at the
top of `mise.toml`).

## Install the CLI

macOS and Linux:

```sh
brew install aegatlin/tap/qot
```

or, without Homebrew (installs to `~/.local/bin`):

```sh
curl -LsSf https://github.com/aegatlin/qot/releases/latest/download/qot_cli-installer.sh | sh
```

Then `qot login you@example.com` and `qot get milk`.

## Try it locally

```sh
mise install
cd server_web && mise exec -- mix setup && mise exec -- mix phx.server   # emails are printed here
mise run dev:web                                # another terminal: the PWA, where sign-in links open
cargo run -p qot_cli -- login you@example.com --server http://localhost:4000   # open the printed link, type the code
cargo run -p qot_cli -- get milk
```

The iOS app (macOS with Xcode): `mise run xcode` builds the Rust core for
Apple and opens `client_apple/Qot.xcodeproj`; run the `Qot` scheme. Rerun
`mise run build:apple-core` after changing Rust. The simulator needs no
signing team; for your own device, set `DEVELOPMENT_TEAM` in
`client_apple/Config/Local.xcconfig` (gitignored).

## Roadmap

The backlog is the open [GitHub issues](https://github.com/aegatlin/qot/issues).
Pricing and the free/paid line: [docs/go-to-market.md](docs/go-to-market.md).

## License

[AGPL-3.0](LICENSE), copyright Abstract Syntax LLC. Why open source, and why this
license: [docs/records/2026-11-04-open-source-or-closed.md](docs/records/2026-11-04-open-source-or-closed.md).

Issues and ideas are welcome. Code contributions aren't accepted yet: see
[CONTRIBUTING.md](CONTRIBUTING.md).

"Quantum of Thought" and "qot" name this project and the service at
quantumofthought.com, both Abstract Syntax LLC's. A fork is welcome under the license, but needs its
own name.
