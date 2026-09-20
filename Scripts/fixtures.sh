#!/bin/bash
# Generates the fixture zoo into Fixtures/ (git-ignored). Extra arguments go to FixtureGen, e.g. --only basic.
set -euo pipefail
cd "$(dirname "$0")/.."

swift run -c release FixtureGen --output Fixtures "$@"
