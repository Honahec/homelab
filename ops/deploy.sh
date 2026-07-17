#!/bin/sh
set -eu

host=${1:?usage: deploy.sh HOST REVISION CONFIG_DIRECTORY}
revision=${2:-origin/main}
config=${3:?usage: deploy.sh HOST REVISION CONFIG_DIRECTORY}
stack=/srv/homelab/stack
compose="$config/compose.yaml"
env_file="/srv/homelab/env/$host.env"

cd "$stack"
git fetch --prune origin
if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  backup_dir=/srv/homelab/backups/working-tree
  install -d -m 700 "$backup_dir"
  tar --exclude=.git -czf "$backup_dir/$host-$stamp.tgz" .
  chmod 600 "$backup_dir/$host-$stamp.tgz"
  git reset --hard HEAD
  git clean -fd
fi
git checkout --detach "$revision"
runtime="/srv/homelab/runtime/$host"
install -d -m 755 "$runtime"
if [ -f "$runtime/Caddyfile" ]; then
  cat "$config/Caddyfile" > "$runtime/Caddyfile"
  chmod 644 "$runtime/Caddyfile"
else
  install -m 644 "$config/Caddyfile" "$runtime/Caddyfile"
fi
ln -sfn "$config" /srv/homelab/candidate
"$stack/ops/preflight.sh" "$host" "$config"

"$stack/ops/init-databases.sh" "$host" "$config"

docker compose --env-file "$env_file" -f "$compose" up -d --pull never --remove-orphans --wait --wait-timeout 180
if docker compose --env-file "$env_file" -f "$compose" config --services | grep -qx caddy; then
  if ! docker compose --env-file "$env_file" -f "$compose" exec -T caddy \
    cmp -s /etc/caddy/Caddyfile - < "$runtime/Caddyfile"; then
    docker compose --env-file "$env_file" -f "$compose" up -d --pull never --no-deps --force-recreate caddy
  fi
  docker compose --env-file "$env_file" -f "$compose" exec -T caddy \
    caddy validate --config /etc/caddy/Caddyfile
  if ! docker compose --env-file "$env_file" -f "$compose" exec -T caddy \
    wget -q -O /dev/null http://127.0.0.1:2019/config/; then
    docker compose --env-file "$env_file" -f "$compose" up -d --pull never --no-deps --force-recreate caddy
  fi
  docker compose --env-file "$env_file" -f "$compose" exec -T caddy \
    caddy reload --address 127.0.0.1:2019 --config /etc/caddy/Caddyfile
fi
"$stack/ops/verify.sh" "$host" "$config"
"$stack/ops/cleanup-images.sh" "$host" "$config"
ln -sfn "$config" /srv/homelab/current
