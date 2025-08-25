#!/usr/bin/env bash

set -euo pipefail

TOKEN=$1
BUILDS=$2

# shellcheck disable=SC2206
builds_array=(${BUILDS//;/ }) # split by ws

arch=$(uname -m)

gh_api() {
  local method="$1" url="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -sS -X "$method" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $TOKEN" \
      "$url" -d "$data"
  else
    curl -sS -X "$method" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $TOKEN" \
      "$url"
  fi
}

for build in "${builds_array[@]}"; do
   
  build_base="$build"
  build="$build-$arch" 
  echo "Creating release: $build"

  build_artefact="$build.tar.xz"
  file "$build_artefact"
  ls -lah "$build_artefact"

  # make sure it's quoted, so no `-r`
  quotedChanges=$(jq "[ .\"$build_base\" | .changes | .[] | \"[\`\(.[0])\`] \`\(.[1]/1000 | todateiso8601)\` \(.[2])\"] | join(\"\n\")" builds.json)

  echo "Build  : $build"
  echo "Changes: $quotedChanges"

  release_config=$(
    cat <<-END
{
  "tag_name": "$build_base",
  "name": "$build_base",
  "body": $quotedChanges,
  "draft": false,
  "prerelease": false,
  "generate_release_notes": false
}
END
  )

  echo "Using release config: $release_config"


  get_release_json=$(gh_api GET "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/tags/$build_base" || true)
  release_id=$(echo "${get_release_json:-}" | jq -r '.id // empty')

  if [ -z "$release_id" ]; then
    release_json=$(gh_api POST "https://api.github.com/repos/$GITHUB_REPOSITORY/releases" "$release_config")
    release_id=$(echo "$release_json" | jq -r '.id // empty')

    if [ -z "$release_id" ]; then
      # Concurrent creation: if it already exists, fetch it now
      already_exists=$(echo "$release_json" | jq -r 'select(.errors)!=null and ([.errors[].code] | index("already_exists"))')
      if [ "$already_exists" = "true" ]; then
        get_release_json=$(gh_api GET "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/tags/$build_base" || true)
        release_id=$(echo "${get_release_json:-}" | jq -r '.id // empty')
      fi
    fi

    if [ -z "$release_id" ]; then
      echo "Bad response:"
      echo "$release_json"
      echo "Cannot resolve release id, aborting..."
      exit 2
    fi

    echo "Release created; $release_json"
  else
    echo "Release exists for tag '$build_base' (id=$release_id)"
  fi


  echo "Preparing to upload asset $build_artefact -> $release_id"

  # Delete first if the same one is there, GH doesn't overwrite
  assets_json=$(gh_api GET "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/$release_id/assets")
  existing_asset_id=$(echo "$assets_json" | jq -r ".[] | select(.name==\"$build_artefact\") | .id" | head -n1 || true)
  if [ -n "${existing_asset_id:-}" ]; then
    echo "Deleting existing asset '$build_artefact' (id=$existing_asset_id)"
    gh_api DELETE "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/assets/$existing_asset_id" >/dev/null
  fi

  curl -X POST \
    -H "Content-Type: $(file -b --mime-type "$build_artefact")" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Authorization: Bearer $TOKEN" \
    -T "$build_artefact" \
    "https://uploads.github.com/repos/$GITHUB_REPOSITORY/releases/$release_id/assets?name=$build_artefact" | cat

  echo ""
  echo "Release uploaded"

done
