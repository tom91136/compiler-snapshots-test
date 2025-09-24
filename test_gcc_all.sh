#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mapfile -t builds < <(jq -r '.[] | split(";")[]' "${script_dir}/matrix-gcc-$(uname -m).json")


start="gcc-5.2014-05-11Z.c862e3b.x86_64"
end="gcc-6.2016-01-24Z.1d10121.x86_64"

armed=false
for b in "${builds[@]}"; do
  if [[ $b == "$start" ]]; then armed=true; fi

  if $armed; then
    echo "Building $b"
    "./${script_dir}/action_build_gcc.sh" "$b"
  fi

  if [[ $b == "$end" ]]; then break; fi
done
