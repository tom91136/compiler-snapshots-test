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

git_is_ancestor() { git merge-base --is-ancestor "$1" "$2"; }

for build in "${builds_array[@]}"; do
  dest_dir="/tmp/$build"
  dest_archive="/host/$build.squashfs"

  build_no_arch="${build%.*}"
  builds_json="/host/builds.json"
  [ -f "/host/builds-gcc.json" ] && builds_json="/host/builds-gcc.json"
  hash=$(jq -r ".\"$build_no_arch\" | .hash" "$builds_json")

  # Commits before 71b55d45e4304f5e2e98ac30473c581f58fc486b requires an old glibc for asan to work
  # See https://gcc.gnu.org/bugzilla/show_bug.cgi?id=113181
  SAN_FIX="71b55d45e4304f5e2e98ac30473c581f58fc486b"

  # Commits before 883312dc79806f513275b72502231c751c14ff72 has incompatibilities with newer (>=2.28?) glibc
  # see https://github.com/gcc-mirror/gcc/commit/883312dc79806f513275b72502231c751c14ff72
  # We also use alternative flags as C/C++ defaults at the time is different
  UCTX_FIX="883312dc79806f513275b72502231c751c14ff72"

  # Commits before df2a7a38f6f49656f08e0c34d7856b2709a9e5b6 has busted syntax that cases
  # "too many template-parameter-lists"
  # see https://github.com/gcc-mirror/gcc/commit/df2a7a38f6f49656f08e0c34d7856b2709a9e5b6
  WINT_FIX="df2a7a38f6f49656f08e0c34d7856b2709a9e5b6"

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

    extra=()
    flags="-O2 -g1 -gz=zlib -fno-omit-frame-pointer -gno-column-info -femit-struct-debug-reduced"

    if git_is_ancestor "$SAN_FIX" "$hash"; then
      echo "Commit does not require disabling ASAN support, continuing..."
    else
      extra+=("--disable-libsanitizer")
      echo "Disabling ASAN support"
    fi

    if git_is_ancestor "$UCTX_FIX" "$hash"; then
      echo "Commit does not require ucontext patch and alternative std flags, continuing..."
    else
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

  filter=()
  case "$(uname -m)" in
  x86_64 | amd64) filter=("-Xbcj" "x86") ;;
  aarch64 | arm64) filter=("-Xbcj" "arm") ;;
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
