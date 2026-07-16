#!/bin/sh
set -eu

manifest=${1:?usage: transfer-images.sh MANIFEST SSH_DEST SSH_PORT [SUDO]}
destination=${2:?usage: transfer-images.sh MANIFEST SSH_DEST SSH_PORT [SUDO]}
port=${3:?usage: transfer-images.sh MANIFEST SSH_DEST SSH_PORT [SUDO]}
remote_sudo=${4:-}
archive=$(mktemp)
tags=$(mktemp)
cleanup() { rm -f "$archive" "$tags"; }
trap cleanup EXIT INT TERM

test -s "$manifest"

while IFS='|' read -r source target; do
  [ -n "$source" ] || continue
  if ssh -n -p "$port" "$destination" "$remote_sudo docker image inspect '$target' >/dev/null 2>&1"; then
    continue
  fi
  docker pull "$source"
  if [ "$source" != "$target" ]; then
    docker tag "$source" "$target"
  fi
  printf '%s\n' "$target" >> "$tags"
done < "$manifest"

if [ -s "$tags" ]; then
  xargs docker save < "$tags" | gzip -1 > "$archive"
  ssh -p "$port" "$destination" "$remote_sudo sh -c 'gunzip | docker load'" < "$archive"
fi
