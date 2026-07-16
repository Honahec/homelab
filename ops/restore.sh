#!/bin/sh
set -eu

host=${1:?usage: restore.sh HOST CONFIG_DIRECTORY DATABASE DUMP [DATABASE_USER]}
config=${2:?usage: restore.sh HOST CONFIG_DIRECTORY DATABASE DUMP [DATABASE_USER]}
database=${3:?usage: restore.sh HOST CONFIG_DIRECTORY DATABASE DUMP [DATABASE_USER]}
dump=${4:?usage: restore.sh HOST CONFIG_DIRECTORY DATABASE DUMP [DATABASE_USER]}
database_user=${5:-postgres}
compose="$config/compose.yaml"
env_file="/srv/homelab/env/$host.env"
temporary="restore_${database}_$(date +%s)"

test -s "$dump"
docker compose --env-file "$env_file" -f "$compose" exec -T postgres \
  createdb -U "$database_user" "$temporary"
cleanup() {
  docker compose --env-file "$env_file" -f "$compose" exec -T postgres \
    dropdb -U "$database_user" --if-exists --force "$temporary" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
docker compose --env-file "$env_file" -f "$compose" exec -T postgres \
  pg_restore -U "$database_user" -d "$temporary" --no-owner --no-acl < "$dump"
docker compose --env-file "$env_file" -f "$compose" exec -T postgres \
  psql -U "$database_user" -d "$temporary" -Atqc \
    "select count(*) from pg_tables where schemaname = 'public'"
printf '%s\n' "Restore verified in temporary database: $temporary"
