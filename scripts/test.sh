#!/bin/bash
# Runs the test suite. Extra arguments are passed to `swift test`.
#
# With only the Command Line Tools selected, SwiftPM does not put the Testing framework on the search path:
# `swift test` then fails to compile ("no such module 'Testing'") or builds and runs zero tests. This wrapper
# adds the framework path in that case. With full Xcode it is exactly `swift test`.
# The developer directory is $DEVELOPER_DIR when set, otherwise `xcode-select -p`.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

developer_dir="${DEVELOPER_DIR:-}"
if [[ -z "$developer_dir" ]]; then
  developer_dir="$(xcode-select -p 2>/dev/null || true)"
fi
developer_dir="${developer_dir%/}"
extra=()
if [[ "$developer_dir" == "/Library/Developer/CommandLineTools" ]]; then
  frameworks="$developer_dir/Library/Developer/Frameworks"
  if [[ -d "$frameworks/Testing.framework" ]]; then
    extra+=(-Xswiftc -F"$frameworks" -Xlinker -F"$frameworks" -Xlinker -rpath -Xlinker "$frameworks"
            -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib")
    # The test runner loads Testing and its interop library at run time too.
    export DYLD_FRAMEWORK_PATH="$frameworks"
    export DYLD_LIBRARY_PATH="$developer_dir/Library/Developer/usr/lib"
  fi
fi

output="$(swift test ${extra[@]+"${extra[@]}"} "$@" 2>&1)" && status=0 || status=$?
printf '%s\n' "$output"
if [[ $status -eq 0 ]] && ! grep -q "tests in .* suites passed\|Test run with .* passed" <<<"$output"; then
  echo "error: the build succeeded but no tests ran" >&2
  exit 1
fi
exit $status
