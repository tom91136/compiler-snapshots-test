#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${REPO:?Set REPO to 'gcc' or 'llvm'}"
: "${BAD:?Set BAD to a known bad commit hash}"

GOOD1="${GOOD1-}"
GOOD2="${GOOD2-}"

if [[ -z "$GOOD1" && -z "$GOOD2" ]]; then
  echo "At least one of GOOD1 (a known good before BAD) or GOOD2 (a known good after BAD) required." >&2 && exit 2
fi

case "$REPO" in
gcc)
  remote="https://github.com/gcc-mirror/gcc.git"
  repo=gcc
  ;;
llvm)
  remote="https://github.com/llvm/llvm-project.git"
  repo=llvm
  ;;
*)
  echo "Unknown repo $REPO, must be either llvm or gcc" >&2
  exit 2
  ;;
esac

reset() {

  {
    git reset --hard HEAD
    git clean -ffdx
    git bisect reset
  } &>/dev/null || true
}

run-bisect() {
  # shellcheck disable=SC2016
  PHASE="$1" REPO="$REPO" SCRIPT_DIR="$script_dir" git bisect run bash -c '
       set -uo pipefail
       commit=$(git rev-parse --short HEAD || echo unknown)
       ts=$(date +%Y%m%d-%H%M%S)
       logfile="$SCRIPT_DIR/build-${PHASE}-${ts}-${commit}.log"

       echo ">>> checking ${PHASE}: $commit ($ts)"
       SECONDS=0
       set +e
       CROSS_ARCH=riscv64 "$SCRIPT_DIR/action_build_${REPO}_cross.sh" "$@" &> "$logfile"
       rc=$?
       set -e
       dur=$SECONDS
       printf "<<< duration=%ss, rc=%s\n" "$dur" "$rc"
       [ "$PHASE" = first-fixed ] && rc=$(( rc == 0 ? 1 : 0 ))
       git reset --hard HEAD
       git clean -ffdx
       exit "$rc"
    ' _

}

(
  cd /
  if [ ! -d "/$repo/.git" ]; then
    git clone "$remote" "$repo" --no-recurse-submodules --filter=blob:none --progress
  fi
  cd "/$repo"
  reset

  if [[ -n "$GOOD1" ]]; then
    git bisect start --term-old=fixed --term-new=broken "$BAD" "$GOOD1"
    run-bisect first-bad
    echo "## first bad bisect result ##"
    git bisect log || true
    # Use HEAD as the result of the concluded bisect
    first_bad="$(git rev-parse --verify HEAD || true)"
    echo "## first-bad=$first_bad"
    reset

    if [[ -z "$first_bad" ]]; then
      echo "Error: Could not determine first bad commit" >&2
      exit 1
    fi
  else
    first_bad="$BAD"
  fi

  if [[ -z "$GOOD2" ]]; then
    echo "## broken-start (first-bad) = $first_bad"
    echo "Done"
    exit 0
  fi

  # ---- Phase 2: find first fixed (only if GOOD2 is set) ----
  git bisect start --term-old=broken --term-new=fixed "$GOOD2" "$first_bad"
  run-bisect first-fixed
  echo "## first fixed bisect result ##"
  git bisect log || true
  first_fixed="$(git rev-parse --verify HEAD || true)"
  echo "## first-fixed=$first_fixed"

  if [[ -z "$first_fixed" ]]; then
    echo "Error: Could not determine first fixed commit" >&2
    exit 1
  fi

  if ! git merge-base --is-ancestor "$first_bad" "$first_fixed" 2>/dev/null; then
    echo "Error: first_fixed ($first_fixed) is not reachable from first_bad ($first_bad)" >&2
    exit 1
  fi

  last_bad=$(
    git rev-list --ancestry-path --reverse "$first_bad..$first_fixed" |
      tail -n 2 | head -n 1
  )
  last_bad=${last_bad:-$first_bad}
  echo "## last-bad=$last_bad"
  echo "## broken-range: $first_bad..$last_bad"
  commit_count=$(git rev-list --count "$first_bad..$last_bad")
  echo "## commits in broken range: $commit_count"

  reset
  echo "Done"

)
