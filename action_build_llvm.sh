#!/usr/bin/env bash

set -euo pipefail

set +u # scl_source has unbound vars, disable check
source scl_source enable gcc-toolset-14 || true
set -u

export PATH="/usr/lib64/ccache${PATH:+:${PATH}}"

ccache --set-config=sloppiness=locale,time_macros
ccache -M 10G
ccache -s

BUILDS=$1

dry=false

# shellcheck disable=SC2206
builds_array=(${BUILDS//;/ }) # split by ws

cmake_prefix="$PWD"

build_cmake(){
  local cmake_major=$1
  local cmake_ver=$2

  local prefix="$cmake_prefix/cmake-${cmake_ver}"
  local workdir="/tmp"
  local src_tar="$workdir/cmake-${cmake_ver}.tar.gz"
  local src_dir="$workdir/cmake-${cmake_ver}"
  
  if [ ! -x "$prefix/bin/cmake" ]; then
    # CMake needs openssl-devel, which is included in the build image
    curl -L "https://cmake.org/files/${cmake_major}/cmake-${cmake_ver}.tar.gz" -o "$src_tar"
    tar xf "$src_tar" -C "$workdir"
    (
      cd "$src_dir"
      cmake3 -S . -B build -DCMAKE_INSTALL_PREFIX="$prefix" -GNinja
      cmake3 --build build --target install
      rm -rf "$src_dir" "$src_tar"
    )
  fi

  eval "cmake3() { \"$prefix/bin/cmake\" \"\$@\"; }"
}

if [ ! -d llvm/.git ]; then
  rm -rf llvm
  git init llvm
fi
cd llvm
if git remote get-url origin &>/dev/null; then
  git remote set-url origin https://github.com/llvm/llvm-project.git
else
  git remote add origin https://github.com/llvm/llvm-project.git
fi
git config --local gc.auto 0

git_is_ancestor() {
  local base="$1"
  local hash="$2"

  if git merge-base --is-ancestor "$base" "$hash"; then return 1
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then return 0
    else
      echo "Unable to determine ancestry (git merge-base failed with code $rc); assuming fix present." >&2
      return 1
    fi
  fi
}

filter_cmake_list() {
  local input="$1"
  local template="$2"
  local result=()
  for x in ${input//;/ }; do
    local path="${template//%%/$x}"
    if [[ -f "$path" ]]; then
      result+=("$x")
    fi
  done

  (IFS=";"; echo "${result[*]}")
}

for build in "${builds_array[@]}"; do
  dest_dir="/tmp/$build"
  dest_archive="/host/$build.tar.xz"



  build_no_arch="${build%.*}"

  builds_json="/host/builds.json"
  [ -f "/host/builds-llvm.json" ] && builds_json="/host/builds-llvm.json"
  hash=$(jq -r ".\"$build_no_arch\" | .hash" "$builds_json")

  # Commits before https://github.com/llvm/llvm-project/commit/7f5fe30a150e will only work with
  # CMake < 3.17 due to a bug in LLVM's ExternalProjectAdd.
  TGT_FIX=7f5fe30a150e7e87d3fbe4da4ab0e76ec38b40b9

  # A syntax error in SVN r312500 (https://github.com/llvm/llvm-project/commit/9e68b734d6d0a98c672aebbe64956476cc140008)
  # that doesn't get instantiated due to another bug in old GCC builds (https://gcc.gnu.org/bugzilla/show_bug.cgi?id=84012)
  # This got fixed in llvm-6 but was present in 5 and 4, possibly older version too
  ORC_FIX="9e68b734d6d0a98c672aebbe64956476cc140008"

  # Commits before SVN r291939 (https://github.com/llvm/llvm-project/commit/c6e4583dbbdc3112c9a04d35a161dc9b4657f607)
  # has a syntax error for capture names
  CGF_FIX="c6e4583dbbdc3112c9a04d35a161dc9b4657f607"


  # A syntax error in SVN r265828 (https://github.com/llvm/llvm-project/commit/69341e6abca92f7f118ee7bd99be0cdfc649386f)
  # where `hasMD` had no users up until that point
  HMD_FIX="69341e6abca92f7f118ee7bd99be0cdfc649386f"

  echo "Build   : $build"
  echo "Commit  : $hash"

  git -c protocol.version=2 fetch \
    --quiet \
    --no-tags \
    --prune \
    --progress \
    --no-recurse-submodules \
    --filter=blob:none \
    origin "$hash" "$TGT_FIX" "$ORC_FIX" "$CGF_FIX" "$HMD_FIX"

  git checkout -f -q "$hash"
  git clean -fdx

  echo "Source cloned, starting build step..."

  if git_is_ancestor "$TGT_FIX" "$hash"; then
    echo "Commit requires CMake < 3.17, building from scratch..."
    build_cmake "v3.16" "3.16.4"
  else
    echo "Commit does not require CMake < 3.17, continuing..."
    cmake3() { /usr/bin/cmake "$@"; }
  fi

  if git_is_ancestor "$ORC_FIX" "$hash"; then
    f="llvm/include/llvm/ExecutionEngine/Orc/OrcRemoteTargetClient.h"
    echo "Patching $f"
    if [[ -f "$f" ]]; then
      awk '{
        o=$0
        gsub(/Expected<std::vector<char>>/, "Expected<std::vector<uint8_t>>")
        if ($0!=o) c=1
        print
      } END { if (!c) exit 3 }' "$f" > tmp && mv tmp "$f"
    else echo "Warn: $f not found, skipping." >&2
    fi
  else echo "Commit does not require patching OrcRemoteTargetClient.h, continuing..."
  fi

  if git_is_ancestor "$CGF_FIX" "$hash"; then
    f="clang/lib/CodeGen/CGOpenMPRuntime.cpp"
    echo "Patching $f"
    pats=(
      '\\[\\&CGF, Device, \\&Info\\]\\(CodeGenFunction \\&CGF,'
      '\\[\\&D, \\&CGF, Device, \\&Info, \\&CodeGen, \\&NoPrivAction\\]'
      '\\[\\&D, \\&CGF, Device\\]\\(CodeGenFunction \\&CGF, PrePostActionTy \\&\\)'
      '\\[\\&D, \\&CGF, \\&BasePointersArray, \\&PointersArray,'
      '\\[\\&CGF, \\&BasePointersArray, \\&PointersArray, \\&SizesArray,'

    )
    reps=(
      '[Device, \\&Info](CodeGenFunction \\&CGF,'
      '[\\&D, Device, \\&Info, \\&CodeGen, \\&NoPrivAction]'
      '[\\&D, Device](CodeGenFunction \\&CGF, PrePostActionTy \\&)'
      '[\\&D, \\&BasePointersArray, \\&PointersArray,'
      '[\\&BasePointersArray, \\&PointersArray, \\&SizesArray,'
    )
    
    for i in "${!pats[@]}"; do
      tmp=$(mktemp)
      # Don't fail, llvm 3.x won't match but is fine without this 
      if ! awk -v p="${pats[i]}" -v r="${reps[i]}" '{
          if(!done && sub(p, r)) done=1
          print
        } END{ exit (done ? 0 : 2) }' "$f" >"$tmp"
      then echo "Warning: no match for pattern ${pats[i]}" >&2
      fi
      mv "$tmp" "$f"
    done
  else echo "Commit does not require patching CGOpenMPRuntime.h, continuing..."
  fi

  if git_is_ancestor "$HMD_FIX" "$hash"; then
    f="llvm/include/llvm/IR/ValueMap.h"
    echo "Patching $f"
    awk '{
      o=$0
      sub(/bool hasMD\(\) const { return MDMap; }/,
                  "bool hasMD() const { return bool(MDMap); }")
      if($0!=o) c=1
      print
    } END{ if(!c) exit 3 }' "$f" >tmp && mv tmp "$f"
  else echo "Commit does not require patching ValueMap.h, continuing..."
  fi


  if $dry; then
    echo "Dry run, creating dummy artefact..."
    mkdir -p "$dest_dir"
    echo "$build" >"$dest_dir/data.txt"
  else

    pwd
    ls -lah

    rm -rf build
    mkdir -p build

    install_dir="$dest_dir/opt/$build"
    rm -rf "$install_dir"
    mkdir -p "$install_dir"

    flags="-g1 -gz=zlib -fno-omit-frame-pointer -gno-column-info -femit-struct-debug-reduced"

    broken_pstl=false
    if [[ ! -f pstl/CMakeLists.txt ]]; then
        broken_pstl=true
    elif grep -q 'set(PARALLELSTL_BACKEND "tbb" CACHE STRING "Threading backend; defaults to TBB")' pstl/CMakeLists.txt; then
        broken_pstl=true
    fi

    working_projects="clang;lld;openmp"
    if [[ "$broken_pstl" == false ]]; then working_projects="$working_projects;pstl"; fi

    project_to_build="$(filter_cmake_list "$working_projects" "%%/CMakeLists.txt")"
    echo "Using project list: $project_to_build"

    arch_to_build="$(filter_cmake_list "X86;AArch64;NVPTX;AMDGPU" "llvm/lib/Target/%%/CMakeLists.txt")"
    echo "Using arch list: $arch_to_build"

    # LLVM <= 3.x uses the old-style subprojects, move them into the expected places
    if ! grep -q "LLVM_ENABLE_PROJECTS" llvm/CMakeLists.txt; then
      echo "LLVM_ENABLE_PROJECTS missing, moving projects to the expected directories..."
      mkdir -p "llvm/projects" "llvm/tools"

      # < 3.8  has busted openmp support, don't copy
      major="$(sed -nE 's/^[[:space:]]*set[[:space:]]*\(LLVM_VERSION_MAJOR[[:space:]]*([0-9]+)\).*/\1/p' llvm/CMakeLists.txt | head -n1 || true)"
      minor="$(sed -nE 's/^[[:space:]]*set[[:space:]]*\(LLVM_VERSION_MINOR[[:space:]]*([0-9]+)\).*/\1/p' llvm/CMakeLists.txt | head -n1 || true)"
      if [ -z "${major:-}" ] || [ -z "${minor:-}" ]; then
        echo "ERROR: Could not determine LLVM version from source tree." >&2
        exit 1
      fi
      case "${major}.${minor}" in
        3.8 | 3.9)
          echo "LLVM >= 3.8 detected - adding OpenMP"
          for proj in openmp; do
            if [ -d "$proj" ]; then
              mv "$proj" llvm/projects/
            fi
          done
          ;;
        *)
          echo "LLVM ${major}.${minor} < 3.8, not including broken OpenMP"
          ;;
      esac
      for proj in clang lld; do # copy the rest
        if [ -d "$proj" ]; then
          mv "$proj" llvm/tools/
        fi
      done
      # LLVM <= 3.x doesn't like toolchain only for some reason
      extra+=("-DLLVM_INSTALL_TOOLCHAIN_ONLY=OFF")
    else 
      extra+=("-DLLVM_INSTALL_TOOLCHAIN_ONLY=ON")
    fi

    cmake3 --version
    {

    time \
    LDFLAGS="-pthread" \
    CFLAGS="$flags" \
    CXXFLAGS="$flags -include cstdint -include cstdlib -include string -include cstdio -Wno-template-id-cdtor -Wno-missing-template-keyword -Wno-attributes -Wno-maybe-uninitialized -Wno-deprecated-declarations -Wno-class-memaccess -Wno-cast-function-type -Wno-redundant-move -Wno-init-list-lifetime" \
      cmake3 -S llvm -B build \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache \
      -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLVM_ENABLE_ASSERTIONS=ON \
      -DLLVM_LINK_LLVM_DYLIB=ON \
      -DLLVM_BUILD_LLVM_DYLIB=ON \
      -DLLVM_ENABLE_PROJECTS="$project_to_build" \
      -DLLVM_TARGETS_TO_BUILD="$arch_to_build" \
      -DLLVM_INCLUDE_BENCHMARKS=OFF \
      -DLLVM_INCLUDE_TESTS=OFF \
      -DLLVM_INCLUDE_DOCS=OFF \
      -DLLVM_INCLUDE_EXAMPLES=OFF \
      -DLLVM_BUILD_TESTS=OFF \
      -DLLVM_BUILD_DOCS=OFF \
      -DLLVM_BUILD_EXAMPLES=OFF \
      -DLLVM_STATIC_LINK_CXX_STDLIB=ON \
      -DLIBOMP_USE_QUAD_PRECISION=OFF \
      -DCMAKE_INSTALL_PREFIX="$install_dir" \
      "${extra[@]}" \
      -GNinja

    time cmake3 --build build # Ninja is parallel by default
    time cmake3 --build build --target install
     
    } 2>&1 | tee "$install_dir/build.log"

  fi

  time XZ_OPT='-T0 -9e --block-size=16MiB' tar cfJ "$dest_archive" --checkpoint=.1000 --totals --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -C "$dest_dir" .

  echo ""
  du -sh "$dest_dir"
  du -sh "$dest_archive"

  rm -rf "$dest_dir"
  ccache -s

done
