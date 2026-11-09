#!/usr/bin/env bash
# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Run only on an unregistered image-builder guest immediately before stopping it.
set -euo pipefail
[[ $EUID -eq 0 ]] || exit 1
test -f /usr/local/share/toolchain-release/image.json
test ! -e /opt/actions-runner/.runner
test ! -e /opt/actions-runner/.credentials
test ! -d /opt/actions-runner/_work
systemctl stop docker
rm -f /etc/ssh/ssh_host_*
find /root /home -type f \( -name .bash_history -o -name authorized_keys \) -delete
cloud-init clean --logs --machine-id --seed
sync
