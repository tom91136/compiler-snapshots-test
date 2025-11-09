#!/usr/bin/env bash

set -euo pipefail

export PATH="/usr/lib64/ccache${PATH:+:${PATH}}"

ccache --set-config=sloppiness=locale,time_macros
ccache -M 10G
ccache -s

readonly CROSS_ARCH="${CROSS_ARCH:?cross architecture}"
readonly BUILDS=${1:-}
readonly dry=false

# shellcheck disable=SC2206
builds_array=(${BUILDS//;/ }) # split by ws

readonly cmake_prefix="$PWD"

build_cmake() {
  local cmake_major=$1
  local cmake_ver=$2

  local prefix="$cmake_prefix/cmake-${cmake_ver}"
  local workdir="/tmp"
  local src_tar="$workdir/cmake-${cmake_ver}.tar.gz"
  local src_dir="$workdir/cmake-${cmake_ver}"

  if [ ! -x "$prefix/bin/cmake" ]; then
    # CMake needs openssl-devel, which is included in the build image
    wget -O "$src_tar" "https://cmake.org/files/${cmake_major}/cmake-${cmake_ver}.tar.gz"
    tar xf "$src_tar" -C "$workdir"
    (
      cd "$src_dir"
      cmake -S . -B build -DCMAKE_INSTALL_PREFIX="$prefix" -GNinja
      cmake --build build --target install
      rm -rf "$src_dir" "$src_tar"
    )
  fi

  eval "cmake() { \"$prefix/bin/cmake\" \"\$@\"; }"
}

build_ninja() {
  local ninja_ver=1.13.1

  wget -O "ninja-${ninja_ver}.tar.gz" \
    "https://github.com/ninja-build/ninja/archive/refs/tags/v${ninja_ver}.tar.gz"
  tar -xf "ninja-${ninja_ver}.tar.gz"

  (
    cd ninja-${ninja_ver}
    cmake -Bbuild-cmake -DBUILD_TESTING=OFF
    cmake --build build-cmake -j "$(nproc)"
  )

  export PATH="$PWD/ninja-${ninja_ver}/build-cmake:$PATH"
  ninja --version
}

if [ ! -d /llvm/.git ]; then
  rm -rf /llvm
  git init /llvm
fi
cd /llvm
if git remote get-url origin &>/dev/null; then
  git remote set-url origin https://github.com/llvm/llvm-project.git
else
  git remote add origin https://github.com/llvm/llvm-project.git
fi
git config --local gc.auto 0

git_is_ancestor() { git merge-base --is-ancestor "$1" "$2"; }

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

  (
    IFS=";"
    echo "${result[*]}"
  )
}

extract_cmake_set() {
  local name="$1"
  shift
  local val f
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    val="$(sed -nE "s/^[[:space:]]*set[[:space:]]*\\(${name}[[:space:]]*([0-9]+)\\).*/\\1/p" "$f" | head -n1 || true)"
    [[ -n "${val:-}" ]] && printf '%s\n' "$val" && return 0
    val="$(sed -nE "s/^[[:space:]]*set[[:space:]]*\\(${name}[[:space:]]*\"?([0-9]+(\\.[0-9]+)?)\"?\\).*/\\1/p" "$f" | head -n1 || true)"
    [[ -n "${val:-}" ]] && printf '%s\n' "$val" && return 0
  done
  return 1
}

if [[ ${#builds_array[@]} -eq 0 ]] && git rev-parse --git-dir &>/dev/null; then
  commit="$(git rev-parse HEAD)"
  echo "[bisect] Currently on commit $commit"
  builds_array=("$commit")
fi

for build in "${builds_array[@]}"; do
  dest_dir="/tmp/$build"
  dest_archive="/host/$build.squashfs"

  if [[ "$build" == llvm-* ]]; then
    build_no_arch="${build%.*}"
    builds_json="/host/builds-llvm-$CROSS_ARCH.json"
    hash=$(jq -r ".\"$build_no_arch\" | .hash" "$builds_json")
  else
    hash="$build"
  fi

  # Commits before https://github.com/llvm/llvm-project/commit/7f5fe30a150e will only work with
  # CMake < 3.17 due to a bug in LLVM's ExternalProjectAdd.
  readonly TGT_FIX="7f5fe30a150e7e87d3fbe4da4ab0e76ec38b40b9"

  # A syntax error in SVN r312500 (https://github.com/llvm/llvm-project/commit/9e68b734d6d0a98c672aebbe64956476cc140008)
  # that doesn't get instantiated due to another bug in old GCC builds (https://gcc.gnu.org/bugzilla/show_bug.cgi?id=84012)
  # This got fixed in llvm-6 but was present in 5 and 4, possibly older version too
  readonly ORC_FIX="9e68b734d6d0a98c672aebbe64956476cc140008"

  # Commits before SVN r291939 (https://github.com/llvm/llvm-project/commit/c6e4583dbbdc3112c9a04d35a161dc9b4657f607)
  # has a syntax error for capture names
  readonly CGF_FIX="c6e4583dbbdc3112c9a04d35a161dc9b4657f607"

  # A syntax error in SVN r265828 (https://github.com/llvm/llvm-project/commit/69341e6abca92f7f118ee7bd99be0cdfc649386f)
  # where `hasMD` had no users up until that point
  readonly HMD_FIX="69341e6abca92f7f118ee7bd99be0cdfc649386f"

  # Issue specific to GCC 14 macro expansion when compiling Clang,
  # Debian has a patch for 17-18 at https://salsa.debian.org/pkg-llvm-team/llvm-toolchain/-/blob/f83b695bae4af4361b6892203305cdb05b3f41ab/debian/patches/arm64-clang-gcc-14.patch
  # a "hack" landed upstream during 18
  readonly ARM_FIX="d54dfdd1b53ff72344287d250c2b67329792c840"

  # An option landed after this commit to limit the number of threads to use when building flang
  # due to excessive memory usage (max ~6GB per file)
  readonly FLANG_FIX="2e5ec1cc5b8ef30f04f53d927860184acf7150b3"

  # Flang has a bug where if LLVM_INSTALL_TOOLCHAIN_ONLY=ON is set, the required MLIR DSO is not installed
  # and we end up with a non-functional flang binary, see https://github.com/llvm/llvm-project/commit/69d0bd56ad064df569cd065902fb7036f0311c0a
  readonly MLIR_FIX="69d0bd56ad064df569cd065902fb7036f0311c0a"

  # The lexer has a inconsistent AltiVec vector usage, which was fixed to __vector
  # in https://github.com/llvm/llvm-project/commit/3185c30c54d0af5bffbff3bcfd721668d086ff10
  readonly PPCVEC_FIX="3185c30c54d0af5bffbff3bcfd721668d086ff10"

  # Flang has a unfinished section on sums and reductions where a long double and ieee 128 was mixed in a template
  # this work was subsequently completed in https://github.com/llvm/llvm-project/commit/104f3c180644c8872eaad0b3fcf6a6b948d92a71
  readonly PPCSUM_FIX="104f3c180644c8872eaad0b3fcf6a6b948d92a71"

  echo "Build   : $build"
  echo "Commit  : $hash"

  if [[ "$(git rev-parse HEAD)" != "$hash" ]]; then
    git -c protocol.version=2 fetch \
      --quiet \
      --no-tags \
      --prune \
      --progress \
      --no-recurse-submodules \
      --filter=blob:none \
      origin "$hash" "$TGT_FIX" "$ORC_FIX" "$CGF_FIX" "$HMD_FIX" "$ARM_FIX" "$FLANG_FIX" "$MLIR_FIX" "$PPCVEC_FIX" "$PPCSUM_FIX"
    git checkout -f -q "$hash"
  else
    git reset HEAD --hard
  fi

  git clean -ffdx

  echo "Source cloned, starting build step..."

  readonly llvm_version_files=(
    "llvm/CMakeLists.txt"
    "cmake/Modules/LLVMVersion.cmake"
  )
  major="$(extract_cmake_set LLVM_VERSION_MAJOR "${llvm_version_files[@]}" || true)"
  minor="$(extract_cmake_set LLVM_VERSION_MINOR "${llvm_version_files[@]}" || true)"

  if [[ -z "${major:-}" || -z "${minor:-}" ]]; then
    if ver="$(extract_cmake_set PACKAGE_VERSION "${llvm_version_files[@]}" || true)"; then
      IFS=. read -r major minor _ <<<"$ver"
    fi
  fi

  if [[ -z "${major:-}" || -z "${minor:-}" ]]; then
    echo "ERROR: Could not determine LLVM version from source tree." >&2
    exit 1
  fi
  echo "Detected LLVM version: $major.$minor"

  if git_is_ancestor "$TGT_FIX" "$hash"; then
    echo "Commit does not require CMake < 3.17, continuing..."
    cmake() { /usr/bin/cmake "$@"; }
  else
    echo "Commit requires CMake < 3.17, building from scratch..."
    build_cmake "v3.16" "3.16.4"
  fi

  if git_is_ancestor "$ORC_FIX" "$hash"; then
    echo "Commit does not require patching OrcRemoteTargetClient.h, continuing..."
  else
    f="llvm/include/llvm/ExecutionEngine/Orc/OrcRemoteTargetClient.h"
    echo "Patching $f"
    if [[ -f "$f" ]]; then
      awk '{
        o=$0
        gsub(/Expected<std::vector<char>>/, "Expected<std::vector<uint8_t>>")
        if ($0!=o) c=1
        print
      } END { if (!c) exit 3 }' "$f" >tmp && mv tmp "$f"
    else
      echo "Warn: $f not found, skipping." >&2
    fi
  fi

  if git_is_ancestor "$CGF_FIX" "$hash"; then
    echo "Commit does not require patching CGOpenMPRuntime.h, continuing..."
  else
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
    if [[ -f "$f" ]]; then
      for i in "${!pats[@]}"; do
        tmp=$(mktemp)
        # Don't fail, llvm 3.x won't match but is fine without this
        if ! awk -v p="${pats[i]}" -v r="${reps[i]}" '{
          if(!done && sub(p, r)) done=1
          print
        } END{ exit (done ? 0 : 2) }' "$f" >"$tmp"; then
          echo "Warning: no match for pattern ${pats[i]}" >&2
        fi
        mv "$tmp" "$f"
      done
    fi
  fi

  if git_is_ancestor "$HMD_FIX" "$hash"; then
    echo "Commit does not require patching ValueMap.h, continuing..."
  else
    f="llvm/include/llvm/IR/ValueMap.h"
    echo "Patching $f"
    awk '{
      o=$0
      sub(/bool hasMD\(\) const { return MDMap; }/,
                  "bool hasMD() const { return bool(MDMap); }")
      if($0!=o) c=1
      print
    } END{ if(!c) exit 3 }' "$f" >tmp && mv tmp "$f"
  fi

  if git_is_ancestor "$FLANG_FIX" "$hash"; then
    echo "Commit does not require patching flang/CMakeList.txt"
  else
    f="flang/CMakeLists.txt"
    echo "Patching $f"
    awk '
      { lines[NR] = $0 }
      /set\(FLANG_PARALLEL_COMPILE_JOBS/ { seen = 1 }
      END {
        for (i = 1; i <= NR; ++i) {
          print lines[i]
          if (!seen && lines[i] ~ /^list\(REMOVE_DUPLICATES CMAKE_CXX_FLAGS\)\s*$/) {
            print "set(FLANG_PARALLEL_COMPILE_JOBS CACHE STRING"
            print "  \"The maximum number of concurrent compilation jobs for Flang (Ninja only)\")"
            print "if (FLANG_PARALLEL_COMPILE_JOBS)"
            print "  set_property(GLOBAL APPEND PROPERTY JOB_POOLS flang_compile_job_pool=${FLANG_PARALLEL_COMPILE_JOBS})"
            print "endif()"
            changed = 1
          }
        }
        if (!changed) exit 3
      }
' "$f" >tmp && mv tmp "$f"
    g="flang/cmake/modules/AddFlang.cmake"
    echo "Patching $g"
    awk '
  { lines[NR] = $0 }
  /JOB_POOL_COMPILE[[:space:]]+flang_compile_job_pool/ { seen = 1 }
  END {
    for (i = 1; i <= NR; ++i) {
      print lines[i]
      if (!seen && lines[i] ~ /^[[:space:]]*if[[:space:]]*\(TARGET[[:space:]]*\$\{name\}\)[[:space:]]*$/) {
        print "  if (FLANG_PARALLEL_COMPILE_JOBS)"
        print "    set_property(TARGET ${name} PROPERTY JOB_POOL_COMPILE flang_compile_job_pool)"
        print "  endif()"
        changed = 1
      }
    }
    if (!changed) exit 3
  }
' "$g" >tmp && mv tmp "$g"
  fi

  if git_is_ancestor "$MLIR_FIX" "$hash"; then
    echo "Commit does not require patching AddMLIR.cmake"
  else
    f="mlir/cmake/modules/AddMLIR.cmake"
    echo "Patching $f"
    awk '
    /target_link_libraries\(\$\{name\} INTERFACE \${LLVM_COMMON_LIBS}\)/ && !ins1 {
      print
      print "    if(ARG_INSTALL_WITH_TOOLCHAIN)"
      print "      set_target_properties(${name} PROPERTIES MLIR_INSTALL_WITH_TOOLCHAIN TRUE)"
      print "    endif()"
      ins1=1; next
    }
    $0 ~ /^function\s*\(\s*add_mlir_library_install\s+name\s*\)/ { in_install=1 }
    in_install && $0 ~ /^\s*if\s*\(\s*NOT\s+LLVM_INSTALL_TOOLCHAIN_ONLY\s*\)/ && !ins2 {
      print "  get_target_property(_install_with_toolchain ${name} MLIR_INSTALL_WITH_TOOLCHAIN)"
      sub(/\)\s*$/, " OR _install_with_toolchain)")
      print
      ins2=1; next
    }
    in_install && $0 ~ /^endfunction/ { in_install=0 }
    { print } ' "$f" >"$f.new" && mv "$f.new" "$f"
  fi

  if git_is_ancestor "$PPCVEC_FIX" "$hash"; then
    echo "Commit does not require patching Lexer.cpp, continuing..."
  else
    f="clang/lib/Lex/Lexer.cpp"
    echo "Patching $f"
    awk '
      {
        gsub(/const vector unsigned char\*/, "const __vector unsigned char*");
        print
      }' "$f" >tmp && mv tmp "$f"
  fi

  if git_is_ancestor "$PPCSUM_FIX" "$hash"; then
    echo "Commit does not require patching sum.cpp, continuing..."
  else
    f="flang/runtime/sum.cpp"
    echo "Patching $f"
    awk '
      {
        gsub(/long double/, "CppTypeFor<TypeCategory::Real, 16>");
            print
      }' "$f" >tmp && mv tmp "$f"
  fi

  if git_is_ancestor "$ARM_FIX" "$hash"; then
    echo "Commit does not require patching TokenKinds.def, continuing..."
  else
    echo "Patching TokenKinds.def + 2 others"
    token_patch=$(
      cat <<'EOF'
diff --git a/clang/include/clang/Basic/TokenKinds.def b/clang/include/clang/Basic/TokenKinds.def
index ef0dad0f2dcd..4c3965ca24ed 100644
--- a/clang/include/clang/Basic/TokenKinds.def
+++ b/clang/include/clang/Basic/TokenKinds.def
@@ -753,7 +753,7 @@ KEYWORD(__builtin_sycl_unique_stable_name, KEYSYCL)
 
 // Keywords defined by Attr.td.
 #ifndef KEYWORD_ATTRIBUTE
-#define KEYWORD_ATTRIBUTE(X) KEYWORD(X, KEYALL)
+#define KEYWORD_ATTRIBUTE(X, HASARG, EMPTY) KEYWORD(EMPTY ## X, KEYALL)
 #endif
 #include "clang/Basic/AttrTokenKinds.inc"
 
diff --git a/clang/include/clang/Basic/TokenKinds.h b/clang/include/clang/Basic/TokenKinds.h
index e4857405bc7f..988696b6d92b 100644
--- a/clang/include/clang/Basic/TokenKinds.h
+++ b/clang/include/clang/Basic/TokenKinds.h
@@ -109,7 +109,7 @@ bool isPragmaAnnotation(TokenKind K);
 
 inline constexpr bool isRegularKeywordAttribute(TokenKind K) {
   return (false
-#define KEYWORD_ATTRIBUTE(X) || (K == tok::kw_##X)
+#define KEYWORD_ATTRIBUTE(X, HASARG, EMPTY) || (K == tok::kw_##X)
 #include "clang/Basic/AttrTokenKinds.inc"
   );
 }
diff --git a/clang/utils/TableGen/ClangAttrEmitter.cpp b/clang/utils/TableGen/ClangAttrEmitter.cpp
index b5813c6abc2b..3394e4d8594c 100644
--- a/clang/utils/TableGen/ClangAttrEmitter.cpp
+++ b/clang/utils/TableGen/ClangAttrEmitter.cpp
@@ -3423,14 +3423,14 @@ void EmitClangAttrTokenKinds(RecordKeeper &Records, raw_ostream &OS) {
   // Assume for now that the same token is not used in multiple regular
   // keyword attributes.
   for (auto *R : Records.getAllDerivedDefinitions("Attr"))
-    for (const auto &S : GetFlattenedSpellings(*R))
-      if (isRegularKeywordAttribute(S)) {
-        if (!R->getValueAsListOfDefs("Args").empty())
-          PrintError(R->getLoc(),
-                     "RegularKeyword attributes with arguments are not "
-                     "yet supported");
+    for (const auto &S : GetFlattenedSpellings(*R)) {
+      if (!isRegularKeywordAttribute(S))
+          continue;
+        std::vector<Record *> Args = R->getValueAsListOfDefs("Args");
+        bool HasArgs = llvm::any_of(Args, [](const Record *Arg) { return !Arg->getValueAsBit("Fake"); });
         OS << "KEYWORD_ATTRIBUTE("
-           << S.getSpellingRecord().getValueAsString("Name") << ")\n";
+           << S.getSpellingRecord().getValueAsString("Name") << ", "
+           << (HasArgs ? "true" : "false") << ", )\n";
       }
   OS << "#undef KEYWORD_ATTRIBUTE\n";
 }
EOF
    )
    if echo "$token_patch" | git apply -; then
      echo "TokenKinds.def patched applied"
    else
      echo "Warn: TokenKinds.def patch did not apply"
    fi
  fi

  if ((major == 3 && minor <= 5)); then
    # XXX@ Fix bad visibility for IntrusiveRefCntPtr<X>
    # readonly IRCP_FIX="a170697b18c3667a6ea70ea27246e69e202ba3a4"
    # This is prevalent in < 3.5 so just do it for all those
    f="llvm/include/llvm/ADT/IntrusiveRefCntPtr.h"
    echo "Patching $f"
    awk '{
        print
        if (!done && $0 ~ /void[[:space:]]+release\(\)/) {
          match($0,/^[[:space:]]*/); ws=substr($0,RSTART,RLENGTH)
          print ws "  template <typename X>"
          print ws "  friend class IntrusiveRefCntPtr;"
          done=1
        }
      }' "$f" >tmp && mv tmp "$f"
  else
    echo "Commit does not require patching IntrusiveRefCntPtr.h, continuing..."
  fi

  if ((major == 3 && minor <= 1)); then
    f="clang/lib/CodeGen/CGDebugInfo.cpp"
    echo "Patching $f"
    awk '{
      if ($0 ~ /ReplaceMap\.push_back\(std::make_pair\(Ty.getAsOpaquePtr\(\),/) {
        sub(/ReplaceMap\.push_back\(std::make_pair\(Ty.getAsOpaquePtr\(\),[ \t]*/,
            "ReplaceMap.push_back(std::make_pair(Ty.getAsOpaquePtr(), llvm::WeakVH(")
        sub(/\)\);$/, ")));")
      }
      print
    }' "$f" >tmp && mv tmp "$f"
    f="llvm/tools/bugpoint/ToolRunner.cpp"
    echo "Patching $f"
    awk '{
      if ($0 ~ /errs\(\) *<< *OS *;/) sub(/OS *;/,"OS.str();");
      print
      }' "$f" >tmp && mv tmp "$f"
  else
    echo "Version does not require patching CGDebugInfo.cpp, continuing..."
    echo "Version does not require patching ToolRunner.cpp, continuing..."
  fi

  if ((major == 3 && minor == 0)); then
    f="llvm/include/llvm/ADT/PointerUnion.h"
    echo "Patching $f"
    awk '{
          gsub(/Ty\(Val\)\.is</,  "Ty(Val).template is<");
          gsub(/Ty\(Val\)\.get</, "Ty(Val).template get<");
          print
        }' "$f" >"$f.new" && mv "$f.new" "$f"

    f="llvm/include/llvm/ADT/IntervalMap.h"
    echo "Patching $f"
    awk '{
        gsub(/this->map->newNode</,"this->map->template newNode<");
        print
        }' "$f" >"$f.new" && mv "$f.new" "$f"
  else
    echo "Commit does not require patching PointerUnion.h, continuing..."
  fi

  {
    f="llvm/cmake/modules/AddLLVM.cmake"
    echo "Patching $f"
    awk '
      /^[[:space:]]*set[[:space:]]*\([[:space:]]*LLVM_TOOLCHAIN_TOOLS([[:space:]]|$)/ && !done {
        match($0,/^[[:space:]]*/)
        indent = substr($0, RSTART, RLENGTH)
        print
        print indent "  llc"
        print indent "  lli"
        print indent "  opt"
        print indent "  llvm-as"
        print indent "  llvm-config"
        print indent "  llvm-diff"
        print indent "  llvm-dis"
        print indent "  llvm-dwarfdump"
        print indent "  llvm-extract"
        print indent "  llvm-link"
        done=1
        next
      }
      { print }
    ' "$f" >tmp && mv tmp "$f"
  }

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

    extra=()
    nowarn=(
      "-Wno-template-id-cdtor"
      "-Wno-missing-template-keyword"
      "-Wno-attributes"
      "-Wno-maybe-uninitialized"
      "-Wno-deprecated-declarations"
      "-Wno-class-memaccess"
      "-Wno-cast-function-type"
      "-Wno-redundant-move"
      "-Wno-init-list-lifetime"
      "-Wno-dangling-reference"
      "-Wno-overloaded-virtual"
    )

    includes=(
      "-include cstdint"
      "-include cstdlib"
      "-include cstdio"
      "-include limits"
      "-include string"
    )

    cflags=()
    cxxflags=()

    flags=(
      -g1
      -gz=zlib
      -fno-omit-frame-pointer
      -gno-column-info
      -femit-struct-debug-reduced
    )

    broken_pstl=false
    if [[ ! -f pstl/CMakeLists.txt ]]; then
      broken_pstl=true
    elif grep -q 'set(PARALLELSTL_BACKEND "tbb" CACHE STRING "Threading backend; defaults to TBB")' pstl/CMakeLists.txt; then
      broken_pstl=true
    fi

    broken_lld=false
    if ((major < 3 || (major == 3 && minor <= 5))); then
      broken_lld=true
    fi

    if ((major < 3 || (major == 3 && minor <= 3))); then
      extra+=("-DPYTHON_EXECUTABLE=/usr/bin/python2")
    fi

    if ((major < 3 || (major == 3 && minor <= 4))); then
      cxxflags+=("-std=gnu++11")
      includes+=("-include time.h")
    fi

    enable_flang=false
    if ((major >= 17)); then
      # before 17 flang doesn't really work, see https://github.com/mesonbuild/meson/issues/12306
      enable_flang=true
    fi

    if [[ "$enable_flang" == true ]]; then
      # In LLVM 21, the build itself includes fortran sources which requires newer ninja
      build_ninja
      # Horrible hack that injects the SCL toolchain which isn't detected during flang-rt as it uses the just-built clang
      toolchain_root="$(dirname "$(dirname "$(command -v gcc)")")"
      export CCC_OVERRIDE_OPTIONS="^--gcc-toolchain=$toolchain_root"
    fi

    if [[ -n "${FLANG_MAX_MEMORY_MB:-}" ]]; then
      flang_nproc="$(awk -v mem_mb="$FLANG_MAX_MEMORY_MB" 'BEGIN {m=int(mem_mb/5000); if(m<2)m=2; print m}')"
    else
      flang_nproc="$(awk '/MemTotal:/ {m=int(($2/1024)/5000); if(m<2)m=2; print m}' /proc/meminfo)"
    fi
    echo "Using $flang_nproc threads for FLANG_PARALLEL_COMPILE_JOBS"

    working_projects="clang"
    if [[ "$broken_pstl" == false ]]; then working_projects="$working_projects;pstl"; fi
    if [[ "$broken_lld" == false ]]; then working_projects="$working_projects;lld"; fi
    if [[ "$enable_flang" == true ]]; then working_projects="$working_projects;flang"; fi

    project_to_build="$(filter_cmake_list "$working_projects" "%%/CMakeLists.txt")"
    echo "Using project list: $project_to_build"

    case "$CROSS_ARCH" in
    riscv64) arch_list="RISCV" ;;
    *) echo "Unsupported cross arch: $CROSS_ARCH" && exit 1 ;;
    esac

    arch_to_build="$(filter_cmake_list "$arch_list" "llvm/lib/Target/%%/CMakeLists.txt")"
    echo "Using arch list: $arch_to_build"

    native_project="clang"
    if [[ "$enable_flang" == true ]]; then native_project="$native_project;mlir"; fi

    # LLVM <= 3.x uses the old-style subprojects, move them into the expected places
    if ! grep -q "LLVM_ENABLE_PROJECTS" llvm/CMakeLists.txt; then
      echo "LLVM_ENABLE_PROJECTS missing, moving projects to the expected directories..."
      mkdir -p "llvm/projects" "llvm/tools"
      case "${major}.${minor}" in
      3.8 | 3.9)
        echo "LLVM >= 3.8 detected, adding OpenMP"
        if [ -d "openmp" ]; then mv "openmp" llvm/projects/; fi
        ;;
      *)
        echo "LLVM ${major}.${minor} < 3.8, not including broken OpenMP"
        ;;
      esac
      for proj in clang lld; do # copy the rest
        if [[ "$broken_lld" == true ]] && [[ "$proj" == lld ]]; then continue; fi
        if [ -d "$proj" ]; then
          mv "$proj" llvm/tools/
        fi
      done
      # LLVM <= 3.x doesn't like toolchain only for some reason
      extra+=("-DLLVM_INSTALL_TOOLCHAIN_ONLY=OFF")
    else
      extra+=("-DLLVM_INSTALL_TOOLCHAIN_ONLY=ON")
    fi

    cmake --version
    {

      time LDFLAGS="-pthread" \
        CFLAGS="${cflags[*]} ${flags[*]}" \
        CXXFLAGS="${cxxflags[*]} ${flags[*]} ${includes[*]} ${nowarn[*]}" \
        cmake -S llvm -B build-native \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -DLLVM_ENABLE_ASSERTIONS=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_PROJECTS="$native_project" \
        -DLLVM_TARGETS_TO_BUILD="$arch_to_build" \
        -GNinja

      time cmake --build build-native --target llvm-tblgen
      time cmake --build build-native --target clang-tblgen
      if [[ "$enable_flang" == true ]]; then
        time cmake --build build-native --target mlir-tblgen
        time cmake --build build-native --target mlir-linalg-ods-yaml-gen || true
      fi

      (
        export CC="ccache $CROSS_ARCH-linux-gnu-gcc"
        export CXX="ccache $CROSS_ARCH-linux-gnu-g++"
        export AR="ccache $CROSS_ARCH-linux-gnu-ar"
        export RANLIB="ccache $CROSS_ARCH-linux-gnu-ranlib"
        export LD="ccache $CROSS_ARCH-linux-gnu-ld"
        export STRIP="ccache $CROSS_ARCH-linux-gnu-strip"

        time LDFLAGS="-pthread" \
          CFLAGS="-march=rv64gc ${cflags[*]} ${flags[*]}" \
          CXXFLAGS="-march=rv64gc ${cxxflags[*]} ${flags[*]} ${includes[*]} ${nowarn[*]}" \
          cmake -S llvm -B build \
          -DCMAKE_C_COMPILER_LAUNCHER=ccache \
          -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
          -DCMAKE_BUILD_TYPE=Release \
          -DLLVM_ENABLE_ASSERTIONS=ON \
          -DLLVM_LINK_LLVM_DYLIB=ON \
          -DLLVM_BUILD_LLVM_DYLIB=ON \
          -DLLVM_ENABLE_PROJECTS="$project_to_build" \
          -DLLVM_TARGETS_TO_BUILD="$arch_to_build" \
          -DCLANG_DEFAULT_TARGET_TRIPLE="$CROSS_ARCH-linux-gnu" \
          -DLLVM_DEFAULT_TARGET_TRIPLE="$CROSS_ARCH-linux-gnu" \
          -DLLVM_NATIVE_TOOL_DIR="$PWD/build-native/bin" \
          -DLLVM_INCLUDE_BENCHMARKS=OFF \
          -DLLVM_INCLUDE_TESTS=OFF \
          -DLLVM_INCLUDE_DOCS=OFF \
          -DLLVM_INCLUDE_EXAMPLES=OFF \
          -DLLVM_BUILD_TESTS=OFF \
          -DLLVM_BUILD_DOCS=OFF \
          -DLLVM_BUILD_EXAMPLES=OFF \
          -DLLVM_STATIC_LINK_CXX_STDLIB=ON \
          -DLIBOMP_USE_QUAD_PRECISION=OFF \
          -DOPENMP_ENABLE_LIBOMPTARGET=OFF \
          -DLIBOMP_OMPD_GDB_SUPPORT=OFF \
          -DFLANG_INCLUDE_TESTS=OFF \
          -DFLANG_INCLUDE_DOCS=OFF \
          -DFLANG_RT_INCLUDE_TESTS=OFF \
          -DFLANG_PARALLEL_COMPILE_JOBS="$flang_nproc" \
          -DCMAKE_INSTALL_PREFIX="$install_dir" \
          "${extra[@]}" \
          -GNinja

        time cmake --build build -- -j"${MAX_PROC:-$(nproc)}" # Ninja is parallel by default
        time cmake --build build --target install
      )

    } 2>&1 | tee "$install_dir/build.log"

  fi

  filter=()
  case "$(uname -m)" in
  x86_64 | amd64) filter=("-Xbcj" "x86") ;;
  aarch64 | arm64) filter=("-Xbcj" "arm") ;;
  riscv64) filter=("-Xbcj" "riscv") ;;
  *) ;;
  esac

  mksquashfs "$dest_dir" "$dest_archive" \
    -comp xz "${filter[@]}" -Xdict-size 1M -b 1M -always-use-fragments -all-root -no-xattrs -noappend -processors "$(nproc)"

  echo ""
  du -sh "$dest_dir"
  du -sh "$dest_archive"

  rm -rf "$dest_dir"
  ccache -s

done
