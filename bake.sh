#!/bin/sh
# Prints the targets in BAKE_TARGETS, the JSON `executor bake --print` writes,
# as one JSON object of each target's name to the image it pushed, pinned by
# digest in the repository of its first destination. Needs crane and jq, as in
# the merge image.
set -euf

if [ -f /docker-config/config.json ]; then
  mkdir -p "$HOME/.docker"
  cp /docker-config/config.json "$HOME/.docker/config.json"
fi
if [ -n "${KANIKO_GHCR_IO_PASSWORD:-}" ]; then
  echo "$KANIKO_GHCR_IO_PASSWORD" | crane auth login ghcr.io -u "$KANIKO_GHCR_IO_USER" --password-stdin > /dev/null
fi

targets=$(printf '%s' "$BAKE_TARGETS" | jq -r '.target | to_entries[] | "\(.key) \(.value.destination[0])"')
images='{}'
while read -r target destination; do
  repo="${destination%@*}"
  case "${repo##*/}" in
    *:*) repo="${repo%:*}" ;;
  esac
  digest=$(crane digest "$destination")
  images=$(jq -cn --argjson images "$images" --arg target "$target" --arg image "$repo@$digest" '$images + {($target): $image}')
done <<EOF
$targets
EOF
echo "$images"
