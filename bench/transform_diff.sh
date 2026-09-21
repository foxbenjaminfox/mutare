#!/bin/sh
# Diff what the transform writes at BASE_REV against the working tree, over one corpus.
# Exits 0 when nothing moved. See bench/README.md "Transform differential".
#
#   bench/transform_diff.sh BASE_REV [WORK_DIR]
set -eu

base_rev=${1:?usage: bench/transform_diff.sh BASE_REV [WORK_DIR]}
root=$(git rev-parse --show-toplevel)
work=${2:-$(mktemp -d)}
mkdir -p "$work"
export MIX_ENV=test

cd "$root"
mix run bench/transform_snapshot.exs corpus "$work/corpus.bin"
mix run bench/transform_snapshot.exs snapshot "$work/corpus.bin" "$work/new"

# The base is an exported tree, not a worktree: nothing in the repository's state changes.
# It borrows this checkout's deps and a copy of its build, so only changed modules recompile.
rm -rf "$work/base"
mkdir -p "$work/base"
git archive "$base_rev" | tar -x -C "$work/base"
ln -s "$root/deps" "$work/base/deps"
cp -a "$root/_build" "$work/base/_build"
cp "$root/bench/transform_snapshot.exs" "$work/base/bench/transform_snapshot.exs"

(cd "$work/base" && mix run bench/transform_snapshot.exs snapshot "$work/corpus.bin" "$work/old")

if diff -r "$work/old" "$work/new" > "$work/transform.diff"; then
  echo "identical: $(ls "$work/new" | wc -l) snapshots, $base_rev vs working tree"
else
  echo "differs: see $work/transform.diff"
  diffstat "$work/transform.diff" 2>/dev/null | tail -1 || true
  exit 1
fi
