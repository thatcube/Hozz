#!/usr/bin/env bash
# Builds and runs the Hozz Mac app.
#
# Signing is injected here rather than committed, so the repository stays free
# of team identifiers. This exists mainly so nothing has to be configured in
# Xcode: project.yml generates the project *and* the entitlements, so anything
# set in the IDE is erased the next time the project is regenerated.
set -euo pipefail

TEAM="${HOZZ_TEAM:-N8Z5T4AK3X}"
DERIVED="${HOZZ_MAC_DERIVED:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Recreate the local signing settings if this is a fresh clone or worktree.
# Gitignored on purpose: no team identifier belongs in a public repository.
if [ ! -f Local.xcconfig ]; then
  cat > Local.xcconfig <<CFG
// Local signing settings, recreated by tools/mac-build.sh when missing.
DEVELOPMENT_TEAM = $TEAM
CFG
  echo "Created Local.xcconfig for team $TEAM."
fi

xcodegen generate >/dev/null

ARGS=(
  -project Hozz.xcodeproj
  -scheme HozzMac
  -configuration Debug
  -destination "platform=macOS"
  # Registers this Mac as a development device on first run, and refreshes the
  # profile when an entitlement changes. Without these, adding a capability
  # fails with a profile error that reads like a signing problem.
  -allowProvisioningUpdates
  -allowProvisioningDeviceRegistration
  "DEVELOPMENT_TEAM=$TEAM"
  CODE_SIGN_STYLE=Automatic
)
if [ -n "$DERIVED" ]; then
  ARGS+=(-derivedDataPath "$DERIVED")
fi

xcodebuild "${ARGS[@]}" build "$@"

APP="$(xcodebuild "${ARGS[@]}" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/Hozz.app"

echo "Built $APP"
# Relaunching replaces a copy that is already running, because the old one
# holds the port. That is disruptive in the middle of testing — it drops a
# phone that has just connected — so it is opt-in rather than automatic.
if [ "${HOZZ_MAC_RUN:-0}" = "1" ]; then
  for pid in $(pgrep -f "Hozz.app/Contents/MacOS/Hozz" || true); do
    kill "$pid" 2>/dev/null || true
  done
  sleep 1
  open "$APP"
  echo "Launched."
elif pgrep -f "Hozz.app/Contents/MacOS/Hozz" >/dev/null 2>&1; then
  echo "Built. A copy is already running and was left alone;"
  echo "run with HOZZ_MAC_RUN=1 to replace it."
else
  open "$APP"
  echo "Launched."
fi
