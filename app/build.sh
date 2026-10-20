#!/bin/sh
set -eu
cd "$(dirname "$0")"
# Safari skips an ad-hoc signed web extension, so a build for trying it in Safari needs IDENTITY, such as "Apple Development".
identity="${IDENTITY:--}"
app=build/OpenSpatial.app
version="$(tr -d '[:space:]' < ../version.txt)"
# The rooms the app carries come from room/export.py, which downloads the measurements on first run.
if [ ! -f brir/cr1_ring.f16 ] || [ ! -f brir/free_ring.f16 ]; then
    uv run ../room/export.py cr1 free
fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" -c "Add :CFBundleVersion string $version" "$app/Contents/Info.plist"
cp -R en.lproj "$app/Contents/Resources/"
cp brir/cr1.json brir/cr1_ring.f16 brir/free.json brir/free_ring.f16 MenuBarIcon.svg "$app/Contents/Resources/"
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
# Safari finds the web extension in the app once the app has run; the extension's icon is the app's.
extension="$app/Contents/PlugIns/Safari.appex"
mkdir -p "$extension/Contents/MacOS"
cp ../safari/Info.plist "$extension/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" -c "Add :CFBundleVersion string $version" "$extension/Contents/Info.plist"
cp -R ../safari/Resources "$extension/Contents/"
sips -s format png -Z 512 "$app/Contents/Resources/AppIcon.icns" --out "$extension/Contents/Resources/icon.png" >/dev/null
xcrun swiftc -O -parse-as-library -application-extension -target arm64-apple-macos15.0 ../safari/*.swift \
  -Xlinker -e -Xlinker _NSExtensionMain -o "$extension/Contents/MacOS/Safari"
codesign --force --sign "$identity" --entitlements ../safari/Extension.entitlements "$extension"
codesign --force --sign "$identity" "$app"
echo "$app"
