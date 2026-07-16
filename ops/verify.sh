#!/bin/sh
set -eu

host=${1:?usage: verify.sh HOST CONFIG_DIRECTORY}
config=${2:?usage: verify.sh HOST CONFIG_DIRECTORY}
env_file="/srv/homelab/env/$host.env"
compose="$config/compose.yaml"

running=$(docker compose --env-file "$env_file" -f "$compose" ps --services --status running | wc -l)
total=$(docker compose --env-file "$env_file" -f "$compose" config --services | wc -l)
test "$running" -eq "$total"

if docker compose --env-file "$env_file" -f "$compose" config --services | grep -qx caddy; then
  docker compose --env-file "$env_file" -f "$compose" exec -T caddy \
    caddy validate --config /etc/caddy/Caddyfile
  docker compose --env-file "$env_file" -f "$compose" exec -T caddy \
    wget -q -O /dev/null http://127.0.0.1:2019/config/
fi
