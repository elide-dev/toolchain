#!/usr/bin/env bash
# Verify every submodule's (staged) gitlink matches its *_REV pin in versions.env, and that no
# initialized checkout differs from its gitlink. Works on shallow clones.
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=versions.env
source "$ROOT_DIR/versions.env"

status=0
while read -r line; do
  flag="${line:0:1}"
  sha="$(echo "$line" | awk '{print $1}' | tr -d '+-U')"
  path="$(echo "$line" | awk '{print $2}')"
  gitlink="$(git -C "$ROOT_DIR" ls-files -s -- "$path" | awk '{print $2}')"   # staged gitlink
  var="$(echo "$path" | tr 'a-z-' 'A-Z_')_REV"
  want="${!var:-}"
  if [ -z "$want" ]; then
    echo "MISSING  $path: no $var in versions.env"; status=1
  elif [ "$gitlink" != "$want" ]; then
    echo "MISMATCH $path: gitlink $gitlink, versions.env $want"; status=1
  elif [ "$flag" = "+" ]; then
    echo "DIRTY    $path: checkout $sha differs from gitlink $gitlink"; status=1
  fi
done < <(git -C "$ROOT_DIR" submodule status | sed 's/^ //')
[ "$status" -eq 0 ] && echo "submodule pins OK"
exit "$status"
