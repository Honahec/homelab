#!/bin/sh
set -eu

host=${1:?usage: preflight.sh HOST CONFIG_DIRECTORY}
config=${2:?usage: preflight.sh HOST CONFIG_DIRECTORY}
mode=${3:-full}
env_file="/srv/homelab/env/$host.env"

test -f "$config/compose.yaml"
test -f "$config/Caddyfile"
missing=0
if [ ! -f "$env_file" ]; then
  echo "missing environment file: $env_file" >&2
  missing=1
elif [ "$(stat -c %a "$env_file")" != 600 ]; then
  echo "environment file must have mode 600: $env_file" >&2
  missing=1
fi

while IFS= read -r app_env; do
  [ -n "$app_env" ] || continue
  if [ ! -f "$app_env" ]; then
    echo "missing environment file: $app_env" >&2
    missing=1
  elif [ "$(stat -c %a "$app_env")" != 600 ]; then
    echo "environment file must have mode 600: $app_env" >&2
    missing=1
  fi
done <<EOF
$(sed -n 's|^[[:space:]]*- path: \(/srv/homelab/env/[^[:space:]]*\.env\)$|\1|p' \
  "$config/compose.yaml" | sort -u)
EOF

[ "$missing" -eq 0 ] || exit 10
[ "$mode" = env-only ] && exit 0

docker compose version >/dev/null
docker compose --env-file "$env_file" -f "$config/compose.yaml" config --quiet

available_kb=$(df -Pk / | awk 'NR == 2 {print $4}')
test "$available_kb" -ge 4194304
