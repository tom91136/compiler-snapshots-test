#!/usr/bin/env bash
set -euo pipefail

PARALLEL=${PARALLEL:-8}
MAX_RELEASES=${MAX_RELEASES:-32768}

echo "Enumerating releases..."

mapfile -t TAGS < <(gh release list --limit "$MAX_RELEASES" --json tagName \
  --template '{{range .}}{{.tagName}}{{"\n"}}{{end}}')

COUNT=${#TAGS[@]}
if ((COUNT == 0)); then
  echo "No releases found."
  exit 0
fi

read -r -p "Found ${COUNT} releases, delete all? (parallel=${PARALLEL}) [y/N]" ans
case "${ans}" in
y | Y | yes | YES) ;;
*) echo "Aborted." && exit 1 ;;
esac

printf '%s\0' "${TAGS[@]}" | xargs -0 -n1 -P"${PARALLEL}" -I{} gh release delete -y '{}' --cleanup-tag

echo "Done."
