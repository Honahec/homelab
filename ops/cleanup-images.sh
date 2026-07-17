#!/bin/sh
set -eu

host=${1:?usage: cleanup-images.sh HOST CONFIG_DIRECTORY}
config=${2:?usage: cleanup-images.sh HOST CONFIG_DIRECTORY}
root=${HOMELAB_ROOT:-/srv/homelab}
docker=${DOCKER:-docker}
current_manifest="$config/images.txt"
desired_ids=$(mktemp)
managed_repositories=$(mktemp)
candidate_ids=$(mktemp)
cleanup() { rm -f "$desired_ids" "$managed_repositories" "$candidate_ids"; }
trap cleanup EXIT INT TERM

test -f "$current_manifest"

while IFS='|' read -r _ target || [ -n "$target" ]; do
  [ -n "$target" ] || continue
  "$docker" image inspect --format '{{.Id}}' "$target"
done < "$current_manifest" | sort -u > "$desired_ids"

for manifest in "$root"/releases/*/"$host"/images.txt; do
  [ -f "$manifest" ] || continue
  while IFS='|' read -r source target || [ -n "$source$target" ]; do
    for image in "$source" "$target"; do
      [ -n "$image" ] || continue
      repository=${image%%@*}
      if [ "$repository" = "$image" ]; then
        last_component=${image##*/}
        case "$last_component" in
          *:*) repository=${image%:*} ;;
        esac
      fi
      printf '%s\n' "$repository"
    done
  done < "$manifest" >> "$managed_repositories"
done
sort -u -o "$managed_repositories" "$managed_repositories"

"$docker" image ls --format '{{.Repository}}|{{.ID}}' |
  while IFS='|' read -r repository image_id; do
    [ "$repository" != '<none>' ] || continue
    grep -Fqx "$repository" "$managed_repositories" || continue
    printf '%s\n' "$image_id"
  done | sort -u > "$candidate_ids"

while IFS= read -r image_id || [ -n "$image_id" ]; do
  [ -n "$image_id" ] || continue
  grep -Fqx "$image_id" "$desired_ids" && continue
  if "$docker" image rm "$image_id" >/dev/null 2>&1; then
    printf 'removed stale image: %s\n' "$image_id"
  else
    printf 'kept image still in use: %s\n' "$image_id" >&2
  fi
done < "$candidate_ids"

"$docker" image prune -f >/dev/null
