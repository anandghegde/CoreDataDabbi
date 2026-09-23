#!/bin/bash
# The end-to-end run (M2-11): build the iOS writer app, boot a simulator, and run the tracker against it.
#
#   Scripts/e2e.sh                 build the writer, pick a device, run the end-to-end suite
#   Scripts/e2e.sh build           just build the writer app
#   Scripts/e2e.sh path            print where the built writer app is
#   Scripts/e2e.sh device          print the UDID of the device that would be used, booting it if need be
#
# The suite in Tests/DabbiKitTests is off unless DABBI_WRITER_APP names a built WriterApp.app, because building
# one needs Xcode and a simulator SDK and `swift test` on its own has neither. This script is what sets it.
#
# DABBI_WRITER_UDID picks the device; without it the newest available iOS simulator is used, or one that is
# already booted. DABBI_DERIVED_DATA moves the build products, as in Scripts/app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

derived="${DABBI_DERIVED_DATA:-$PWD/.build/xcode}"
app="$derived/Build/Products/Debug-iphonesimulator/WriterApp.app"

build() {
  xcodebuild -project App/CoreDataDabbi.xcodeproj -scheme WriterApp \
    -sdk iphonesimulator -configuration Debug -derivedDataPath "$derived" -quiet build
  [[ -d "$app" ]] || { echo "the writer did not build at $app" >&2; exit 1; }
}

# The newest available iOS simulator, unless one is named or one is already booted. `bootstatus -b` boots it if
# it is not booted and waits either way, so what this prints is a device that is ready to be installed into.
device() {
  local udid="${DABBI_WRITER_UDID:-}"
  if [[ -z "$udid" ]]; then
    udid="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
runtimes = sorted((r for r in devices if "iOS" in r), key=lambda r: [int(n) for n in r.split("iOS-")[-1].split("-")])
booted = [d for r in runtimes for d in devices[r] if d["state"] == "Booted"]
newest = [d for d in devices[runtimes[-1]]] if runtimes else []
pick = (booted or newest)
print(pick[0]["udid"] if pick else "")
')"
  fi
  [[ -n "$udid" ]] || { echo "no iOS simulator is available on this machine" >&2; exit 1; }
  xcrun simctl bootstatus "$udid" -b >/dev/null
  echo "$udid"
}

case "${1:-run}" in
  build) build ;;
  path) echo "$app" ;;
  device) device ;;
  run)
    build
    udid="$(device)"
    echo "writer: $app"
    echo "device: $udid"
    # Only this suite: the rest of the engine's tests are run by `swift test` in the ordinary job, and running
    # them again here would double the build for nothing.
    DABBI_WRITER_APP="$app" DABBI_WRITER_UDID="$udid" \
      swift test --filter SimulatorWriterTests
    ;;
  *)
    echo "usage: Scripts/e2e.sh [run|build|path|device]" >&2
    exit 64
    ;;
esac
