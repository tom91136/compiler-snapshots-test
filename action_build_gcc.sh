#!/usr/bin/env bash

set -euo pipefail

set +u # scl_source has unbound vars, disable check
source scl_source enable gcc-toolset-14 || true
set -u

BUILDS=$1

dry=false

# shellcheck disable=SC2206
builds_array=(${BUILDS//;/ }) # split by ws

git init gcc
cd gcc
git remote add origin https://github.com/gcc-mirror/gcc.git
git config --local gc.auto 0

for build in "${builds_array[@]}"; do
  dest_dir="/tmp/$build-$(uname -m)"
  dest_archive="/host/$build-$(uname -m).tar.xz"

  hash=$(jq -r ".\"$build\" | .hash" "/host/builds.json")

  # Commits before d5ca27efb4b69f8fdf38240ad62cc1af30a30f77 requires an old glibc for asan to work
  # See https://gcc.gnu.org/bugzilla/show_bug.cgi?id=113181
  SAN_FIX=d5ca27efb4b69f8fdf38240ad62cc1af30a30f77

  echo "Build   : $build-$(uname -m)"
  echo "Commit  : $hash"

  git -c protocol.version=2 fetch \
    --quiet \
    --no-tags \
    --prune \
    --progress \
    --no-recurse-submodules \
    --filter=blob:none \
    origin "$hash" "$SAN_FIX"

  git checkout -f -q "$hash"
  git clean -fdx

  has_san_fix=0
  if git merge-base --is-ancestor "$SAN_FIX" "$hash"; then
    has_san_fix=0
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      has_san_fix=1
    else
      echo "Unable to determine ancestry (git merge-base failed with code $rc); assuming fix present."
      has_san_fix=0
    fi
  fi

  if [ "$has_san_fix" -ne 0 ]; then
    extra="--disable-libsanitizer"
  else
    echo "Commit does not require disabling support, continuing..."
    extra=""
  fi

  echo "Source cloned, starting build step..."

  if $dry; then
    echo "Dry run, creating dummy artefact..."
    mkdir -p "$dest_dir"
    echo "$build-$(uname -m)" >"$dest_dir/data.txt"
  else

    pwd
    ls -lah

    rm -rf build
    mkdir -p build

    install_dir="$dest_dir/opt/$build-$(uname -m)"
    mkdir -p "$install_dir"

    {

    time ./contrib/download_prerequisites --no-isl --no-verify
    (
      cd build
      ../configure \
        CFLAGS='-Wno-error=incompatible-pointer-types -Wno-maybe-uninitialized'\
        --prefix="/opt/$build-$(uname -m)" \
        --enable-languages=c,c++,fortran \
        --disable-bootstrap \
        --disable-multilib \
        --disable-libvtv \
        --without-isl \
        $extra
    )
    time make --silent -C build -j "$(nproc)"
    time make --silent -C build -j "$(nproc)" install DESTDIR="$dest_dir"

    } 2>&1 | tee "$install_dir/build.log"

  fi

  XZ_OPT='-T0 -9e --block-size=16MiB' tar cfJ "$dest_archive" --checkpoint=.1000 --totals --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -C "$dest_dir" .

  du -sh "$dest_dir"
  du -sh "$dest_archive"

done
