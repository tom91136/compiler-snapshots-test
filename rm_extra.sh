#!/usr/bin/env bash
set -euo pipefail

PARALLEL=${PARALLEL:-8}
MAX_RELEASES=${MAX_RELEASES:-32768}

declare -A keep=()
for f in "$@"; do
  echo "Reading: $f"
  while IFS= read -r tag; do [[ -n "$tag" ]] && keep["$tag"]=1; done < <(jq -r '.[] | strings' "$f")
done
echo "Total tags to keep: ${#keep[@]}"

echo "Enumerating releases..."
mapfile -t release_tags < <(gh release list --limit "$MAX_RELEASES" --json tagName \
  --template '{{range .}}{{.tagName}}{{"\n"}}{{end}}' | sed '/^$/d')

echo "Commits not in keep list:"
declare -a releases_to_delete=()
for t in "${release_tags[@]:-}"; do
  if [[ -z "${keep[$t]+x}" ]]; then
    releases_to_delete+=("$t")
    echo " - $t"
  fi
done

read -r -p "Found ${#releases_to_delete[@]} extra releases, delete? (parallel=${PARALLEL}) [y/N] " ans
case "${ans}" in
y | Y | yes | YES) ;;
*)
  echo "Aborted." && exit 1
  ;;
esac

if ((${#releases_to_delete[@]})); then
  printf '%s\0' "${releases_to_delete[@]}" | xargs -0 -n1 -P"${PARALLEL}" -I{} gh release delete -y '{}' --cleanup-tag
fi

echo "Enumerating tags..."
mapfile -t all_tags < <(gh api "repos/:owner/:repo/git/matching-refs/tags" |
  jq -r '.[].ref' | sed -e 's#^refs/tags/##' -e '/^$/d' | sort -u)

echo "Tags not in keep list:"
declare -a tags_to_delete=()
for t in "${all_tags[@]:-}"; do
  if [[ -z "${keep[$t]+x}" ]]; then
    tags_to_delete+=("$t")
    echo " - $t"
  fi
done

read -r -p "Found ${#tags_to_delete[@]} extra releases, delete? (parallel=${PARALLEL}) [y/N] " ans
case "${ans}" in
y | Y | yes | YES) ;;
*)
  echo "Aborted." && exit 1
  ;;
esac

if ((${#tags_to_delete[@]})); then
  printf '%s\0' "${tags_to_delete[@]}" | xargs -0 -n1 -P"${PARALLEL}" -I{} gh api -X DELETE "repos/:owner/:repo/git/refs/tags/{}"
fi

echo "Done."
