# qot_core

The note model and sync rules shared by every client: the CLI uses it
directly, the Apple apps through UniFFI (`core_ffi/`), and the PWA through
wasm-bindgen (`core_wasm/`).

A note is a small Automerge document (`id`, `content`, and a `deleted`
tombstone). Sync exchanges raw Automerge changes: a peer remembers the
`heads()` it last saw, sends `changes_since(heads)`, and the other side calls
`apply_changes`. See the module docs in `src/lib.rs`; the client sync rules (`SyncState`,
`plan_push`, `apply_pulled`) are in `src/sync.rs`, pinned by the shared
vectors in `tests/vectors/sync.json`.

```sh
cargo test -p qot_core
```
