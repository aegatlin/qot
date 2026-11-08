# Why the Apple apps don't use automerge-swift

Status: decided
Date: 2026-11-08
Question: automerge-swift is Automerge's own, first-party Swift package. Why do
the Apple apps reach Automerge through our Rust core (`qot_core` via
`qot_ffi`) instead?

## Answer

**Because what the Apple apps need is qot's rules, not Automerge.**
automerge-swift would give Swift an Automerge document; qot's note model,
tombstones, the "always committed" heads rule and the whole client sync
algorithm (`qot_core::sync`) would then have to be written a second time in
Swift and kept identical to the Rust that the CLI and the PWA run. One core
behind thin bindings (rule 2 of
[the repo layout](2026-11-04-repo-layout-for-clients.md)) is the decision;
not using automerge-swift follows from it.

This is worth revisiting only if `qot_core` shrinks to "an Automerge document
and nothing else", which it won't: the sync rules are the product.

## What automerge-swift has going for it

It is a fair question, so the case for it, stated fully:

- **First party.** Maintained in the `automerge` GitHub organisation by the
  people who write Automerge. "Use the official library" is the default
  answer, and the burden is on not using it.
- **No Rust in the Apple build.** Its `Package.swift` pulls a prebuilt
  `automergeFFI.xcframework` from a GitHub release (0.7.2 as of this
  writing). Our setup compiles Rust on every Xcode Cloud build
  (`ci_scripts/ci_post_clone.sh`), which is slower and broke build 5 (tool
  downloads timing out).
- **A Swift-shaped API**, with Codable-style helpers (`AutomergeUtilities`)
  and a sibling, `automerge-repo-swift`, for networking and storage.
- **MIT**, so licensing is not the reason.

## Why it loses anyway

1. **It is the same Rust underneath.** automerge-swift is a UniFFI wrapper
   over the Rust `automerge` crate, like ours. Choosing it doesn't move us
   off Rust or UniFFI; it moves where the xcframework gets built (their CI
   instead of ours).
2. **It wraps Automerge, not qot.** Everything in `qot_core` sits above
   Automerge: a note is one document with `id`, `content` and `deleted`;
   delete is a tombstone; every `Note` is fully committed so heads are
   stable; `changes_since` errors on unknown heads rather than sending
   everything; and `qot_core::sync` (`plan_push`, `mark_pushed`,
   `apply_pulled`, `SyncState`) decides what to push and when a note's
   pushed heads may move. In Swift over automerge-swift, all of that is a
   reimplementation.
3. **Two implementations drift, and drift here loses notes.** The rules are
   subtle (`apply_pulled` must not move pushed heads when local edits are
   waiting, or those edits never go up). The shared test vectors
   (`core/tests/vectors/sync.json`) would catch some drift in a Swift
   rewrite, but they pin cases, not code; one implementation can't drift at
   all. CLI, PWA and iOS run the same compiled rules today.
4. **One Automerge version everywhere.** Every client writes bytes from the
   `automerge` crate pinned in `Cargo.lock` (0.12.0 now), upgraded once, in
   one PR, for all clients. automerge-swift pins its own Rust automerge on
   its own schedule; the Apple apps would sit on a different version from
   the CLI and the PWA, and an upgrade becomes two coordinated ones.
5. **Its sync stack is the one we deliberately don't use.**
   `automerge-repo-swift` follows automerge-repo, which qot avoids while it
   is rebuilt around Subduction (CLAUDE.md, "The note model"). Our server
   relays opaque change blobs through `/api/sync/push` and `/pull`; the
   automerge-repo protocol doesn't fit it, so only the bare document
   library would be usable anyway.
6. **It doesn't solve the Watch.** Its `Package.swift` declares iOS, macOS
   and visionOS, not watchOS, and the obstacle there (arm64_32 is a Tier 3
   Rust target) applies to any Rust underneath. The Watch relays to the
   iPhone either way.

## What it costs us, and the cheaper fixes

The real price of our choice is **building Rust in Apple CI**. That is a
build-speed and reliability problem, solvable without changing the
architecture:

- Install only Rust in Xcode Cloud, not every tool in `mise.toml` (done
  2026-11-08 after build 5).
- Pin Rust with `rust-toolchain.toml` so CI needs rustup, not mise (proposed).
- If it still hurts: publish `QotFFI.xcframework` as a release asset from
  GitHub Actions and point QotKit at it as a remote `binaryTarget` with a
  checksum, which is exactly what automerge-swift does for itself.

## Options considered

- **automerge-swift + a Swift port of `qot_core`**: rejected for the
  reasons above.
- **automerge-swift for the document, `qot_ffi` for sync only**: two
  Automerge runtimes in one app passing bytes between them, the worst of
  both.
- **Our own UniFFI crate over `qot_core`** (`qot_ffi`): chosen, 2026-11-04.

## Sources

- automerge-swift: https://github.com/automerge/automerge-swift (MIT;
  `Package.swift` read 2026-11-08: binary target from release 0.7.2,
  platforms iOS 13, macOS 10.15, visionOS 1). Which Rust automerge version
  it wraps was not checked.
- automerge-repo-swift: https://github.com/automerge/automerge-repo-swift
