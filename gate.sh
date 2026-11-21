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
#
# What failed is printed again last: a reader who keeps only the tail of this output would
# otherwise see "1 issue" and not which test it was.
log=$(mktemp)
status=0
swift test -c release --no-parallel > "$log" 2>&1 || status=$?
cat "$log"
if [ "$status" -ne 0 ]; then
    echo "gate: the tests failed; what failed:" >&2
    grep -E '✘|recorded an issue|error:' "$log" | grep -v '^✘ Test run with' | head -40 >&2
    rm -f "$log"
    exit "$status"
fi
rm -f "$log"

# The armv8 engine is what an A12 runs: no dotprod instruction may reach it (docs/adr/0052).
scripts/dotprod-confined.sh \
    "$(swift build -c release --show-bin-path)/ChessmirrorKitTests.xctest/Contents/MacOS/ChessmirrorKitTests"
