# qot_core

The note model shared by every client: the CLI uses it directly, and the
Apple apps will reach it through UniFFI.

A note is a small Automerge document (`id`, `content`, and a `deleted`
tombstone). Sync exchanges raw Automerge changes: a peer remembers the
`heads()` it last saw, sends `changes_since(heads)`, and the other side calls
`apply_changes`. See the module docs in `src/lib.rs`.

```sh
cargo test -p qot_core
```
