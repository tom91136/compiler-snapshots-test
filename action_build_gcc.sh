#!/usr/bin/env bash

set -eu

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

  dest_dir="/tmp/$build"
  dest_archive="/host/$build.tar.xz"

  hash=$(jq -r ".\"$build\" | .hash" "/host/builds.json")

  # Commits before d5ca27efb4b69f8fdf38240ad62cc1af30a30f77 requires an old glibc for asan to work
  # See https://gcc.gnu.org/bugzilla/show_bug.cgi?id=113181
  SAN_FIX=d5ca27efb4b69f8fdf38240ad62cc1af30a30f77

  echo "Build   : $build"
  echo "Commit  : $hash"

  git -c protocol.version=2 fetch \
    --quiet \
    --no-tags \
    --prune \
    --progress \
    --no-recurse-submodules \
    --filter=blob:none \
    origin "$hash" "$SAN_FIX"

  git checkout -q "$hash"

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
    echo "$build" >"$dest_dir/data.txt"
  else

    pwd
    ls -lah

    rm -rf build
    mkdir -p build

    time ./contrib/download_prerequisites --no-isl --no-verify
    (
      cd build
      ../configure \
        CFLAGS=-Wno-error=incompatible-pointer-types \
        --prefix="/opt/$build" \
        --enable-languages=c,c++,fortran \
        --disable-bootstrap \
        --disable-multilib \
        --disable-libvtv \
        --without-isl \
        $extra
    )
    time make -C build -j "$(nproc)"
    time make -C build -j "$(nproc)" install DESTDIR="$dest_dir"

  fi

  XZ_OPT='-T0 -2' tar cfJ "$dest_archive" --checkpoint=.1000 --totals -C "$dest_dir" .
  # zip -r "$dest_archive" "$dest_dir"

  du -sh "$dest_dir"
  du -sh "$dest_archive"

done
