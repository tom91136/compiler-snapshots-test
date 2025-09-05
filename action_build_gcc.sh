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

if [ ! -d gcc/.git ]; then
  rm -rf gcc
  git init gcc
fi
cd gcc
if git remote get-url origin &>/dev/null; then
  git remote set-url origin https://github.com/gcc-mirror/gcc.git
else
  git remote add origin https://github.com/gcc-mirror/gcc.git
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


for build in "${builds_array[@]}"; do
  dest_dir="/tmp/$build"
  dest_archive="/host/$build.tar.xz"

  build_no_arch="${build%.*}"
  builds_json="/host/builds.json"
  [ -f "/host/builds-gcc.json" ] && builds_json="/host/builds-gcc.json"
  hash=$(jq -r ".\"$build_no_arch\" | .hash" "$builds_json")

  # Commits before d5ca27efb4b69f8fdf38240ad62cc1af30a30f77 requires an old glibc for asan to work
  # See https://gcc.gnu.org/bugzilla/show_bug.cgi?id=113181
  SAN_FIX=d5ca27efb4b69f8fdf38240ad62cc1af30a30f77


  # Commits before 1a8be74612e0ab0f149f7f843603a8b48ae2843f has incompatibilities with newer (>=2.28?) glibc
  # see https://github.com/gcc-mirror/gcc/commit/1a8be74612e0ab0f149f7f843603a8b48ae2843f
  # We also use alternative flags as C/C++ defaults at the time is different
  UCTX_FIX="1a8be74612e0ab0f149f7f843603a8b48ae2843f"

  # Commits before d68244487a4a370c727befee4dc8488e4794a2db has busted syntax that cases 
  # "too many template-parameter-lists" 
  # see https://github.com/gcc-mirror/gcc/commit/d68244487a4a370c727befee4dc8488e4794a2db
  WINT_FIX="d68244487a4a370c727befee4dc8488e4794a2db"

  echo "Build   : $build"
  echo "Commit  : $hash"

  git -c protocol.version=2 fetch \
    --quiet \
    --no-tags \
    --prune \
    --progress \
    --no-recurse-submodules \
    --filter=blob:none \
    origin "$hash" "$SAN_FIX" "$UCTX_FIX" "$WINT_FIX"

  git checkout -f -q "$hash"
  git clean -fdx


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

    flags="-O2 -g1 -gz=zlib -fno-omit-frame-pointer -gno-column-info -femit-struct-debug-reduced"

    if git_is_ancestor "$SAN_FIX" "$hash"; then
      extra+=("--disable-libsanitizer")
    else
      echo "Commit does not require disabling ASAN support, continuing..."
    fi

    if git_is_ancestor "$UCTX_FIX" "$hash"; then
      for arch in i386 aarch64; do
        f="libgcc/config/$arch/linux-unwind.h"
        echo "Patching $f"
        awk '{
          o=$0
          gsub(/\<struct[[:space:]]+ucontext\>/,"ucontext_t")
          if($0!=o) c=1
          print
        } END{ if(!c) exit 3 }' "$f" >tmp && mv tmp "$f"
      done
      extra+=(CXXFLAGS_FOR_TARGET="-O2 -g1" CFLAGS_FOR_TARGET="-O2 -g1")
      extra+=(CXX="ccache c++ -std=gnu++98")
      extra+=(CC="ccache cc -std=gnu89 -Wno-implicit-int -Wno-implicit-function-declaration")
    else
      echo "Commit does not require ucontext patch and alternative std flags, continuing..."
    fi

    if git_is_ancestor "$WINT_FIX" "$hash"; then
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
        awk -v rx="$rx" '
          BEGIN{ tmplE="^[[:space:]]*template[[:space:]]*<>[[:space:]]*$" }
          { sub(/\r$/,""); L[++n]=$0 }
          END{
            hits=0
            for(i=3;i<=n;i++)
              if(L[i] ~ rx && L[i-2] ~ tmplE){ del[i-2]=1; hits++ }
            if(!hits) exit 3
            for(i=1;i<=n;i++) if(!del[i]) print L[i]
          }' "$f" >"$tmp" || { echo "Failed: no N-2 'template <>' for anchor: $rx" >&2; rm -f "$tmp"; exit 1; }
        mv "$tmp" "$f"
      done
    else
      echo "Commit does not require wide-int patch, continuing..."
    fi

    {

    time ./contrib/download_prerequisites --no-isl --no-verify
    (
      cd build
      ../configure \
        CXX="ccache c++" \
        CC="ccache cc" \
        CXXFLAGS="$flags" \
        CFLAGS="$flags -Wno-error=incompatible-pointer-types -Wno-maybe-uninitialized" \
        --prefix="/opt/$build" \
        --enable-languages=c,c++,fortran \
        --disable-nls \
        --disable-bootstrap \
        --disable-multilib \
        --disable-libvtv \
        --without-isl \
        "${extra[@]}"
    )
    time make --silent -C build -j "$(nproc)"
    time make --silent -C build -j "$(nproc)" install DESTDIR="$dest_dir"

    } 2>&1 | tee "$install_dir/build.log"

  fi

  time XZ_OPT='-T0 -9e --block-size=16MiB' tar cfJ "$dest_archive" --checkpoint=.1000 --totals --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -C "$dest_dir" .

  echo ""
  du -sh "$dest_dir"
  du -sh "$dest_archive"

  rm -rf "$dest_dir"
  ccache -s

done
