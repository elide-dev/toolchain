#!/usr/bin/env bash
# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Install a reviewed controller snapshot on a trusted Linux host, outside build guests.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
destination="$HOME/.local/share/toolchain-release-controller"
logs="$HOME/.local/state/toolchain-release"
units="$HOME/.config/systemd/user"
for tool in python3 gh gcloud ssh systemctl; do command -v "$tool" >/dev/null; done
gh auth status
gcloud auth print-access-token >/dev/null
mkdir -p "$destination/.github/scripts" "$destination/.github/release-runners" "$logs" "$units"
if systemctl --user is-active --quiet toolchain-release-controller.service; then
  echo 'Controller is already running; stop it after its guests finish before updating.' >&2
  exit 1
fi
for script in release-pool.py release-runner.py release-macos-runner.py; do
  install -m 0644 "$root/.github/scripts/$script" "$destination/.github/scripts/$script"
done
install -m 0644 "$root/.github/release-runners/pool.json" "$destination/.github/release-runners/pool.json"
cat > "$units/toolchain-release-controller.service" <<EOF
[Unit]
Description=Disposable toolchain release runner controller
StartLimitIntervalSec=1800
StartLimitBurst=3

[Service]
Type=simple
Environment="PATH=$PATH"
ExecStart=/usr/bin/python3 "%h/.local/share/toolchain-release-controller/.github/scripts/release-pool.py" --watch --logs "%h/.local/state/toolchain-release"
Restart=on-failure
RestartSec=60
TimeoutStopSec=300
# Let the supervisor signal workers and wait for their VM cleanup before killing the cgroup.
KillMode=mixed
UMask=0077

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now toolchain-release-controller.service
echo "Controller installed. Logs: journalctl --user -u toolchain-release-controller; $logs"
echo 'Enable user lingering on this controller host to keep the service alive after logout.'
