#!/usr/bin/env bash
# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Run as the image's admin user through Tart's guest-agent channel.
set -euo pipefail
[[ $(uname -m) == arm64 ]] || exit 1
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
brew install bash ninja cmake rsync xz ccache jq
xcrun --find clang
xcrun --show-sdk-path
runner="$HOME/actions-runner"
test ! -e "$runner/.runner"
test ! -e "$runner/.credentials"
mkdir -p "$runner"
archive=$(mktemp)
trap 'rm -f "$archive"' EXIT
curl -fL --retry 3 -o "$archive" https://github.com/actions/runner/releases/download/v2.336.0/actions-runner-osx-arm64-2.336.0.tar.gz
printf '%s  %s\n' 8e8839c49b7060b6b2154f4931f815df330c27f167d53ef2239ee3dfce28b079 "$archive" | shasum -a 256 -c -
tar -xzf "$archive" -C "$runner"
# The controller uses the guest agent, never these template SSH credentials.
rm -f "$HOME/.ssh/authorized_keys" "$HOME/.bash_history" "$HOME/.zsh_history"
rm -rf "$HOME/.cache/ccache" "$HOME/Library/Caches/ccache" "$HOME/.cache/elide-toolchain"
mkdir -p "$HOME/toolchain-release-image"
brew list --versions > "$HOME/toolchain-release-image/packages.txt"
sw_vers > "$HOME/toolchain-release-image/macos.txt"
printf 'runner=2.336.0\nsha256=8e8839c49b7060b6b2154f4931f815df330c27f167d53ef2239ee3dfce28b079\n' > "$HOME/toolchain-release-image/runner.txt"
test ! -d "$runner/_work"
printf 'Release macOS image provisioning complete\n'
