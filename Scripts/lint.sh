#!/bin/bash
# Lints every Swift source with the toolchain's swift-format. Pass --fix to format in place.
set -euo pipefail
cd "$(dirname "$0")/.."

PATHS=(Package.swift Sources Tests Tools)
if [[ "${1:-}" == "--fix" ]]; then
    swift format format --in-place --recursive --parallel "${PATHS[@]}"
else
    swift format lint --strict --recursive --parallel "${PATHS[@]}"
fi
