#!/usr/bin/env bash
set -euo pipefail

compiler="${1:?Compiler variant, gcc|llvm}"
N="${2:?Number of groups/jobs}"

host_arch="$(uname -m)"
matrix="matrix-$compiler-$host_arch.json"
[[ -s "$matrix" ]] || { echo "Matrix $matrix not found or empty" && exit 1; }

mkdir -p build

readarray -t groups < <(
  jq -c --argjson N "$N" '
    (map(split(";")) | flatten) as $a
    | ($a|length) as $len
    | ( (($len + $N - 1) / $N) | floor ) as $sz
    | if $len == 0 then [] else
        [ range(0; $len; $sz) | $a[ . : (. + $sz) ] ]
      end
    | .[]
  ' "$matrix"
)

chunks=()
for i in "${!groups[@]}"; do
  f="build/chunk_$(printf '%02d' "$i").json"
  printf '%s\n' "${groups[$i]}" >"$f"
  if [ "$(jq 'length' "$f")" -gt 0 ]; then
    chunks+=("$f")
  fi
done

if ((${#chunks[@]} == 0)); then
  echo "No jobs" && exit 0
fi

build_one() {
  set -euo pipefail
  local json="$1"
  ./local_make_builds.sh "$json" 2>&1 | tee "${json%.json}.log"
}
export -f build_one

SHELL="$(command -v bash)" parallel \
  --no-notice --line-buffer \
  --joblog "build/parallel.log" \
  -j "$N" --noswap --memfree 20% \
  build_one ::: "${chunks[@]}"

echo "Done"
