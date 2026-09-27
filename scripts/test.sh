#!/bin/bash
# Runs the test suite on a machine without Xcode (CLT only).
#
# XCTest is unavailable in the CLT, so tests use swift-testing, which ships in
# the CLT but isn't on the default search path. Two workarounds:
#   1. -F so the compiler finds Testing.framework, and -rpath so the test
#      binary finds it at runtime.
#   2. The CLT ships the `_Testing_Foundation` cross-import overlay as a binary
#      without a swiftmodule, so `import Foundation` + `import Testing` fails.
#      We copy Testing.framework into .build/ and strip its swiftcrossimport
#      descriptor — the overlay is then never requested (tests don't use it).
set -euo pipefail
cd "$(dirname "$0")/.."

# With a full Xcode (CI runners, most dev machines) none of the CLT
# workarounds are needed — swift-testing is wired up automatically.
if xcode-select -p | grep -q "Xcode.app"; then
    exec swift test "$@"
fi

CLT_FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LOCAL_FW=.build/test-frameworks

if [ ! -d "$LOCAL_FW/Testing.framework" ]; then
    mkdir -p "$LOCAL_FW"
    cp -R "$CLT_FW/Testing.framework" "$LOCAL_FW/"
    rm -rf "$LOCAL_FW/Testing.framework/Versions/A/Modules/Testing.swiftcrossimport"
fi

swift test \
    -Xswiftc -F -Xswiftc "$(pwd)/$LOCAL_FW" \
    -Xlinker -rpath -Xlinker "$CLT_FW" \
    "$@"
