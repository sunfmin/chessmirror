#!/bin/sh
# The app's screen tests (App/ScreenTests, README.md's "Screen snapshots"), the way the gate runs
# them: the project generated from App/project.yml, the app-hosted ScreenTests bundle on an
# iPhone 17 simulator addressed by id, with this worktree's own DerivedData, package checkout and
# result bundle, so two worktrees never build over each other.
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

# The device README names, picked from what is installed rather than by a name xcodebuild has to
# resolve, and created on the newest iOS runtime when this machine has none.
device_name='iPhone 17'
udid=$(xcrun simctl list devices available --json | jq -r --arg name "$device_name" '
    [.devices | to_entries[] | select(.key | test("SimRuntime\\.iOS-")) | .value[]
     | select(.name == $name)] | first | .udid // empty')
if [ -z "$udid" ]; then
    runtime=$(xcrun simctl list runtimes available --json | jq -r '
        [.runtimes[] | select(.platform == "iOS")] | sort_by(.version | split(".") | map(tonumber))
        | last | .identifier // empty')
    if [ -z "$runtime" ]; then
        echo "screen-tests: no iOS simulator runtime installed (xcrun simctl list runtimes)" >&2
        exit 1
    fi
    udid=$(xcrun simctl create "$device_name" com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$runtime")
    echo "screen-tests: created $device_name ($udid) on $runtime"
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
    "$@" > "$log" 2>&1
rc=$?
set -e
if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "screen-tests: xcodebuild ran past ${limit}s and was ended; its last lines:" >&2
    tail -5 "$log" >&2
    echo "screen-tests: a hang after the build is the simulator ($udid) not launching the tests:" >&2
    echo "  xcrun simctl shutdown $udid, when no other run is using it, and run again" >&2
    exit 1
fi

if [ -d "$results" ]; then
    summary=$(xcrun xcresulttool get test-results summary --path "$results" --compact)
    echo "$summary" | jq -r '"screen-tests: \(.result): \(.passedTests) passed, \(.failedTests) failed, \(.skippedTests) skipped, \(.expectedFailures) known issues, on \(.devicesAndConfigurations[0].device.deviceName // "?") (\(.devicesAndConfigurations[0].device.osVersion // "?"))"'
    echo "$summary" | jq -r '.testFailures[]? | "  \(.testIdentifierString): \(.failureText)"'
fi
if [ "$rc" -ne 0 ]; then
    # A build that failed leaves no tests to name: the compiler's errors are in the log.
    if [ ! -d "$results" ] || [ "$(echo "$summary" | jq '.failedTests')" = 0 ]; then
        grep -E 'error:|BUILD FAILED|TEST FAILED|Testing failed' "$log" | head -40 >&2
    fi
    echo "screen-tests: failed (exit $rc); full log: $log" >&2
fi
exit "$rc"
