#!/usr/bin/env bash
set -uo pipefail

max=2
running=0

trap 'jobs -pr | xargs -r kill 2>/dev/null || true' EXIT INT TERM

run() {
  local ver="$1"
  echo "Building $ver"
  local start=$SECONDS
  {
    docker run --rm -i -v "$PWD:/host/:rw,z" build_image /bin/bash /host/action_build_llvm.sh "$ver"
  } &>"$ver.log"
  local rc=$?
  local dur=$((SECONDS - start))
  echo "$ver => $rc (${dur}s)"
  return "$rc"
}

builds=(

"llvm-3.0.2011-10-16Z.2723da1.x86_6"
"llvm-3.1.2012-04-22Z.4ea5fe0.x86_64"
"llvm-3.2.2012-11-16Z.ccb5be1.x86_64"
"llvm-3.3.2013-05-10Z.d5e1212.x86_64"
"llvm-3.4.2013-11-24Z.307b249.x86_64"
"llvm-3.5.2014-07-27Z.5b15c0f.x86_64"
"llvm-3.6.2015-01-17Z.155bbe3.x86_64"
"llvm-3.7.2015-07-18Z.12555f8.x86_64"
"llvm-3.8.2016-01-14Z.d1d2746.x86_64"
"llvm-3.9.2016-07-24Z.5bdc21f.x86_64"
"llvm-4.2017-01-15Z.4cd57bf.x86_64"
"llvm-5.2017-07-22Z.a2e23a8.x86_64"
"llvm-6.2018-01-04Z.9dd5a02.x86_64"
"llvm-7.2018-08-03Z.d08e938.x86_64"
"llvm-8.2019-01-18Z.e264dae.x86_64"
#"llvm-9.2019-07-19Z.1931d3c.x86_64"
#"llvm-10.2019-07-21Z.3d68ade.x86_64"
#"llvm-11.2020-01-19Z.a7818e6.x86_64"
#"llvm-12.2020-07-19Z.cf11050.x86_64"
#"llvm-13.2021-01-31Z.3203c96.x86_64"
#"llvm-14.2021-08-01Z.2b9b5bc.x86_64"
#"llvm-15.2022-02-06Z.6635c12.x86_64"
#"llvm-16.2021-09-14Z.be98d93.x86_64"
#"llvm-17.2023-01-29Z.fac00d1.x86_64"
#"llvm-18.2023-07-30Z.09b6765.x86_64"
#"llvm-19.2024-01-28Z.c34aa78.x86_64"
#"llvm-20.2024-07-28Z.ea7cc12.x86_64"
#"llvm-21.2025-02-02Z.115bb87.x86_64"
#"llvm-22.2025-07-20Z.bdbc098.x86_64"
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
