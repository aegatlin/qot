#!/bin/sh
# Xcode Cloud runs this after cloning, before it resolves Swift packages.
# QotKit links the Rust core (QotFFI.xcframework), which isn't committed:
# install the Rust pinned in mise.toml and build it, as on a developer's Mac.
# Only Rust: `mise exec` would otherwise install every tool in mise.toml
# (Erlang, Node, wasm-bindgen…), and GitHub downloads from Xcode Cloud are
# slow enough to time out (build 5).
# https://developer.apple.com/documentation/xcode/writing-custom-build-scripts
set -eu

cd "${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/../.." && pwd)}"

if ! command -v mise >/dev/null 2>&1; then
  brew install mise
fi
export MISE_YES=1
export MISE_EXEC_AUTO_INSTALL=0
mise trust mise.toml
mise install rust
mise exec -- scripts/build-apple-core --release
