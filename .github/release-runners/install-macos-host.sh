#!/usr/bin/env bash
# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Install checksum-pinned virtualization tools, separate from Homebrew and native CI.
set -euo pipefail
[[ $(uname -m) == arm64 ]] || { echo 'Apple Silicon is required' >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fL --retry 3 -o "$tmp/tart.tar.gz" https://github.com/openai/tart/releases/download/2.41.1/tart.tar.gz
curl -fL --retry 3 -o "$tmp/softnet.tar.gz" https://github.com/openai/softnet/releases/download/0.25.0/softnet.tar.gz
printf '%s  %s\n' e680a734febccfce7d4e910c1f7f13fc3b00f19a181c945e2d746de3214c32c2 "$tmp/tart.tar.gz" \
  5a2e8ef779f0a2169b88d273ee806c0d64321ec7714c0dc99bf217523ae9b008 "$tmp/softnet.tar.gz" | shasum -a 256 -c -
mkdir "$tmp/tart" "$tmp/softnet"
tar -xzf "$tmp/tart.tar.gz" -C "$tmp/tart"
tar -xzf "$tmp/softnet.tar.gz" -C "$tmp/softnet"
codesign --verify --deep --strict "$tmp/tart/tart.app"
sudo install -d -m 0755 -o root -g wheel /opt/toolchain-release /opt/toolchain-release/bin
sudo cp -R "$tmp/tart" /opt/toolchain-release/tart-2.41.1
sudo install -m 4755 -o root -g wheel "$tmp/softnet/softnet" /opt/toolchain-release/bin/softnet
sudo chown -R root:wheel /opt/toolchain-release/tart-2.41.1
sudo chmod -R go-w /opt/toolchain-release/tart-2.41.1
sudo ln -sf /opt/toolchain-release/tart-2.41.1/tart.app/Contents/MacOS/tart /opt/toolchain-release/bin/tart
/opt/toolchain-release/bin/tart --version
