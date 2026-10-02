#!/bin/sh
set -eu
cd "$(dirname "$0")"
app=build/OpenSpatial.app
version="$(tr -d '[:space:]' < ../version.txt)"
# The room's response tables come from room/export.py, which downloads the measurements on first run.
[ -f brir/cr1_ring.f32 ] || uv run ../room/export.py
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" -c "Add :CFBundleVersion string $version" "$app/Contents/Info.plist"
cp -R en.lproj "$app/Contents/Resources/"
cp brir/cr1.json brir/cr1_ring.f32 MenuBarIcon.svg "$app/Contents/Resources/"
# The app installs the driver it carries on first launch.
[ -d ../driver/OpenSpatial.driver ] || ../driver/build.sh
cp -R ../driver/OpenSpatial.driver "$app/Contents/Resources/"
# Needs Xcode 26 or later: actool turns the Icon Composer file into Assets.car for the Liquid Glass icon
# and AppIcon.icns for earlier macOS. It rejects a relative path to the .icon document.
xcrun actool "$PWD/AppIcon.icon" --compile "$app/Contents/Resources" \
  --app-icon AppIcon --platform macosx --target-device mac --minimum-deployment-target 15.0 \
  --enable-on-demand-resources NO --output-partial-info-plist build/AppIcon.plist \
  --errors --warnings >/dev/null
xcrun swiftc -O -parse-as-library -target arm64-apple-macos15.0 ./*.swift -o "$app/Contents/MacOS/OpenSpatial"
codesign --force --sign - "$app"
echo "$app"
