#!/usr/bin/env bash
# Regenerates the gitignored Xcode project while holding the host-wide Apple
# build lease. Use this instead of invoking XcodeGen directly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

source tools/lib/apple-build-lease.sh
acquire_apple_build_shared_lease "hozz/generate-project"
install_apple_build_lease_traps

xcodegen generate "$@"
