#!/usr/bin/env bash
set -euo pipefail

matrix_json="$1"
host_arch="${HOST_ARCH:?host arch, required}"
cross="${CROSS:?cross compile, required}"
max_proc="${MAX_PROC:?max processors per build container, required}"

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

if [[ "$cross" == true ]]; then
  suffix="_cross"
  envs=(CROSS_ARCH="$host_arch" MAX_PROC="$max_proc")
  extra=(--security-opt label=disable --mount "type=bind,src=/proc/sys/fs/binfmt_misc,target=/proc/sys/fs/binfmt_misc,ro")
  echo "Cross compiling to $host_arch"
else
  suffix=""
  envs=(MAX_PROC="$max_proc")
  extra=()
fi

docker create --name "$container_name" --replace -v "$PWD:/host" \
  --tmpfs /tmp:rw,exec,nosuid,nodev,mode=1777 \
  --tmpfs /var/tmp:rw,exec,nosuid,nodev,mode=1777 \
  --tmpfs /ccache:rw,nosuid,nodev,mode=0777 \
  -e CCACHE_DIR=/ccache \
  --cpus="$max_proc" \
  "${extra[@]}" \
  "build_image$suffix:latest" \
  sleep infinity

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
  elif docker exec "${envs[@]/#/-e}" -w "/host" "$container_name" timeout 4h "/host/action_build_$job_compiler$suffix.sh" "$job" &>"logs_$job_compiler/$job.log"; then
    echo "✅ \`$job (build,   $(fmt_time "$SECONDS"))\`"
  else
    echo "❌ \`$job (build,   $(fmt_time "$SECONDS"))\`"
  fi
done

echo "Done"
