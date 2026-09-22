#!/bin/bash
# Runs the performance baselines (PRD §10) on the million-row fixture, in a release build.
#
#   Scripts/perf.sh          the engine's baselines (opening, paging, sorting, the tracker's scan)
#   Scripts/perf.sh app      the same store through the app: open to first rows, and a frame of scrolling
#
# The fixture is generated once into Fixtures/large and reused. DABBI_LARGE_ROWS overrides the row count.
set -euo pipefail
cd "$(dirname "$0")/.."

export DABBI_LARGE_ROWS="${DABBI_LARGE_ROWS:-1000000}"
export DABBI_FIXTURES="$PWD/Fixtures"
export DABBI_PERF=1

if ! grep -q "\"Event\" : $DABBI_LARGE_ROWS" Fixtures/large/manifest.json 2>/dev/null; then
    swift run -c release FixtureGen --output Fixtures --only large
fi

if [[ "${1:-engine}" == "app" ]]; then
    # The tests read these from the environment the test runner gives them, which strips the prefix.
    export TEST_RUNNER_DABBI_PERF=1 TEST_RUNNER_DABBI_FIXTURES="$DABBI_FIXTURES"
    export TEST_RUNNER_DABBI_LARGE_ROWS="$DABBI_LARGE_ROWS"
    # Every app test runs: xcodebuild's -only-testing does not filter a Swift Testing suite. They take seconds.
    # Testability is what @testable needs; the hardened runtime validates the libraries a process loads, and a
    # test bundle is one. Neither belongs in a shipping build, which is why they are asked for here and not in
    # Release.xcconfig. What is being measured — the optimised build — is unaffected.
    exec Scripts/app.sh test Release ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO
fi

# The filter is a regex over test names, so it takes every suite whose name ends this way. Serially: these
# suites measure the same disk, and two of them at once would be measuring the contention.
swift test -c release -Xswiftc -enable-testing --no-parallel --filter "PerformanceTests" "$@"
