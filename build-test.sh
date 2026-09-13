#//  build-test.sh
#//  ScreenSwap
#//
#//  Created by NG on 13/9/26.
#//
TEST_FW="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/Library/Frameworks"

echo "$TEST_FW"

test -d "$TEST_FW/Testing.framework" && echo "Testing.framework found"
swift build
swift test \
  -Xswiftc -F \
  -Xswiftc "$TEST_FW" \
  -Xlinker -F \
  -Xlinker "$TEST_FW"
