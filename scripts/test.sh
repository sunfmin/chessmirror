#!/bin/sh
# The package's tests, the way the gate runs them (slimfit.toml's test_command; README.md,
# "Build and test"): release, as two runs of the one test bundle.
#
# 1. The footprint checks, one at a time, with nothing beside them. They read the test process's
#    footprint (Tests/ChessmirrorKitTests/Footprint.swift), and a test running in the same
#    process would be counted in it.
# 2. Everything else, side by side (Swift Testing's default), with CHESSMIRROR_TESTS_SIDE_BY_SIDE
#    set: a footprint read there records an issue, so a footprint check left out of $alone fails.
#
# Usage: scripts/test.sh [--xunit-output <file>] [swift test options...]
# The options go to both runs (the gate passes --enable-code-coverage); the xunit reports of the
# two runs are merged into the one Swift Testing writes for <file> (<name>-swift-testing.xml).
# Exits non-zero when either run fails; both always run.
set -u
cd "$(dirname "$0")/.."

# The suites that read the footprint: the only tests that run alone.
alone='RecognitionMemoryTests'

xunit=
if [ "${1:-}" = --xunit-output ]; then
    xunit=$2
    shift 2
fi
if [ -n "$xunit" ]; then
    parts=$(mktemp -d)
    alone_xunit="--xunit-output $parts/alone.xml"
    beside_xunit="--xunit-output $parts/beside.xml"
else
    alone_xunit=
    beside_xunit=
fi

# shellcheck disable=SC2086 # the xunit flag is two words or none
swift test -c release --no-parallel --filter "$alone" $alone_xunit "$@"
alone_rc=$?
# Each `swift test` empties the coverage directory before it runs, so the first run's counters
# are kept aside and put back: the gate's one coverage report is of both runs.
codecov=.build/release/codecov
kept=$(mktemp -d)
cp "$codecov"/*.profraw "$kept" 2>/dev/null
# shellcheck disable=SC2086
CHESSMIRROR_TESTS_SIDE_BY_SIDE=1 swift test -c release --skip "$alone" $beside_xunit "$@"
beside_rc=$?
cp "$kept"/*.profraw "$codecov" 2>/dev/null
rm -rf "$kept"

if [ -n "$xunit" ]; then
    # One <testsuite> per run, as Swift Testing writes it; the merged one sums their counts.
    awk '
        /<testsuite / {
            for (i = 1; i <= NF; i++) if (split($i, kv, "=") == 2) {
                gsub(/[">]/, "", kv[2]); if (kv[1] ~ /^(tests|failures|errors|skipped|time)$/) sum[kv[1]] += kv[2]
            }
            inside = 1; next
        }
        /<\/testsuite>/ { inside = 0; next }
        inside { cases = cases $0 "\n" }
        END {
            print "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            print "<testsuites>"
            printf "<testsuite name=\"TestResults\" errors=\"%d\" tests=\"%d\" failures=\"%d\" skipped=\"%d\" time=\"%s\">\n", sum["errors"], sum["tests"], sum["failures"], sum["skipped"], sum["time"]
            printf "%s", cases
            print "</testsuite>"
            print "</testsuites>"
        }
    ' "$parts/alone-swift-testing.xml" "$parts/beside-swift-testing.xml" > "${xunit%.xml}-swift-testing.xml"
    rm -rf "$parts"
fi

[ "$alone_rc" -eq 0 ] && [ "$beside_rc" -eq 0 ]
