#!/bin/bash
# Runs the corruption suite (PRD §10 Reliability) at length, in a release build: the randomised edit-and-commit
# fuzzing over every fixture, then the soak, an editing session committing against another writer for hours.
# The normal suite runs a few seeds and a few seconds of each.
#
#   Scripts/soak.sh                          50 seeds of 400 steps each, then 180 minutes of soak
#   DABBI_SOAK_MINUTES=20 Scripts/soak.sh    a shorter soak
#   DABBI_FUZZ_SEEDS=500 Scripts/soak.sh     more seeds (DABBI_FUZZ_STEPS sets their length)
#   DABBI_FUZZ_SEED=17 DABBI_FUZZ_TRACE=1 Scripts/soak.sh --filter CorruptionFuzzTests
#                                            one seed again, with its steps (never a value) on standard error
#
# Every store checked must pass SQLite's integrity_check and re-open through Core Data with the rows it should
# hold. A failure names its seed and what was found.
set -euo pipefail
cd "$(dirname "$0")/.."

export DABBI_SOAK=1

if [[ $# -gt 0 ]]; then
    exec swift test -c release -Xswiftc -enable-testing --no-parallel "$@"
fi
# Serially: the soak times its commits, and the fuzzing beside it would be measuring the contention.
swift test -c release -Xswiftc -enable-testing --no-parallel --filter "CorruptionFuzzTests|SoakTests"
