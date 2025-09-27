#!/usr/bin/env bash
set -uo pipefail

max=8
running=0

trap 'jobs -pr | xargs -r kill 2>/dev/null || true' EXIT INT TERM

run() {
  local ver="$1"
  echo "Building $ver"
  local start=$SECONDS
  {
    docker run --rm -i -v "$PWD:/host/:rw,z" build_image /bin/bash /host/action_build_gcc.sh "$ver"
  } &>"$ver.log"
  local rc=$?
  local dur=$((SECONDS - start))
  echo "$ver => $rc (${dur}s)"
  return "$rc"
}

builds=(
  "gcc-4.0.2005-03-13Z.774b0ae.x86_64"
  "gcc-4.1.2005-12-11Z.3f06c7d.x86_64"
  "gcc-4.2.2006-10-29Z.8ea18b7.x86_64"
  "gcc-4.3.2008-03-09Z.19699f8.x86_64"
  "gcc-4.4.2009-04-19Z.191e54a.x86_64"
  "gcc-4.5.2010-04-18Z.ec7ba7e.x86_64"
  "gcc-4.6.2011-03-27Z.113c612.x86_64"
  "gcc-4.7.2012-03-11Z.a9dd952.x86_64"
  "gcc-4.8.2013-03-24Z.e634906.x86_64"
  "gcc-4.9.2014-04-20Z.53b3c3d.x86_64"
  "gcc-5.2015-04-12Z.096f5cf.x86_64"
  "gcc-6.2016-04-17Z.9f585d9.x86_64"
  "gcc-7.2017-05-21Z.9165dfb.x86_64"
  "gcc-8.2018-05-06Z.7b7a3fd.x86_64"
  "gcc-9.2019-05-19Z.324470d.x86_64"
  "gcc-10.2020-05-24Z.217a224.x86_64"
  "gcc-11.2021-05-23Z.9ee61d2.x86_64"
  "gcc-12.2022-05-15Z.0556c35.x86_64"
  "gcc-13.2023-05-07Z.fc79c3a.x86_64"
  "gcc-14.2024-05-26Z.2e0f832.x86_64"
)

for v in "${builds[@]}"; do
  run "$v" &
  ((running++))
  if ((running >= max)); then
    wait -n
    ((running--))
  fi
done

wait

echo "Done"
