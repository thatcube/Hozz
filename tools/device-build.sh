#!/usr/bin/env bash
# Builds and installs Hozz on the maintainer's iPhone.
#
# Nothing about signing or capabilities is injected here any more. The team
# lives in a gitignored Local.xcconfig, and the entitlements are declared in
# project.yml, so both survive `xcodegen generate` — setting them in Xcode does
# not, because that file generates the project and the entitlements with it.
set -euo pipefail

DEVICE="${HOZZ_DEVICE:-CACB5C41-FBA6-5DE8-9868-98BBDF897991}"
TEAM="${HOZZ_TEAM:-N8Z5T4AK3X}"
DERIVED="${HOZZ_DERIVED:-/tmp/hozz-dd}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Recreate the local signing settings if this is a fresh clone or worktree.
if [ ! -f Local.xcconfig ]; then
  cat > Local.xcconfig <<CFG
// Local signing settings. Gitignored on purpose: no team identifier belongs in
// a public repository. Recreated by tools/device-build.sh when missing.
DEVELOPMENT_TEAM = $TEAM
CFG
  echo "Created Local.xcconfig for team $TEAM."
fi

xcodegen generate >/dev/null

DEVELOPER_DIR=/Applications/Xcode.app xcodebuild \
  -project Hozz.xcodeproj -scheme Hozz -configuration Debug \
  -destination "platform=iOS,id=$DEVICE" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  build "$@"

APP="$DERIVED/Build/Products/Debug-iphoneos/Hozz.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "Installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
