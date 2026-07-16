#!/bin/sh
set -eu

output=${1:?usage: generate.sh OUTPUT_DIRECTORY}
root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cue=${CUE:-cue}
version=$($cue version | sed -n 's/^cue version //p' | head -n 1)

test "$version" = v0.17.0
test ! -e "$output"
install -d "$output"
$cue vet "$root/config"

for host in primary secondary; do
  out="$output/$host"
  install -d "$out"
  $cue export "$root/config" -e "outputs.$host.compose" --out text > "$out/compose.yaml"
  $cue export "$root/config" -e "outputs.$host.images" --out text > "$out/images.txt"
  $cue export "$root/config" -e "outputs.$host.databases" --out text > "$out/databases.txt"
  config_json="$out/config.json"
  $cue export "$root/config" -e "outputs.$host" --out json > "$config_json"
  jq -r '.hostEnv | to_entries[] | "\(.key)=\(.value)"' "$config_json" > "$out/.env.example"
  {
    printf '{\n\temail %s\n}\n\n' "$(jq -r '.caddy.email' "$config_json")"
    while IFS= read -r domain; do
      [ -n "$domain" ] || continue
      service=$(jq -r --arg domain "$domain" '.caddy.proxySites[$domain].service' "$config_json")
      port=$(jq -r --arg domain "$domain" '.caddy.proxySites[$domain].port' "$config_json")
      printf '%s {\n\treverse_proxy %s:%s\n}\n\n' "$domain" "$service" "$port"
    done <<EOF
$(jq -r '(.caddy.proxySites // {}) | keys[]?' "$config_json")
EOF
    while IFS= read -r domain; do
      [ -n "$domain" ] || continue
      printf '%s {\n' "$domain"
      jq -r --arg domain "$domain" '.caddy.routeSites[$domain].routes | to_entries[] | "\t@route\(.key) path \(.value.path)\n\thandle @route\(.key) {\n\t\treverse_proxy \(.value.upstream.service):\(.value.upstream.port)\n\t}"' "$config_json"
      status=$(jq -r --arg domain "$domain" '.caddy.routeSites[$domain].fallbackStatus' "$config_json")
      printf '\trespond %s\n}\n\n' "$status"
    done <<EOF
$(jq -r '(.caddy.routeSites // {}) | keys[]?' "$config_json")
EOF
  } > "$out/Caddyfile"

  for app in $($cue eval "$root/config" -e "outputs.$host.envExamples" --out json | jq -r 'keys[]'); do
    jq -r --arg app "$app" '.envExamples[$app] | to_entries[] | "\(.key)=\(.value)"' "$config_json" > "$out/$app.env.example"
  done
  rm -f "$config_json"
done
