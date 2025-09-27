#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


#/host/action_build_gcc.sh gcc-4.4.2009-04-19Z.191e54a.x86_64
#/host/action_build_gcc.sh gcc-4.5.2010-04-18Z.ec7ba7e.x86_64
/host/action_build_gcc.sh gcc-4.6.2011-03-27Z.113c612.x86_64
/host/action_build_gcc.sh gcc-4.7.2012-03-11Z.a9dd952.x86_64
/host/action_build_gcc.sh gcc-4.8.2013-03-24Z.e634906.x86_64
#/host/action_build_gcc.sh gcc-4.9.2014-04-20Z.53b3c3d.x86_64








#file="$script_dir/all-gcc-$(uname -m).json"
#
#jq -r '.[]' "$file" | while read -r item; do
#  if [[ $item =~ ^gcc-([0-9]+)\.([0-9]+) ]]; then
#    major="${BASH_REMATCH[1]}"
#    minor="${BASH_REMATCH[2]}"
#    if ((major < 4 || (major == 4 && minor < 4))); then continue; fi
#    if ((major >= 5)); then echo "Reached gcc-$major.$minor, stopping." && break; fi
#    echo -n "Building $item ... "
#    SECONDS=0
#    set +e
#    /host/action_build_gcc.sh "$item" &>"/host/$item.log"
#    rc=$?
#    elapsed=$SECONDS
#    set -e
#    echo " rc=$rc ($elapsed s)"
#  fi
#done

#/host/action_build_gcc.sh gcc-5.2015-04-12Z.096f5cf.x86_64
#/host/action_build_gcc.sh gcc-6.2016-04-17Z.9f585d9.x86_64
#/host/action_build_gcc.sh gcc-7.2017-05-21Z.9165dfb.x86_64
#/host/action_build_gcc.sh gcc-8.2018-05-06Z.7b7a3fd.x86_64
#/host/action_build_gcc.sh gcc-9.2019-05-19Z.324470d.x86_64
#/host/action_build_gcc.sh gcc-10.2020-05-24Z.217a224.x86_64
#/host/action_build_gcc.sh gcc-11.2021-05-23Z.9ee61d2.x86_64
#/host/action_build_gcc.sh gcc-12.2022-05-15Z.0556c35.x86_64
#/host/action_build_gcc.sh gcc-13.2023-05-07Z.fc79c3a.x86_64
#/host/action_build_gcc.sh gcc-14.2024-05-26Z.2e0f832.x86_64
