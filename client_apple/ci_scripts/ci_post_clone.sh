#!/bin/sh
# Xcode Cloud runs this after cloning, before it resolves Swift packages.
# QotKit links the Rust core (QotFFI.xcframework), which isn't committed, so
# install Rust (with rustup, at the version pinned in mise.toml) and build it.
# https://developer.apple.com/documentation/xcode/writing-custom-build-scripts
set -eu

cd "${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/../.." && pwd)}"

rust=$(sed -n 's/^rust = { version = "\([^"]*\)".*/\1/p' mise.toml)
[ -n "$rust" ] || { echo "no Rust version in mise.toml" >&2; exit 1; }

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
  --profile minimal --default-toolchain "$rust" \
  --target aarch64-apple-ios --target aarch64-apple-ios-sim
. "${CARGO_HOME:-$HOME/.cargo}/env"

scripts/build-apple-core --release
