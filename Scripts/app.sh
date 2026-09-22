#!/bin/bash
# Builds or tests the Mac app from the command line, the way CI does.
#
#   Scripts/app.sh build [Debug|Release]
#   Scripts/app.sh test [Debug|Release] [xcodebuild settings…]
#   Scripts/app.sh path            prints where the built app is
#   Scripts/app.sh strings [--check]   fills the String Catalog from the build, or checks it is filled
#
# Derived data goes under .build/xcode (git-ignored with the rest of .build), or wherever DABBI_DERIVED_DATA says.
# Anything the tests should read from the environment is passed as TEST_RUNNER_<NAME>: the test runner strips
# the prefix. `Scripts/perf.sh app` uses that for the performance run.
set -euo pipefail
cd "$(dirname "$0")/.."

derived="${DABBI_DERIVED_DATA:-$PWD/.build/xcode}"
common=(-project App/CoreDataDabbi.xcodeproj -scheme CoreDataDabbi -derivedDataPath "$derived")

case "${1:-build}" in
  build)
    xcodebuild "${common[@]}" -quiet -configuration "${2:-Debug}" build
    ;;
  test)
    config="${2:-Debug}"
    # Anything after the configuration goes to xcodebuild as it is: the performance run asks a Release build
    # for testability, which @testable needs and a shipping build has no business having.
    shift
    if [[ $# -gt 0 ]]; then shift; fi
    # Not quiet: a failing test is only named in the full output.
    xcodebuild "${common[@]}" -configuration "$config" "$@" test
    ;;
  path)
    echo "$derived/Build/Products/${2:-Debug}/CoreDataDabbi.app"
    ;;
  strings)
    # Every user-visible string belongs in the String Catalog (§11, Definition of Done). Xcode does this on
    # each build from the IDE; from the command line the extraction is a step of its own, so CI runs it with
    # --check and fails a change that added a string without adding it here.
    catalog="App/CoreDataDabbi/Resources/Localizable.xcstrings"
    before="$(cat "$catalog")"
    xcodebuild "${common[@]}" -quiet -configuration Debug build
    objects="$derived/Build/Intermediates.noindex/CoreDataDabbi.build/Debug/CoreDataDabbi.build/Objects-normal"
    data=()
    while IFS= read -r file; do data+=("$file"); done < <(find "$objects" -name '*.stringsdata' | sort)
    if [[ ${#data[@]} -eq 0 ]]; then
      echo "no .stringsdata: the app did not build" >&2
      exit 1
    fi
    xcrun xcstringstool sync "$catalog" --stringsdata "${data[@]}"
    if [[ "${2:-}" == "--check" && "$before" != "$(cat "$catalog")" ]]; then
      echo "$catalog is out of date: run Scripts/app.sh strings and commit the result" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: Scripts/app.sh build [Debug|Release] | test [Debug|Release] | path | strings [--check]" >&2
    exit 64
    ;;
esac
