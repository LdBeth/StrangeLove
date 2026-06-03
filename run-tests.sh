#!/bin/sh
# Runs swift-testing tests under CommandLineTools (no Xcode).
# Plain `swift test` cannot resolve `Testing` here, so build with
# Testing.framework on the search path and invoke the test helper directly
# with DYLD_* set so Testing + lib_TestingInterop resolve at runtime.

set -e

CLT=/Library/Developer/CommandLineTools
F=$CLT/Library/Developer/Frameworks

swift build --build-tests -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F"

DYLD_FRAMEWORK_PATH=$F \
DYLD_LIBRARY_PATH=$CLT/Library/Developer/usr/lib \
  "$CLT/usr/libexec/swift/pm/swiftpm-testing-helper" \
  --test-bundle-path "$(ls -d .build/*/debug/*.xctest/Contents/MacOS/*PackageTests)" \
  --testing-library swift-testing \
  "$@"
