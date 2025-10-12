#!/usr/bin/env bash
set -euo pipefail

matrix_json="$1"
host_arch="$(uname -m)"

name="${matrix_json%.*}" && name="${name//\//_}"
container_name="build_persistent_$name"

mapfile -t matrix < <(jq -er '.[]' "$matrix_json")
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

for job in "${jobs[@]}"; do
  [[ -z "$job" ]] && continue
  job_compiler="${job%%-*}"
  job_arch="${job##*.}"
  if [[ "$job_arch" != "$host_arch" ]]; then
    echo "Skipping $job (arch mismatch: host=$host_arch, job=$job_arch)" && continue
  fi

  mkdir -p "logs_$job_compiler"

  SECONDS=0
  if [[ -f "$job.squashfs" ]]; then
    echo "✅ \`$job (skip,    $(fmt_time "$SECONDS"))\`"
  elif docker exec -w "/host" "$container_name" timeout 4h "/host/action_build_$job_compiler.sh" "$job" &>"logs_$job_compiler/$job.log"; then
    echo "✅ \`$job (build,   $(fmt_time "$SECONDS"))\`"
  else
    echo "❌ \`$job (build,   $(fmt_time "$SECONDS"))\`"
  fi
done

echo "Done"
