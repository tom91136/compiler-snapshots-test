#!/usr/bin/env bash

set -eu

set +u # scl_source has unbound vars, disable check
source scl_source enable gcc-toolset-14 || true
set -u

BUILDS=$1

dry=false

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
      cmake_ver="3.16.4"
      cmake_major="v3.16"
      workdir="$PWD"
      src_tar="$workdir/cmake-${cmake_ver}.tar.gz"
      src_dir="$workdir/cmake-${cmake_ver}"
      prefix="$workdir/cmake-${cmake_ver}-local"

      if [ ! -x "$prefix/bin/cmake" ]; then
        dnf install openssl-devel -y

        curl -L "https://cmake.org/files/${cmake_major}/cmake-${cmake_ver}.tar.gz" -o "$src_tar"
        tar xf "$src_tar" -C "$workdir"
        cd "$src_dir"
        ./bootstrap --prefix="$prefix"
        make -j "$(nproc)"
        make install
        cd "$workdir"
        rm -rf "$src_dir" "$src_tar"
      fi
      cmake3() { "$prefix/bin/cmake" "$@"; }
      cmake3 --version
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

    {

    # compiler-rt implements atomic which openmp needs
    time CXXFLAGS="-include cstdint -include cstdlib -include string -include cstdio -Wno-template-id-cdtor -Wno-missing-template-keyword -Wno-attributes" \
      cmake3 -S llvm -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLVM_ENABLE_ASSERTIONS=ON \
      -DLLVM_LINK_LLVM_DYLIB=ON \
      -DLLVM_BUILD_LLVM_DYLIB=ON \
      -DLLVM_ENABLE_PROJECTS="clang;lld;openmp;pstl" \
      -DLLVM_TARGETS_TO_BUILD="X86;AArch64;NVPTX;AMDGPU" \
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

    } 2>&1 | tee -a "$dest_dir/opt/$build-$(uname -m)/build.log"

  fi

  XZ_OPT='-T0 -9e --block-size=16MiB' tar cfJ "$dest_archive" --checkpoint=.1000 --totals --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -C "$dest_dir" .

  du -sh "$dest_dir"
  du -sh "$dest_archive"

done
