#!/bin/sh
# Would today's generated suites have caught a past defect? Reverse one fix's `lib/` changes
# on top of the working tree and run them. See bench/README.md "Replaying fixes".
#
#   bench/replay_fix.sh WORK_DIR FIX_COMMIT...
#
# Prints one line per commit:
#   caught        the suites fail with the fix reversed
#   missed        they pass: a generator dimension is missing
#   unrevertable  later work rewrote the fixed lines, so the fix cannot be reversed alone
#   unbuildable   the reversed lib does not compile
# Only the fix is reversed. Checking out the whole pre-fix `lib/` would also drop every
# later fix, and the suites would fail for those instead.
set -u

work=${1:?usage: bench/replay_fix.sh WORK_DIR FIX_COMMIT...}
shift
root=$(git rev-parse --show-toplevel)
suites="test/mutare/transform_source_patch_property_test.exs test/mutare/transform_clean_source_patch_property_test.exs"
mkdir -p "$work"
export MIX_ENV=test

for fix in "$@"; do
  short=$(git rev-parse --short "$fix")
  tree="$work/$short"
  rm -rf "$tree"
  mkdir -p "$tree"

  # The working tree is copied, not HEAD, so a generator dimension can be tried uncommitted.
  (cd "$root" && tar -c --exclude=./_build --exclude=./deps --exclude=./.git --exclude=./tmp --exclude=./doc .) | tar -x -C "$tree"
  git -C "$root" diff "$fix~1" "$fix" -- lib > "$tree/fix.diff"
  summary=""

  if ! (cd "$tree" && patch -R -p1 --no-backup-if-mismatch -s -f < fix.diff > patch.log 2>&1); then
    verdict=unrevertable
  else
    ln -s "$root/deps" "$tree/deps"
    cp -a "$root/_build" "$tree/_build"

    if ! (cd "$tree" && mix compile > compile.log 2>&1); then
      verdict=unbuildable
    elif (cd "$tree" && mix test --only property $suites > test.log 2>&1); then
      verdict=missed
    else
      verdict=caught
    fi

    summary=$(grep -E "^[0-9]+ (properties|tests)" "$tree/test.log" 2>/dev/null | tail -1)
    rm -rf "$tree/_build"
  fi

  printf '%s  %-12s %s  [%s]\n' "$short" "$verdict" "$(git log -1 --format=%s "$fix")" "$summary"
done
