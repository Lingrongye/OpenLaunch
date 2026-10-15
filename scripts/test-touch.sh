#!/bin/zsh
set -eu
cd "${0:A:h:h}"
touch_test_binary=$(mktemp -t openlaunch-touch-regression)
trap 'rm -f "$touch_test_binary"' EXIT
clang -Wall -Wextra -I Sources/CTouch/include Tests/CTouchTests/coalescing.c -framework CoreFoundation -o "$touch_test_binary"
"$touch_test_binary"

clang -Wall -Wextra -I Sources/CTouch/include Tests/CTouchTests/capture.c -framework CoreFoundation -o "$touch_test_binary"
"$touch_test_binary"
