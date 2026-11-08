#!/bin/sh
# Xcode Cloud runs this after cloning, before it resolves Swift packages.
# QotKit links the Rust core (QotFFI.xcframework), which isn't committed:
# install the Rust pinned in mise.toml and build it, as on a developer's Mac.
# https://developer.apple.com/documentation/xcode/writing-custom-build-scripts
set -eu

cd "${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/../.." && pwd)}"

if ! command -v mise >/dev/null 2>&1; then
  brew install mise
fi
export MISE_YES=1
mise trust mise.toml
mise install rust
mise exec -- scripts/build-apple-core --release
