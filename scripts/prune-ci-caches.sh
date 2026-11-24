#!/usr/bin/env bash
# Copyright the Elide Toolchain contributors.
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Prune stale pull-request cache scopes on a persistent self-hosted runner.
# Usage: scripts/prune-ci-caches.sh CACHE_ROOT CURRENT_SCOPE
#
# job.build.yml keeps ccache and downloads in CACHE_ROOT/<scope>/<os>-<arch>, with one
# review-<PR> scope per pull request and a 50G ccache cap each. Nothing removed them, so
# every PR that built on a runner left up to ~50G there for good, and the linux-amd64
# runners ran out of disk mid-build. This removes other review-* scopes that have been idle
# for PRUNE_REVIEW_IDLE_MINUTES (default one day); when free space is still below
# PRUNE_MIN_FREE_GB (default 150) it also removes those idle for PRUNE_BUSY_MINUTES (default
# three hours, longer than a build, so a scope another job may still be using is kept).
# The main and release scopes and the current scope are never touched. It then stamps the
# current scope as used.
#
# Must stay bash 3.2-safe: macOS runners call it too.
set -euo pipefail

root="${1:?usage: prune-ci-caches.sh CACHE_ROOT CURRENT_SCOPE}"
current="${2:?usage: prune-ci-caches.sh CACHE_ROOT CURRENT_SCOPE}"
idle_minutes="${PRUNE_REVIEW_IDLE_MINUTES:-1440}"
busy_minutes="${PRUNE_BUSY_MINUTES:-180}"
min_free_gb="${PRUNE_MIN_FREE_GB:-150}"
stamp_name=".last-used"

mkdir -p "$root"

free_gb() { df -Pk "$root" | awk 'NR == 2 { printf "%d\n", $4 / 1048576 }'; }

# used_within DIR MINUTES — the scope's stamp, or any file in a scope from before stamps
# existed, changed within MINUTES.
used_within() {
  if [ -e "$1/$stamp_name" ]; then
    [ -z "$(find "$1/$stamp_name" -mmin +"$2" -print 2>/dev/null)" ]
  else
    [ -n "$(find "$1" -mmin -"$2" -print 2>/dev/null | head -n 1)" ]
  fi
}

# prune_idle MINUTES — remove other review scopes idle for longer than MINUTES.
prune_idle() {
  local d name
  for d in "$root"/review-*; do
    [ -d "$d" ] || continue
    name="${d##*/}"
    [ "$name" = "$current" ] && continue
    used_within "$d" "$1" && continue
    echo "prune-ci-caches: removing $name ($(du -sh "$d" 2>/dev/null | cut -f1), idle > ${1}m)"
    rm -rf "$d"
  done
}

echo "prune-ci-caches: ${root}: $(free_gb)G free before pruning"
prune_idle "$idle_minutes"
if [ "$(free_gb)" -lt "$min_free_gb" ]; then
  echo "prune-ci-caches: below ${min_free_gb}G free; removing review scopes idle > ${busy_minutes}m"
  prune_idle "$busy_minutes"
fi
mkdir -p "$root/$current"
touch "$root/$current/$stamp_name"

left="$(free_gb)"
echo "prune-ci-caches: ${left}G free after pruning"
if [ "$left" -lt "$min_free_gb" ]; then
  echo "::warning::only ${left}G free on this runner after pruning CI caches; a full build may run out of disk"
  du -sh "$root"/* 2>/dev/null | sort -h | tail -n 10 || true
fi
