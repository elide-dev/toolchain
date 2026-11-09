#!/usr/bin/env bash
# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Run once on a fresh Ubuntu image-builder VM, before registering any runner.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
[[ ! -e /opt/actions-runner ]] || { echo 'Refusing to reuse a runner image' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl git sudo jq file unzip zip xz-utils zstd \
  build-essential bison gawk python3 ninja-build cmake rsync clang lld llvm \
  ccache docker.io pkg-config
systemctl enable --now docker
useradd --create-home --shell /bin/bash ci-agent
usermod -aG docker ci-agent
printf 'ci-agent ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/toolchain-release
chmod 0440 /etc/sudoers.d/toolchain-release
visudo -cf /etc/sudoers.d/toolchain-release
case "$(uname -m)" in
  x86_64) arch=x64; digest=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40 ;;
  aarch64) arch=arm64; digest=670adb2f268fe21dcbb58b3db0e0aa9d5b3bddfe2c651481336e561ff86de945 ;;
  *) echo 'Unsupported image architecture' >&2; exit 1 ;;
esac
runner_version=2.338.2
archive=$(mktemp)
trap 'rm -f "$archive"' EXIT
curl --fail --location --retry 3 -o "$archive" \
  "https://github.com/actions/runner/releases/download/v$runner_version/actions-runner-linux-$arch-$runner_version.tar.gz"
printf '%s  %s\n' "$digest" "$archive" | sha256sum -c -
install -d -o ci-agent -g ci-agent /opt/actions-runner
tar -xzf "$archive" -C /opt/actions-runner
/opt/actions-runner/bin/installdependencies.sh
chown -R ci-agent:ci-agent /opt/actions-runner
install -d /usr/local/share/toolchain-release
dpkg-query -W -f='${Package}\t${Version}\n' > /usr/local/share/toolchain-release/packages.tsv
jq -n --arg runner "$runner_version" --arg digest "$digest" --arg arch "$arch" \
  '{schema:1,runner_version:$runner,runner_sha256:$digest,architecture:$arch,registered:false}' \
  > /usr/local/share/toolchain-release/image.json
# No registration, service credentials, build workspaces or shared caches enter this image.
test ! -e /opt/actions-runner/.credentials
test ! -e /opt/actions-runner/.runner
docker image ls --format '{{.ID}}' | wc -l
apt-get clean
printf 'Release image provisioning complete\n'
