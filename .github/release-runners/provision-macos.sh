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
curl -fL --retry 3 -o "$archive" https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-osx-arm64-2.338.2.tar.gz
printf '%s  %s\n' 25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388 "$archive" | shasum -a 256 -c -
tar -xzf "$archive" -C "$runner"
# The controller uses the guest agent, never these template SSH credentials.
rm -f "$HOME/.ssh/authorized_keys" "$HOME/.bash_history" "$HOME/.zsh_history"
rm -rf "$HOME/.cache/ccache" "$HOME/Library/Caches/ccache" "$HOME/.cache/elide-toolchain"
mkdir -p "$HOME/toolchain-release-image"
brew list --versions > "$HOME/toolchain-release-image/packages.txt"
sw_vers > "$HOME/toolchain-release-image/macos.txt"
printf 'runner=2.338.2\nsha256=25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388\n' > "$HOME/toolchain-release-image/runner.txt"
test ! -d "$runner/_work"
printf 'Release macOS image provisioning complete\n'
