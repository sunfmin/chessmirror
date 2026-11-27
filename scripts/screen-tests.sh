#!/bin/sh
# The app's screen tests (App/ScreenTests, README.md's "Screen snapshots"), the way the gate runs
# them: the project generated from App/project.yml, the app-hosted ScreenTests bundle on an
# iPhone 17 simulator made for the run and deleted after it, with this worktree's own DerivedData,
# package checkout and result bundle, so two worktrees never build or test over each other.
#
# Usage: scripts/screen-tests.sh [xcodebuild test options...]
#   e.g. scripts/screen-tests.sh -only-testing:ScreenTests/GameScreenTests
# The options are added after the gate's own. An -only-testing among them replaces the gate's
# -only-testing:ScreenTests (xcodebuild runs the union of every -only-testing it is given).
# On a failure it prints the failing tests' messages from the result bundle; the full log is
# kept at .build/screen-tests/xcodebuild.log.
#
# The run is bounded: SCREEN_TESTS_LIMIT seconds (default 660, about twice a cold run's 316s,
# chessmirror#21). A simulator that never launches the test host leaves xcodebuild waiting in
# XCTest's simulator control at ~2% CPU for as long as it is let (60 min, chessmirror#21's warm
# run); past the bound the run is ended and fails saying so, rather than holding a gate.
set -eu
cd "$(dirname "$0")/.."

out=.build/screen-tests
mkdir -p "$out"
log=$out/xcodebuild.log
results=$out/ScreenTests.xcresult
rm -rf "$results"

# A device of the run's own, so two runs on this host (the fast gate, the slow gate on promotion,
# idle work, a worker's measurement) never install over each other's test runner: on one shared
# simulator a second run kills the first's ("Test crashed with signal kill before establishing
# connection", chessmirror#24). It is created, not cloned, from the device type and runtime of the
# one device_name names (iPhone 17, newest iOS): simctl clones only a shut-down device, and the named one
# is often booted by something else. Its name carries this script's pid; the trap shuts it down and
# deletes it on a pass, a failure, a timeout or a signal, and a run killed past its trap (SIGKILL)
# leaves one whose pid is gone, which the next run deletes.
device_name='iPhone 17'
prefix='screen-tests'
devices=$(xcrun simctl list devices --json)
echo "$devices" | jq -r --arg p "$prefix " '.devices[][] | select(.name | startswith($p))
    | "\(.udid) \(.name | ltrimstr($p) | split(" ") | first)"' |
while read -r stale pid; do
    if ! kill -0 "$pid" 2>/dev/null; then
        xcrun simctl shutdown "$stale" 2>/dev/null || true
        xcrun simctl delete "$stale" && echo "screen-tests: deleted $stale, left by a run (pid $pid) that is gone"
    fi
done
runtime=$(echo "$devices" | jq -r --arg name "$device_name" '
    [.devices | to_entries[] | select(.key | test("SimRuntime\\.iOS-")) | .key as $rt | .value[]
     | select(.name == $name and .isAvailable) | $rt] | first // empty')
if [ -z "$runtime" ]; then
    runtime=$(xcrun simctl list runtimes available --json | jq -r '
        [.runtimes[] | select(.platform == "iOS")] | sort_by(.version | split(".") | map(tonumber))
        | last | .identifier // empty')
fi
if [ -z "$runtime" ]; then
    echo "screen-tests: no iOS simulator runtime installed (xcrun simctl list runtimes)" >&2
    exit 1
fi
udid=$(xcrun simctl create "$prefix $$ $device_name" com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$runtime")
child=
cleanup() {
    [ -n "$child" ] && kill "$child" 2>/dev/null
    xcrun simctl shutdown "$udid" 2>/dev/null || true
    xcrun simctl delete "$udid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
# Booted before xcodebuild, so a device that never boots fails here, bounded, not in XCTest.
if ! timeout 180 xcrun simctl bootstatus "$udid" -b > "$out/boot.log" 2>&1; then
    echo "screen-tests: the run's simulator ($udid) did not boot in 180s:" >&2
    tail -5 "$out/boot.log" >&2
    exit 1
fi

only=-only-testing:ScreenTests
for arg in "$@"; do
    case $arg in -only-testing:*) only= ;; esac
done

(cd App && xcodegen generate --quiet)

limit=${SCREEN_TESTS_LIMIT:-660}

set +e
timeout -k 30 "$limit" xcodebuild test \
    -project App/Chessmirror.xcodeproj -scheme Chessmirror \
    -destination "id=$udid" \
    -derivedDataPath "$out/DerivedData" \
    -clonedSourcePackagesDirPath "$out/SourcePackages" \
    -resultBundlePath "$results" \
    ${only:+"$only"} \
    CODE_SIGNING_ALLOWED=NO ARCHS=arm64 \
    "$@" > "$log" 2>&1 &
# In the background and waited for, so a signal to this script runs its trap at once (sh holds a
# trap until a foreground child ends): the trap ends the run and deletes its simulator.
child=$!
wait "$child"
rc=$?
child=
set -e
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "screen-tests: xcodebuild ran past ${limit}s and was ended; its last lines:" >&2
    tail -5 "$log" >&2
    echo "screen-tests: a hang after the build is the run's simulator ($udid) not launching the tests" >&2
    exit 1
fi

# The summary goes through a file: sh's echo would turn the \n inside its strings into newlines.
summary=$out/summary.json
rm -f "$summary"
if [ -d "$results" ]; then
    xcrun xcresulttool get test-results summary --path "$results" --compact > "$summary"
    jq -r '"screen-tests: \(.result): \(.passedTests) passed, \(.failedTests) failed, \(.skippedTests) skipped, \(.expectedFailures) known issues, on \(.devicesAndConfigurations[0].device.deviceName // "?") (\(.devicesAndConfigurations[0].device.osVersion // "?"))"' "$summary"
    jq -r '.testFailures[]? | "  \(.testIdentifierString): \(.failureText)"' "$summary"
fi
if [ "$rc" -ne 0 ]; then
    # A build that failed leaves no tests to name: the compiler's errors are in the log.
    if [ ! -s "$summary" ] || [ "$(jq '.failedTests' "$summary")" = 0 ]; then
        grep -E 'error:|BUILD FAILED|TEST FAILED|Testing failed' "$log" | head -40 >&2
    fi
    echo "screen-tests: failed (exit $rc); full log: $log" >&2
fi
exit "$rc"
