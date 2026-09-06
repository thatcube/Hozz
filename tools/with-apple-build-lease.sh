#!/usr/bin/env bash
#
# Run one command while holding the host-wide Apple build interlock.
#
# Usage:
#   tools/with-apple-build-lease.sh OWNER -- command ...
#   tools/with-apple-build-lease.sh --exclusive OWNER -- command ...
#
set -euo pipefail

cd "$(dirname "$0")/.."
source tools/lib/apple-build-lease.sh

MODE="shared"
if [[ "${1:-}" == "--exclusive" ]]; then
  MODE="exclusive"
  shift
fi
OWNER="${1:-}"
[[ -n "$OWNER" ]] || { echo "usage: $0 [--exclusive] OWNER -- command ..." >&2; exit 2; }
shift
[[ "${1:-}" == "--" ]] || { echo "usage: $0 [--exclusive] OWNER -- command ..." >&2; exit 2; }
shift
[[ $# -gt 0 ]] || { echo "usage: $0 [--exclusive] OWNER -- command ..." >&2; exit 2; }

acquire_apple_build_lease "$MODE" "$OWNER"
install_apple_build_lease_traps
"$@"
