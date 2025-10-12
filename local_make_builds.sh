#!/usr/bin/env bash
set -euo pipefail

compiler="$1"
host_arch="$(uname -m)"
container_name="build_persistent"

mapfile -t matrix < <(jq -er '.[]' "matrix-$compiler-$host_arch.json")
jobs=()
for g in "${matrix[@]}"; do
  IFS=';' read -ra parts <<<"$g"
  jobs+=("${parts[@]}")
done

echo "Job count: ${#jobs[@]}"

fmt_time() { date -ud "@$1" +'%Hh%Mm%Ss'; }

docker create --name "$container_name" --replace -v "$PWD:/host" build_image:latest sleep infinity
docker start "$container_name" >/dev/null

cleanup() {
  docker rm -f "$container_name" >/dev/null 2>&1 || true
}

on_interrupt() {
  echo && echo "Interrupted" && exit 130
}

trap cleanup EXIT
trap on_interrupt INT TERM

mkdir -p logs
for job in "${jobs[@]}"; do
  [[ -z "$job" ]] && continue
  job_arch="${job##*.}"
  if [[ "$job_arch" != "$host_arch" ]]; then
    echo "Skipping $job (arch mismatch: host=$host_arch, job=$job_arch)" && continue
  fi

  SECONDS=0
  if [[ -f "$job.squashfs" ]]; then
    echo "✅ \`$job (skip,    $(fmt_time "$SECONDS"))\`"
  elif docker exec -w "/host" "$container_name" timeout 3h "/host/action_build_$compiler.sh" "$job" &>"logs/$job.log"; then
    echo "✅ \`$job (build,   $(fmt_time "$SECONDS"))\`"
  else
    echo "❌ \`$job (build,   $(fmt_time "$SECONDS"))\`"
  fi
done

echo "Done"
