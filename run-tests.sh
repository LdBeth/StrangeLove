#!/bin/sh
# Runs the swift-testing tests under CommandLineTools (no Xcode).
#
# Plain `swift test` fails here with
#   plugin for module 'TestingMacros' not found
# because the macro plugin ships in a subdirectory of the host plugin dir
# that the compiler does not search by default. Point -plugin-path at it and
# the normal `swift test` path works.

set -e

exec swift test \
  -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  "$@"
