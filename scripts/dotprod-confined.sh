#!/bin/sh
# Usage: scripts/dotprod-confined.sh <linked binary>
#
# The engine is linked in twice, and only the copy in `namespace StockfishDotprod` may use the
# dot-product instructions: the armv8 copy is what an A12 runs, and there one `sdot` or `udot`
# is an illegal instruction the moment the engine looks at a board (docs/adr/0052).
#
# Read from the linked binary rather than the object files, so that a shared function the linker
# happened to take from the dotprod objects — a libc++ template both copies instantiate — is
# caught as surely as a build setting that turned dotprod on for the armv8 copy. And the dotprod
# copy must have some: a check that finds nothing because nothing was built with dotprod is not
# a check.
set -eu
binary="$1"
if [ ! -f "$binary" ]; then
    echo "dotprod-confined: $binary does not exist — nothing was checked" >&2
    exit 1
fi

found=$(objdump -d --no-show-raw-insn "$binary" \
    | awk '/^[0-9a-f]+ <.*>:$/ { fn = $2; next } /\t(sdot|udot)[.\t ]/ { n[fn]++ } END { for (f in n) print f }' \
    | c++filt)

if [ -z "$found" ]; then
    echo "dotprod-confined: no sdot/udot anywhere in $binary — the dotprod build is not using dotprod" >&2
    exit 1
fi
stray=$(printf '%s\n' "$found" | grep -v 'StockfishDotprod::' || true)
if [ -n "$stray" ]; then
    echo "dotprod-confined: sdot/udot outside the dotprod build in $binary:" >&2
    printf '%s\n' "$stray" >&2
    exit 1
fi
echo "dotprod-confined: $(printf '%s\n' "$found" | wc -l | tr -d ' ') functions use dotprod, all in StockfishDotprod"
