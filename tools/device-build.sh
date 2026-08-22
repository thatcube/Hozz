#!/usr/bin/env bash
# Builds and installs Hozz on the maintainer's iPhone.
#
# Signing is injected here rather than committed, so the repository stays free
# of team identifiers and provisioning profile names. The injection is always
# reverted, including when the build fails.
set -euo pipefail

DEVICE="${HOZZ_DEVICE:-CACB5C41-FBA6-5DE8-9868-98BBDF897991}"
TEAM="${HOZZ_TEAM:-N8Z5T4AK3X}"
PROFILE="${HOZZ_PROFILE:-Hozz Development}"
DERIVED="${HOZZ_DERIVED:-/tmp/hozz-dd}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

cp project.yml /tmp/hozz-project.yml.orig
restore() {
  cp /tmp/hozz-project.yml.orig project.yml
  rm -f /tmp/hozz-project.yml.orig
  xcodegen generate >/dev/null 2>&1
}
trap restore EXIT

TEAM="$TEAM" PROFILE="$PROFILE" python3 - <<'PY'
import os
team, profile = os.environ["TEAM"], os.environ["PROFILE"]
text = open("project.yml").read()

app_anchor = "        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor"
text = text.replace(app_anchor, app_anchor + f"""
      configs:
        Debug:
          DEVELOPMENT_TEAM: {team}
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: Apple Development
          PROVISIONING_PROFILE_SPECIFIER: {profile}""", 1)

# The widget is signed too, or the app it is embedded in will not build. The
# anchor is the last key of the widget's `base` block, so `configs` lands as a
# sibling of `base` rather than inside it.
widget_anchor = """    info:
      path: Widget/Info.plist"""
text = text.replace(widget_anchor, f"""      configs:
        Debug:
          DEVELOPMENT_TEAM: {team}
          CODE_SIGN_STYLE: Automatic
""" + widget_anchor, 1)

open("project.yml", "w").write(text)
PY

xcodegen generate >/dev/null
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild \
  -project Hozz.xcodeproj -scheme Hozz -configuration Debug \
  -destination "platform=iOS,id=$DEVICE" \
  -derivedDataPath "$DERIVED" build "$@"

APP="$DERIVED/Build/Products/Debug-iphoneos/Hozz.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "Installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
