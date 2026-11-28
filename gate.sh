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

# The documents (docfit.toml): each registered under one kind, within its budget, its pointers
# there, and no file citing this host's tracker anew, against .docfit/baseline.json. First, as
# it takes well under a second.
docfit check

# The tests, once, through slimfit (slimfit.toml): release, as scripts/test.sh runs them and
# README.md's "Build and test" says (the footprint checks alone, since they measure the test
# process; the rest side by side), measured against .slimfit/baseline.json.
slimfit check

# Each stand-in answers every case of its contract (truefit.toml); none yet: chessmirror drives
# no program from a command line (see truefit.toml), so this holds the first one declared.
truefit contract >/dev/null || truefit contract

# The armv8 engine is what an A12 runs: no dotprod instruction may reach it (docs/adr/0052).
scripts/dotprod-confined.sh \
    "$(swift build -c release --show-bin-path)/ChessmirrorKitTests.xctest/Contents/MacOS/ChessmirrorKitTests"

# The app's screen tests (App/ScreenTests), which only an app-hosted bundle on a simulator can
# run: no `swift test` reaches them, and a landing that broke every screen would otherwise land.
# Bounded and explained in scripts/screen-tests.sh; why they are in this one gate, factorium.toml.
scripts/screen-tests.sh
