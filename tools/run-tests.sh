#!/usr/bin/env bash
# Regenerates and runs the Hozz XCTest suite under one shared lease.
set -euo pipefail

DESTINATION="${HOZZ_SIM_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
DERIVED="${HOZZ_TEST_DERIVED:-DerivedData-tests}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

source tools/lib/apple-build-lease.sh
acquire_apple_build_shared_lease "hozz/run-tests"
install_apple_build_lease_traps

tools/generate-project.sh >/dev/null
xcodebuild -project Hozz.xcodeproj -scheme Hozz \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  test "$@"
