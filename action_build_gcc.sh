#!/usr/bin/env bash

set -euo pipefail

set +u # scl_source has unbound vars, disable check
source scl_source enable gcc-toolset-14 || true
set -u

export PATH="/usr/lib64/ccache${PATH:+:${PATH}}"

ccache --set-config=sloppiness=locale,time_macros
ccache -M 10G
ccache -s

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

build_bison() {
  local bison_ver=2.7

  wget "https://www.mirrorservice.org/sites/ftp.gnu.org/gnu/bison/bison-${bison_ver}.tar.xz"
  tar -xf "bison-${bison_ver}.tar.xz"

  (
    cd "bison-${bison_ver}"
    git apply <<'EOF'
--- a/lib/stdio-impl.h
+++ b/lib/stdio-impl.h
@@ -18,6 +18,12 @@
    the same implementation of stdio extension API, except that some fields
    have different naming conventions, or their access requires some casts.  */

+/* Glibc 2.28 made _IO_IN_BACKUP private.  For now, work around this
+   problem by defining it ourselves.  FIXME: Do not rely on glibc
+   internals.  */
+#if !defined _IO_IN_BACKUP && defined _IO_EOF_SEEN
+# define _IO_IN_BACKUP 0x100
+#endif

 /* BSD stdio derived implementations.  */

--- a/lib/fseterr.c
+++ b/lib/fseterr.c
@@ -29,7 +29,7 @@
   /* Most systems provide FILE as a struct and the necessary bitmask in
      <stdio.h>, because they need it for implementing getc() and putc() as
      fast macros.  */
-#if defined _IO_ftrylockfile || __GNU_LIBRARY__ == 1 /* GNU libc, BeOS, Haiku, Linux libc5 */
+#if defined _IO_EOF_SEEN || __GNU_LIBRARY__ == 1 /* GNU libc, BeOS, Haiku, Linux libc5 */
   fp->_flags |= _IO_ERR_SEEN;
 #elif defined __sferror || defined __DragonFly__ /* FreeBSD, NetBSD, OpenBSD, DragonFly, Mac OS X, Cygwin */
   fp_->_flags |= __SERR;
EOF

    mkdir build && cd build
    ../configure --prefix="$PWD/dist"
    make -j "$(nproc)" && make install
  )

  export PATH="$PWD/bison-${bison_ver}/build/dist/bin:$PATH"
  bison --version
}

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
    builds_json="/host/builds-gcc-$(uname -m).json"
    hash=$(jq -r ".\"$build_no_arch\" | .hash" "$builds_json")
  else
    hash="$build"
  fi

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

  # GCC added _FloatN support half way during the GCC 7 cycle, Glibc only has guards for GCC 7 so
  # the first half of the 7.x branch won't build due to missing FloatN types, which was added in
  # the following commit
  FLTN_FIX="c65699efcce48d68ef57ab3ce7fc5420fac5cbf9"

  # Fixes SEGV in GCC 4.6~4.7 series, see
  # https://github.com/gcc-mirror/gcc/commit/42001763ab5dc5d784f5af3599c7ecf98566fdad
  SEGV_FIX="42001763ab5dc5d784f5af3599c7ecf98566fdad"

  # Fixes pair escaping lexical scope, see
  # https://github.com/gcc-mirror/gcc/commit/6e3f8a30262f988bd062a6662c0b0c61bd9e884a
  SPAIR_FIX="6e3f8a30262f988bd062a6662c0b0c61bd9e884a"

  # Lexer has a alignment bug doing unsafe casts, only triggers on ppc64le
  # First fixed in GCC 8.x, see https://lists.busybox.net/pipermail/buildroot/2018-July/214807.html
  PPCLEX_FIX="a3a821c903c9fa2288712d31da2038d0297babcb"

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
      origin "$hash" "$SAN_FIX" "$UCTX_FIX" "$WINT_FIX" "$FLTN_FIX" "$SEGV_FIX" "$SPAIR_FIX"
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

    if [[ -x contrib/download_prerequisites ]]; then
      time ./contrib/download_prerequisites --no-isl --no-verify
    else
      MPFR=mpfr-2.4.2
      GMP=gmp-4.3.2
      MPC=mpc-0.8.1
      wget "https://gcc.gnu.org/pub/gcc/infrastructure/$MPFR.tar.bz2"
      tar xjf "$MPFR.tar.bz2"
      ln -sf "$MPFR" mpfr
      wget "https://gcc.gnu.org/pub/gcc/infrastructure/$GMP.tar.bz2"
      tar xjf "$GMP".tar.bz2
      ln -sf "$GMP" gmp
      wget "https://gcc.gnu.org/pub/gcc/infrastructure/$MPC.tar.gz"
      tar xzf "$MPC.tar.gz"
      ln -sf "$MPC" mpc

      rm -f "$MPFR.tar.bz2" "$GMP.tar.bz2" "$MPC.tar.gz"
      :
    fi

    config_env_extra=()
    config_extra=()
    target_extra=()

    if [[ "$major" == "7" ]]; then
      if git_is_ancestor "$FLTN_FIX" "$hash"; then
        echo "Commit does not require spoofing xgcc version"
      else
        echo "Spoofing xgcc to version 6"
        target_extra+=("-U__GNUC__" "-D__GNUC__=6")
      fi
    fi

    if ((major < 4 || (major == 4 && minor <= 0))); then
      # GCC 4.0 and older needs Bison <= 2
      build_bison
    fi

    fortran_target="fortran"
    if ((major < 4 || (major == 4 && minor <= 2))); then
      fortran_target="f95"
      root=$PWD
      config_extra+=("--with-mpfr=$root/mpfr/build/dist")
      config_extra+=("--with-gmp=$root/gmp/build/dist")
      for lib in gmp mpfr; do
        (
          cd "$root/$lib"
          mkdir build && cd build
          CXX="ccache c++ -std=gnu++98 -w" \
            CC="ccache cc -std=gnu89 -w -Wno-implicit-int -Wno-implicit-function-declaration" \
            ../configure --prefix="$PWD/dist" --disable-shared --with-gmp-build="$root/gmp/build"
          make -j "$(nproc)" && make install
        )
      done
    fi

    old_dir_format=false
    if [[ -f gcc/config/i386/linux-unwind.h ]]; then
      old_dir_format=true
    fi

    flags="-O2 -g1 -gz=zlib -fno-omit-frame-pointer -gno-column-info -femit-struct-debug-reduced"
    build_nproc=$(nproc)
    install_nproc=$(nproc)

    if [[ "$old_dir_format" == true ]]; then
      flags="-O2 -g0"
      install_nproc=1
    fi

    if git_is_ancestor "$SAN_FIX" "$hash"; then
      echo "Commit does not require disabling ASAN support, continuing..."
    else
      config_extra+=("--disable-libsanitizer")
      echo "Disabling ASAN support"
    fi

    if git_is_ancestor "$SEGV_FIX" "$hash"; then
      echo "Commit does not require patching ira-int.h, continuing..."
    else
      f="gcc/ira-int.h"
      echo "Patching $f"
      awk 'function ns(s){gsub(/[[:space:]]/,"",s);return s}
        { if(ns($0)=="*o=ALLOCNO_OBJECT(a,i->n);"){getline l;if(ns(l)=="returni->n++<ALLOCNO_NUM_OBJECTS(a);"){
        print "  int n = i->n++;"
        print "  if (n < ALLOCNO_NUM_OBJECTS (a))"
        print "    {"
        print "      *o = ALLOCNO_OBJECT (a, n);"
        print "      return true;"
        print "    }"
        print "  return false;";next} else{print $0;print l;next}} print }' "$f" >tmp && mv tmp "$f"
    fi

    if git_is_ancestor "$SPAIR_FIX" "$hash"; then
      echo "Commit does not require patching gengtype.c, continuing..."
    else
      f="gcc/gengtype.c"
      echo "Patching $f"
      awk '
        { L[++n]=$0 }
        END{
          for(i=1;i<=n;i++) if (L[i] ~ /struct[[:space:]]+pair[[:space:]]+newv;/){t=i;break}
          if(!t){ for(i=1;i<=n;i++) print L[i]; exit }
          for(i=t-1;i>=1;i--) if (index(L[i],"v && type == v->type")){a=i;break}
          if(!a){ for(i=1;i<=n;i++) print L[i]; exit }
          s=L[t]
          for(i=1;i<=n;i++){ if(i==t) continue; print L[i]; if(i==a-1) print s }
        }' "$f" >tmp && mv tmp "$f"
    fi

    if git_is_ancestor "$PPCLEX_FIX" "$hash"; then
      echo "Commit does not require patching lex.c, continuing..."
    else
      f="libcpp/lex.c"
      echo "Patching $f"
      awk '{
              gsub(/data = \*\(\(const vc \*\)s\);/, "data = __builtin_vec_vsx_ld (0, s);");
              print
           }' "$f" >tmp && mv tmp "$f"
    fi

    if git_is_ancestor "$UCTX_FIX" "$hash"; then
      echo "Commit does not require ucontext patch and alternative std flags, continuing..."
    else
      for arch in i386 aarch64; do
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
        cd build
        env MAKEINFO=true \
          CXX="ccache c++" \
          CC="ccache cc" \
          CFLAGS_FOR_BUILD="$flags ${nowarn[*]}" \
          CXXFLAGS_FOR_BUILD="$flags ${nowarn[*]}" \
          CFLAGS_FOR_TARGET="-O2 -g1 ${target_extra[*]}" \
          CXXFLAGS_FOR_TARGET="-O2 -g1 ${target_extra[*]}" \
          CFLAGS="-O2 -g1" \
          CXXFLAGS="-O2 -g1" \
          BOOT_CFLAGS="-O2 -g1" \
          "${config_env_extra[@]}" \
          ../configure \
          --prefix="/opt/$build" \
          --enable-languages="c,c++,$fortran_target" \
          --disable-nls \
          --disable-bootstrap \
          --disable-multilib \
          --disable-libvtv \
          --without-isl \
          "${config_extra[@]}"
      )
      time make --silent -C build -j "$build_nproc"
      time make --silent -C build -j "$install_nproc" install DESTDIR="$dest_dir"

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
