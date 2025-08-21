#!/usr/bin/env bash

set -eu

token="$GITHUB_TOKEN"
repo="$GITHUB_REPOSITORY"
prefix="*" # llvm-* | gcc-*

if ! command -v jq &>/dev/null; then
  echo "jq is required to delete releases"
  exit 1
fi

if ! command -v curl &>/dev/null; then
  echo "curl is required to delete releases"
  exit 1
fi

tags=$(git tag -l "$prefix")
# shellcheck disable=SC2086
git push -d origin $tags
# shellcheck disable=SC2046
git tag -d $(git tag -l "$prefix")

for tag in "${tags[@]}"; do
  id=$(curl -s \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $token" \
    "https://api.github.com/repos/$repo/releases/tags/$tag" | jq .id)

  echo "$tag => $id"
  curl \
    -X DELETE \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $token" \
    "https://api.github.com/repos/$repo/releases/$id" &

done

echo "Deleted ${#tags[@]} entries"
