#!/bin/sh
set -eu

host=${1:?usage: cleanup-images.sh HOST CONFIG_DIRECTORY}
config=${2:?usage: cleanup-images.sh HOST CONFIG_DIRECTORY}
root=${HOMELAB_ROOT:-/srv/homelab}
docker=${DOCKER:-docker}
current_manifest="$config/images.txt"
desired=$(mktemp)
historical=$(mktemp)
cleanup() { rm -f "$desired" "$historical"; }
trap cleanup EXIT INT TERM

test -f "$current_manifest"

awk -F '|' 'NF >= 2 && $2 != "" {print $2}' "$current_manifest" | sort -u > "$desired"

for manifest in "$root"/releases/*/"$host"/images.txt; do
  [ -f "$manifest" ] || continue
  awk -F '|' 'NF >= 2 && $2 != "" {print $2}' "$manifest" >> "$historical"
done
sort -u -o "$historical" "$historical"

while IFS= read -r image || [ -n "$image" ]; do
  [ -n "$image" ] || continue
  grep -Fqx "$image" "$desired" && continue
  "$docker" image inspect "$image" >/dev/null 2>&1 || continue
  if "$docker" image rm "$image" >/dev/null 2>&1; then
    printf 'removed stale image: %s\n' "$image"
  else
    printf 'kept image still in use: %s\n' "$image" >&2
  fi
done < "$historical"

"$docker" image prune -f >/dev/null
