#!/bin/sh
set -eu

host=${1:?usage: init-databases.sh HOST CONFIG_DIRECTORY}
config=${2:?usage: init-databases.sh HOST CONFIG_DIRECTORY}

read_env() {
  file=$1
  key=$2
  value=$(sed -n "s/^${key}=//p" "$file" | tail -n 1)
  case "$value" in
    \'*\') value=${value#\'}; value=${value%\'} ;;
    \"*\") value=${value#\"}; value=${value%\"} ;;
  esac
  test -n "$value"
  printf '%s' "$value"
}

compose="$config/compose.yaml"
host_env="/srv/homelab/env/$host.env"
manifest="$config/databases.txt"

test -f "$manifest"

if ! grep -Eq '^[A-Za-z0-9_-]+$' "$manifest"; then
  exit 0
fi

docker compose --env-file "$host_env" -f "$compose" up -d postgres --wait --wait-timeout 120
admin_user=$(docker compose --env-file "$host_env" -f "$compose" exec -T postgres \
  sh -c 'printf %s "${POSTGRES_USER:-postgres}"')

while IFS= read -r app || [ -n "$app" ]; do
  case "$app" in
    ''|'#'*) continue ;;
    *[!a-zA-Z0-9_-]*)
      echo "invalid application name in $manifest: $app" >&2
      exit 2
      ;;
  esac
  app_env="/srv/homelab/env/$app.env"
  database=$(read_env "$app_env" DB_NAME)
  username=$(read_env "$app_env" DB_USER)
  password=$(read_env "$app_env" DB_PASSWORD)
  case "$database" in
    *[!a-zA-Z0-9_-]*|[0-9]*)
      echo "invalid database name in $app_env" >&2
      exit 2
      ;;
  esac
  case "$username" in
    *[!a-zA-Z0-9_]*|[0-9]*)
      echo "invalid database role in $app_env" >&2
      exit 2
      ;;
  esac

  database_url=$(read_env "$app_env" DATABASE_URL)
  url_authority=${database_url#*://}
  url_user=${url_authority%%:*}
  url_path=${url_authority#*/}
  url_database=${url_path%%\?*}
  if [ "$url_user" != "$username" ] || [ "$url_database" != "$database" ]; then
    echo "database URL does not match DB_USER/DB_NAME in $app_env" >&2
    exit 2
  fi

  docker compose --env-file "$host_env" -f "$compose" exec -T postgres \
    psql -U "$admin_user" -d postgres -v ON_ERROR_STOP=1 \
      -v username="$username" -v password="$password" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'username', :'password')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'username') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'username', :'password') \gexec
SQL

  exists=$(docker compose --env-file "$host_env" -f "$compose" exec -T postgres \
    psql -U "$admin_user" -d postgres -v database="$database" -At <<'SQL'
SELECT 1 FROM pg_database WHERE datname = :'database';
SQL
  )
  if [ "$exists" != 1 ]; then
    docker compose --env-file "$host_env" -f "$compose" exec -T postgres \
      createdb -U "$admin_user" -O "$username" "$database"
  fi
done < "$manifest"
