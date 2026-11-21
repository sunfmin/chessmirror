#!/bin/sh
# The gate: what must pass before anything lands. factorium.toml's [gate] names it.
set -eu
cd "$(dirname "$0")"

# The engine tests load the two real NNUE nets, which Git LFS carries (.gitattributes). A clone
# made without `git lfs install` has pointers in their place, and the tests fail far from why.
for net in Resources/Nets/*.nnue; do
    if head -c 40 "$net" | grep -q '^version https://git-lfs'; then
        echo "gate: $net is a Git LFS pointer, not the net: git lfs install && git lfs pull" >&2
        exit 1
    fi
done

# Release and one test at a time, as README.md's "Build and test" says: the recognition memory
# checks measure the test process's footprint, so tests running beside them would be counted.
swift test -c release --no-parallel
