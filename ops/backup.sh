#!/bin/sh
set -eu

host=${1:?usage: backup.sh HOST CONFIG_DIRECTORY DATABASE [DATABASE_USER]}
config=${2:?usage: backup.sh HOST CONFIG_DIRECTORY DATABASE [DATABASE_USER]}
database=${3:?usage: backup.sh HOST CONFIG_DIRECTORY DATABASE [DATABASE_USER]}
database_user=${4:-postgres}
compose="$config/compose.yaml"
env_file="/srv/homelab/env/$host.env"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
dest="/srv/homelab/backups/database/$stamp"

install -d -m 700 "$dest"
docker compose --env-file "$env_file" -f "$compose" exec -T postgres \
  pg_dump -U "$database_user" -Fc --no-owner --no-acl "$database" > "$dest/$database.dump"
(cd "$dest" && sha256sum ./*.dump > SHA256SUMS)
chmod 600 "$dest"/*
printf '%s\n' "$dest"
