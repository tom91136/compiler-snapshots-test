#!/usr/bin/env bash

set -eu

TOKEN=$1
BUILDS=$2

# shellcheck disable=SC2206
builds_array=(${BUILDS//;/ }) # split by ws

echo "Token=$TOKEN"

for build in "${builds_array[@]}"; do
  build="$build-$(uname -m)"
  echo "Creating release: $build"

  build_artefact="$build.tar.xz"
  file "$build_artefact"
  ls -lah "$build_artefact"

  # make sure it's quoted, so no `-r`
  quotedChanges=$(jq "[ .\"$build\" | .changes | .[] | \"[\`\(.[0])\`] \`\(.[1]/1000 | todateiso8601)\` \(.[2])\"] | join(\"\n\")" builds.json)

  echo "Build  : $build"
  echo "Changes: $quotedChanges"

  release_config=$(
    cat <<-END
{
  "tag_name": "$build",
  "name": "$build",
  "body": $quotedChanges,
  "draft": false,
  "prerelease": false,
  "generate_release_notes": false
}
END
  )

  echo "Using release config: $release_config"

  release_json=$(curl \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $TOKEN" \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/releases" \
    -d "$release_config")

  release_id=$(echo "$release_json" | jq .id)
  if [ "$release_id" == "null" ]; then
    echo "Bad response:"
    echo "$release_json"
    echo "Cannot resolve release id, aborting..."
    exit 2
  fi

  echo "Release created; $release_json"
  echo "Release id: $release_id"

  curl -X POST \
    -H "Content-Type: $(file -b --mime-type "$build_artefact")" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Authorization: Bearer $TOKEN" \
    -T "$build_artefact" \
    "https://uploads.github.com/repos/$GITHUB_REPOSITORY/releases/$release_id/assets?name=$build_artefact" | cat

  echo "Release uploaded"

done
