#!/bin/zsh

set -euo pipefail

TEST_FW="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/Library/Frameworks"

echo "$TEST_FW"

if [[ ! -d "$TEST_FW/Testing.framework" ]]; then
  echo "error: Testing.framework was not found at $TEST_FW" >&2
  exit 1
fi

echo "Testing.framework found"
swift build
echo "Discovered tests:"
DISCOVERED_TESTS="$(swift test list \
  -Xswiftc -F \
  -Xswiftc "$TEST_FW" \
  -Xlinker -F \
  -Xlinker "$TEST_FW")"
echo "$DISCOVERED_TESTS"

TEST_COUNT="$(echo "$DISCOVERED_TESTS" | awk 'NF { count += 1 } END { print count + 0 }')"
if (( TEST_COUNT == 0 )); then
  echo "error: SwiftPM discovered zero tests" >&2
  exit 1
fi

echo "Discovered $TEST_COUNT test(s)."
echo "Running tests:"
swift test \
  -Xswiftc -F \
  -Xswiftc "$TEST_FW" \
  -Xlinker -F \
  -Xlinker "$TEST_FW"
