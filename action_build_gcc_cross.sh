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

if [ ! -d /gcc/.git ]; then
  rm -rf /gcc
  git init /gcc
fi
cd /gcc
if git remote get-url origin &>/dev/null; then
  git remote set-url origin https://github.com/gcc-mirror/gcc.git
else
  git remote add origin https://github.com/gcc-mirror/gcc.git
fi
git config --local gc.auto 0

git_is_ancestor() { git merge-base --is-ancestor "$1" "$2"; }

if [[ ${#builds_array[@]} -eq 0 ]] && git rev-parse --git-dir &>/dev/null; then
  commit="$(git rev-parse HEAD)"
  echo "[bisect] Currently on commit $commit"
  builds_array=("$commit")
fi

for build in "${builds_array[@]}"; do
  dest_dir="/tmp/$build"
  dest_archive="/host/$build.squashfs"

  if [[ "$build" == gcc-* ]]; then
    build_no_arch="${build%.*}"
    builds_json="/host/builds-gcc-$CROSS_ARCH.json"
    hash=$(jq -r ".\"$build_no_arch\" | .hash" "$builds_json")
  else
    hash="$build"
  fi

  # Commits before 883312dc79806f513275b72502231c751c14ff72 has incompatibilities with newer (>=2.28?) glibc
  # see https://github.com/gcc-mirror/gcc/commit/883312dc79806f513275b72502231c751c14ff72
  # We also use alternative flags as C/C++ defaults at the time is different
  UCTX_FIX="883312dc79806f513275b72502231c751c14ff72"

  # Commits before df2a7a38f6f49656f08e0c34d7856b2709a9e5b6 has busted syntax that cases
  # "too many template-parameter-lists"
  # see https://github.com/gcc-mirror/gcc/commit/df2a7a38f6f49656f08e0c34d7856b2709a9e5b6
  WINT_FIX="df2a7a38f6f49656f08e0c34d7856b2709a9e5b6"

  #  TODO
  CROSS_FIX="4fde88e5dd152fe866a97b12e0f8229970d15cb3"

  # Commit after https://github.com/gcc-mirror/gcc/commit/27d68a60783b52504a08503d3fe12054de104241
  # broke build in a way that the target lib only compile for future (1+ the commit) versions of GCC
  # so, we need to disable HF in the target lib
  RISCVHF_FIX="27d68a60783b52504a08503d3fe12054de104241"

  # Undo is_convertible, not available in newer compilers
  TRAIT_FIX="af85ad891703db220b25e7847f10d0bbec4becf4"

  # Commit https://github.com/gcc-mirror/gcc/commit/cb775ecd6e437de8fdba9a3f173f3787e90e98f2
  # broke Canadian cross with the introduction of __LIBGCC_DWARF_CIE_DATA_ALIGNMENT__ so we shim it
  DW2_FIX="cb775ecd6e437de8fdba9a3f173f3787e90e98f2"

  # Commit https://github.com/gcc-mirror/gcc/commit/1a566fddea212a6a8e4484f7843d8e5d39b5bff0

  FLOATN_FIX="1a566fddea212a6a8e4484f7843d8e5d39b5bff0"

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
      origin "$hash" "$UCTX_FIX" "$WINT_FIX" "$CROSS_FIX" "$RISCVHF_FIX" "$TRAIT_FIX" "$DW2_FIX" "$FLOATN_FIX"
    git checkout -f -q "$hash"
  else
    git reset HEAD --hard
  fi

  git clean -ffdx

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

    install_dir="$dest_dir/opt/$build"
    mkdir -p "$install_dir"

    ver=""
    if [[ -r "gcc/BASE-VER" ]]; then
      ver="$(head -n1 "gcc/BASE-VER" | tr -d '[:space:]')"
    elif [[ -z "$ver" && -r "gcc/version.c" ]]; then
      ver="$(awk -F'"' '/version_string/ {print $2; exit}' "gcc/version.c" | awk '{print $1}')"
    fi
    if [[ -z "${ver:-}" ]]; then
      echo "ERROR: Could not determine GCC version from source tree." >&2
      exit 1
    fi

    major="$(awk -F. '{print $1}' <<<"$ver")"
    minor="$(awk -F. '{print ($2 == "" ? 0 : $2)}' <<<"$ver")"
    echo "Detected GCC version:  $major.$minor (ver=$ver)"

    time ./contrib/download_prerequisites --no-isl --no-verify

    config_env_extra=()
    config_extra=()
    target_extra=()
    cxx_target_extra=()

    flags="-O2 -g1 -gz=zlib -fno-omit-frame-pointer -gno-column-info -femit-struct-debug-reduced"
    build_nproc=$(nproc)
    install_nproc=$(nproc)

    if git_is_ancestor "$UCTX_FIX" "$hash"; then
      echo "Commit does not require ucontext patch and alternative std flags, continuing..."
    else
      for arch in i386 aarch64 riscv; do
        for f in "libgcc/config/$arch/linux-unwind.h" "gcc/config/$arch/linux-unwind.h"; do
          echo "Patching $f"
          awk '{
                  o=$0
                  gsub(/\<struct[[:space:]]+ucontext\>/,"ucontext_t")
                  if($0!=o) c=1
                  print
                } END{ if(!c) exit 3 }' "$f" >tmp && mv tmp "$f"
        done
      done
      config_env_extra+=(CXX="ccache c++ -std=gnu++98")
      config_env_extra+=(CC="ccache cc -std=gnu89 -Wno-implicit-int -Wno-implicit-function-declaration")
    fi

    if git_is_ancestor "$WINT_FIX" "$hash"; then
      echo "Commit does not require wide-int patch, continuing..."
    else
      f="gcc/wide-int.h"
      echo "Patching $f"
      anchors=(
        '^[[:space:]]*struct[[:space:]]+binary_traits[[:space:]]*<T1,[[:space:]]*T2,[[:space:]]*FLEXIBLE_PRECISION,[[:space:]]*FLEXIBLE_PRECISION>[[:space:]]*$'
        '^[[:space:]]*struct[[:space:]]+binary_traits[[:space:]]*<T1,[[:space:]]*T2,[[:space:]]*FLEXIBLE_PRECISION,[[:space:]]*VAR_PRECISION>[[:space:]]*$'
        '^[[:space:]]*struct[[:space:]]+binary_traits[[:space:]]*<T1,[[:space:]]*T2,[[:space:]]*FLEXIBLE_PRECISION,[[:space:]]*CONST_PRECISION>[[:space:]]*$'
        '^[[:space:]]*struct[[:space:]]+binary_traits[[:space:]]*<T1,[[:space:]]*T2,[[:space:]]*VAR_PRECISION,[[:space:]]*FLEXIBLE_PRECISION>[[:space:]]*$'
        '^[[:space:]]*struct[[:space:]]+binary_traits[[:space:]]*<T1,[[:space:]]*T2,[[:space:]]*CONST_PRECISION,[[:space:]]*FLEXIBLE_PRECISION>[[:space:]]*$'
        '^[[:space:]]*struct[[:space:]]+binary_traits[[:space:]]*<T1,[[:space:]]*T2,[[:space:]]*CONST_PRECISION,[[:space:]]*CONST_PRECISION>[[:space:]]*$'
        '^[[:space:]]*struct[[:space:]]+binary_traits[[:space:]]*<T1,[[:space:]]*T2,[[:space:]]*VAR_PRECISION,[[:space:]]*VAR_PRECISION>[[:space:]]*$'
        '^[[:space:]]*struct[[:space:]]+int_traits[[:space:]]*<[[:space:]]*generic_wide_int[[:space:]]*<storage>[[:space:]]*>[[:space:]]*$'
        '^[[:space:]]*struct[[:space:]]+int_traits[[:space:]]*<[[:space:]]*wide_int_ref_storage[[:space:]]*<SE>[[:space:]]*>[[:space:]]*$'
        '^[[:space:]]*struct[[:space:]]+int_traits[[:space:]]*<[[:space:]]*fixed_wide_int_storage[[:space:]]*<N>[[:space:]]*>[[:space:]]*$'
      )

      for rx in "${anchors[@]}"; do
        tmp="$(mktemp)"
        if awk -v rx="$rx" '
          BEGIN{ tmplE="^[[:space:]]*template[[:space:]]*<>[[:space:]]*$" }
          { sub(/\r$/,""); L[++n]=$0 }
          END{
            hits=0
            for(i=3;i<=n;i++)
              if(L[i] ~ rx && L[i-2] ~ tmplE){ del[i-2]=1; hits++ }
            if(!hits) exit 3
            for(i=1;i<=n;i++) if(!del[i]) print L[i]
          }' "$f" >"$tmp"; then
          mv "$tmp" "$f"
        else
          echo "Warn: no N-2 'template <>' for anchor: $rx" >&2 && rm -f "$tmp"
        fi
      done
    fi

    if git_is_ancestor "$CROSS_FIX" "$hash"; then
      echo "Commit does not require Canadian cross libstdc++ patch, continuing..."
    else
      for f in libstdc++-v3/src/c++17/Makefile.in libstdc++-v3/src/c++17/Makefile.am; do
        echo "Patching $f"
        awk '{
                gsub(/-std=gnu\+\+17[[:space:]]+/, "-std=gnu++17 -nostdinc++ ");
                print
             }' "$f" >tmp && mv tmp "$f"
      done
    fi

    if ! git_is_ancestor "$RISCVHF_FIX" "$hash"; then
      echo "Commit does not require soft-float cleanup, continuing..."
    else
      for f in libgcc/config/riscv/t-softfp32 libgcc/config/riscv/t-softfp64; do
        if [[ -f "$f" ]]; then
          echo "Patching $f"
          awk '{
                 gsub(/([hb]f(sf|df|tf|[hb]f)|(sf|df|tf)[hb]f)/, "")
                 gsub(/fix(unsh)?(h?f|bf)(si|di|ti)/, "")
                 gsub(/float((si|di|ti)|(unsi|undi|unti))(hf|bf)/, "")
                 print
               } ' "$f" >tmp && mv tmp "$f"
        else
          echo "Skipping $f (file not found)"
        fi
      done
    fi

    if ! git_is_ancestor "$TRAIT_FIX" "$hash"; then
      echo "Commit does not require type_traits cleanup, continuing..."
    else
      f="libstdc++-v3/include/std/type_traits"
      echo "Patching $f"
      awk '{
             gsub(/__is_convertible\(_From,[[:space:]]*_To\);/, "is_convertible<_From, _To>::value;");
             print
           }' "$f" >tmp && mv tmp "$f"
    fi

    if ! git_is_ancestor "$DW2_FIX" "$hash"; then
      echo "Commit does not require unwind-dw2 fix, continuing..."
    else
      f="libgcc/unwind-dw2.c"
      echo "Patching $f"
      awk ' /#include <stddef\.h>/ {
             print
             print "#ifndef __LIBGCC_DWARF_CIE_DATA_ALIGNMENT__"
             print "#define __LIBGCC_DWARF_CIE_DATA_ALIGNMENT__ 0"
             print "#endif"
             next
           }
           { print } ' "$f" >tmp && mv tmp "$f"
    fi

    if ! git_is_ancestor "$FLOATN_FIX" "$hash"; then
      echo "Commit does not require future float flags, continuing..."
    else
      cxx_target_extra+=(-U__FLT16_DIG__ -U__FLT32_DIG__ -U__FLT64_DIG__ -U__FLT128_DIG__ -U__BFLT16_DIG__)
      echo "Setting ${cxx_target_extra[*]}"
    fi

    nowarn=(
      "-Wno-switch"
      "-Wno-nonnull"
      "-Wno-use-after-free"
      "-Wno-format-diag"
      "-Wno-cast-function-type"
      "-Wno-maybe-uninitialized"
      "-Wno-implicit-fallthrough"
      "-Wno-expansion-to-defined"
      "-Wno-error=incompatible-pointer-types"
    )

    {

      (
        export CC="ccache ${CROSS_ARCH}-linux-gnu-gcc"
        export CXX="ccache ${CROSS_ARCH}-linux-gnu-g++"
        export AR="ccache ${CROSS_ARCH}-linux-gnu-ar"
        export RANLIB="ccache ${CROSS_ARCH}-linux-gnu-ranlib"
        export LD="ccache ${CROSS_ARCH}-linux-gnu-ld"
        export STRIP="ccache ${CROSS_ARCH}-linux-gnu-strip"

        cd build
        env MAKEINFO=true \
          CFLAGS_FOR_BUILD="$flags ${nowarn[*]}" \
          CXXFLAGS_FOR_BUILD="$flags ${nowarn[*]}" \
          CPPFLAGS_FOR_TARGET="${target_extra[*]}" \
          CFLAGS_FOR_TARGET="-O2 -g1 ${nowarn[*]} ${target_extra[*]}" \
          CXXFLAGS_FOR_TARGET="-O2 -g1 ${nowarn[*]} ${target_extra[*]} ${cxx_target_extra[*]}" \
          CFLAGS="-O2 -g1" \
          CXXFLAGS="-O2 -g1" \
          BOOT_CFLAGS="-O2 -g1" \
          "${config_env_extra[@]}" \
          ../configure \
          --prefix="/opt/$build" \
          --enable-languages="c,c++,fortran" \
          --disable-nls \
          --disable-bootstrap \
          --disable-multilib \
          --disable-libvtv \
          --without-isl \
          --disable-libsanitizer \
          --disable-libstdcxx-pch \
          --host="$CROSS_ARCH-linux-gnu" \
          --target="$CROSS_ARCH-linux-gnu" \
          --with-sysroot="/usr/$CROSS_ARCH-linux-gnu" \
          --with-native-system-header-dir="/include" \
          "${config_extra[@]}"
      )

      time make -C build -j "$build_nproc" \
        all-gcc all-target-libgcc all-target-libstdc++-v3

      time make -C build -j "$install_nproc" \
        install-gcc install-target-libgcc install-target-libstdc++-v3 \
        DESTDIR="$dest_dir"

    } 2>&1 | tee "$install_dir/build.log"

  fi

  filter=()
  case "$CROSS_ARCH" in
  x86_64 | amd64) filter=("-Xbcj" "x86") ;;
  aarch64 | arm64) filter=("-Xbcj" "arm") ;;
  riscv64)
    # XXX requires very new xz: filter=("-Xbcj" "riscv") ;;
    filter=()
    ;;
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
