#!/bin/bash
# Engine targets must stay UI-free (ARCHITECTURE.md §3.1). Fails when a UI framework is imported under Sources/.
set -euo pipefail
cd "$(dirname "$0")/.."

if grep -rnE '^\s*(@_exported\s+)?import\s+(AppKit|SwiftUI|UIKit|Cocoa)\b' Sources; then
    echo "error: engine targets must not import UI frameworks" >&2
    exit 1
fi
echo "layering OK"
