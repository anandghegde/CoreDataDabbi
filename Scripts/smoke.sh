#!/bin/bash
# The M0 exit check: `dabbi describe` and `dabbi query` must load every fixture headlessly.
#
#   Scripts/smoke.sh [fixtures-dir]        (default: Fixtures/, generated on demand)
#
# Core Data stores must describe, and every entity must return exactly the row count the manifest promises.
# The foreign fixtures (plain SQLite, encrypted) must fail with their specific, explained error.
set -euo pipefail
cd "$(dirname "$0")/.."

fixtures="${1:-Fixtures}"
swift build --product dabbi >/dev/null
[ -d "$fixtures" ] || swift run FixtureGen --output "$fixtures" >/dev/null
dabbi="$(swift build --show-bin-path)/dabbi"

failures=0
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }

for manifest in "$fixtures"/*/manifest.json; do
  dir="$(dirname "$manifest")"
  name="$(plutil -extract fixture raw "$manifest")"
  kind="$(plutil -extract kind raw "$manifest")"
  store="$dir/$(plutil -extract store raw "$manifest")"
  model=()
  if relative="$(plutil -extract model raw "$manifest" 2>/dev/null)"; then model=(--model "$dir/$relative"); fi

  case "$kind" in
    coreDataStore)
      if ! "$dabbi" describe "$store" ${model[@]+"${model[@]}"} >/dev/null; then fail "$name: describe"; continue; fi
      "$dabbi" describe "$store" ${model[@]+"${model[@]}"} --json | plutil -convert xml1 -o /dev/null - \
        || fail "$name: describe --json is not valid JSON"
      for entity in $(plutil -extract entityCounts raw "$manifest"); do
        expected="$(plutil -extract "entityCounts.$entity" raw "$manifest")"
        actual="$("$dabbi" query "$store" "$entity" ${model[@]+"${model[@]}"} --limit 5 --json \
          | plutil -extract matching raw - 2>/dev/null || echo "error")"
        [ "$actual" = "$expected" ] || fail "$name: $entity has $actual rows, expected $expected"
      done
      echo "ok    $name"
      ;;
    plainSQLite | notSQLite)
      code="sqlite.notCoreData"
      [ "$kind" = notSQLite ] && code="sqlite.notSQLite"
      if output="$("$dabbi" describe "$store" 2>&1)"; then
        fail "$name: describe succeeded on a file that is not a Core Data store"
      elif [[ "$output" != *"[$code]"* ]]; then
        fail "$name: expected error $code, got: $output"
      else
        echo "ok    $name (refused with $code)"
      fi
      ;;
  esac
done

# A store whose model cache is gone must say so, and say what to do about it.
for name in merged noModelCache; do
  manifest="$fixtures/$name/manifest.json"
  store="$fixtures/$name/$(plutil -extract store raw "$manifest")"
  output="$("$dabbi" describe "$store" 2>&1)" && fail "$name: opened without a model"
  [[ "$output" == *"[model.cacheMissing]"* ]] || fail "$name: expected model.cacheMissing without --model"
done

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed"; exit 1; }
echo "All fixtures load."
