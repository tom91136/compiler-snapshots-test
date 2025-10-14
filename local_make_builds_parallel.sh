#!/usr/bin/env bash
set -euo pipefail

compiler="${1:?Compiler variant, gcc|llvm}"
N="${2:?Number of groups/jobs}"

host_arch="$(uname -m)"
matrix="matrix-$compiler-$host_arch.json"
[[ -s "$matrix" ]] || { echo "Matrix $matrix not found or empty" && exit 1; }

rm -rf "build_$compiler" && mkdir -p "build_$compiler"

mapfile -t ALL_JOBS < <(jq -r 'map(split(";")) | flatten | .[]' "$matrix")

pending=()
for job in "${ALL_JOBS[@]}"; do
  [[ -z "$job" ]] && continue
  [[ -f "$job.squashfs" ]] && echo "✅ \`$job (completed)\`" && continue
  # log file exists but no archive, so fail
  [[ -f "logs_${compiler}/${job}.log" ]] && echo "❌ \`$job (failed)\`" && continue
  pending+=("$job")
done

((${#pending[@]})) || { echo "No jobs" && exit 0; }

chunks=()
len=${#pending[@]}
sz=$(((len + N - 1) / N))
for ((i = 0, start = 0; start < len; i++, start += sz)); do
  f="build_$compiler/chunk_$(printf '%02d' "$i").json"
  seg=("${pending[@]:start:sz}")
  if ((${#seg[@]})); then
    printf '%s\0' "${seg[@]}" | jq -Rs 'split("\u0000")[:-1]' >"$f"
    chunks+=("$f")
  fi
done

((${#chunks[@]})) || { echo "No jobs" && exit 0; }

echo "Total jobs: $(jq -s 'map(length) | add // 0' "${chunks[@]}")"
echo "Total groups: ${#chunks[@]}"
for f in "${chunks[@]}"; do
  echo "  $(basename "$f"): $(jq 'length' "$f") jobs"
done

read -r -p "Continue? [y/N] " ans
case "$ans" in
y | Y) ;;
*) echo "Aborted." && exit 0 ;;
esac

build_one() {
  set -euo pipefail
  local json="$1"
  ./local_make_builds.sh "$json" 2>&1 | tee "${json%.json}.log"
}
export -f build_one

SHELL="$(command -v bash)" parallel \
  --no-notice --line-buffer \
  --joblog "build_$compiler/parallel.log" \
  -j "$N" --noswap --memfree 20% \
  build_one ::: "${chunks[@]}"

echo "Done"
