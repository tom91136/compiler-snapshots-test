#!/usr/bin/env bash

set -eu

set +u # scl_source has unbound vars, disable check
source scl_source enable gcc-toolset-14 || true
set -u

BUILDS=$1

dry=true

# shellcheck disable=SC2206
builds_array=(${BUILDS//;/ }) # split by ws

git init llvm
cd llvm
git remote add origin https://github.com/llvm/llvm-project.git
git config --local gc.auto 0

for build in "${builds_array[@]}"; do
  dest_dir="/tmp/$build-$(uname -m)"
  dest_archive="/host/$build-$(uname -m).tar.xz"

  hash=$(jq -r ".\"$build\" | .hash" "/host/builds.json")

  # Commits before https://github.com/llvm/llvm-project/commit/7f5fe30a150e will only work with
  # CMake < 3.17 due to a bug in LLVM's ExternalProjectAdd.
  TGT_FIX=7f5fe30a150e7e87d3fbe4da4ab0e76ec38b40b9

  echo "Build   : $build-$(uname -m)"
  echo "Commit  : $hash"

  git -c protocol.version=2 fetch \
    --quiet \
    --no-tags \
    --prune \
    --progress \
    --no-recurse-submodules \
    --filter=blob:none \
    origin "$hash" "$TGT_FIX"

  git checkout -q "$hash"


  has_tgt_fix=0
  if git merge-base --is-ancestor "$TGT_FIX" "$hash"; then
    has_tgt_fix=0
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      has_tgt_fix=1
    else
      echo "Unable to determine ancestry (git merge-base failed with code $rc); assuming fix present."
      has_tgt_fix=0
    fi
  fi

  if [ "$has_tgt_fix" -ne 0 ]; then
    echo "Commit requires CMake < 3.17, downloading that now..."
    curl -L "https://github.com/Kitware/CMake/releases/download/v3.16.4/cmake-3.16.4-Linux-x86_64.sh" -o "cmake-install.sh"
    chmod +x "./cmake-install.sh"
    "./cmake-install.sh" --skip-license --include-subdir
    rm -rf "./cmake-install.sh"
    cmake3() { "$PWD/cmake-3.16.4-Linux-x86_64/bin/cmake" "$@"; }
  else
    echo "Commit does not require CMake < 3.17, continuing..."
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

    # compiler-rt implements atomic which openmp needs
    time CXXFLAGS="-include cstdint -include cstdlib -include string -include cstdio -Wno-template-id-cdtor -Wno-missing-template-keyword -Wno-attributes" \
      cmake3 -S llvm -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DLLVM_ENABLE_PROJECTS="clang;lld;openmp;pstl" \
      -DLLVM_ENABLE_RTTI=ON \
      -DLLVM_INCLUDE_BENCHMARKS=OFF \
      -DLLVM_INCLUDE_TESTS=OFF \
      -DLLVM_INCLUDE_DOCS=OFF \
      -DLLVM_INCLUDE_EXAMPLES=OFF \
      -DLLVM_BUILD_TESTS=OFF \
      -DLLVM_BUILD_DOCS=OFF \
      -DLLVM_BUILD_EXAMPLES=OFF \
      -DLLVM_STATIC_LINK_CXX_STDLIB=ON \
      -DLIBOMP_USE_QUAD_PRECISION=OFF \
      -DCMAKE_INSTALL_PREFIX="$dest_dir/opt/$build-$(uname -m)" \
      -GNinja

    time cmake3 --build build # Ninja is parallel by default
    time cmake3 --build build --target install

  fi

  XZ_OPT='-T0 -2' tar cfJ "$dest_archive" --checkpoint=.1000 --totals -C "$dest_dir" .
  # zip -r "$dest_archive" "$dest_dir"

  du -sh "$dest_dir"
  du -sh "$dest_archive"

done
