#!/bin/sh
# Builds the OpenSpatial loopback driver: BlackHole with 8 channels and a speaker layout Wine maps to Windows 7.1.
# Fetches BlackHole v0.7.1 into blackhole/ and applies openspatial.patch on first run.
set -eu
cd "$(dirname "$0")"
if [ ! -d blackhole ]; then
    git clone --quiet --depth 1 --branch v0.7.1 https://github.com/ExistentialAudio/BlackHole blackhole
    git -C blackhole apply ../openspatial.patch
fi
src=blackhole/BlackHole
name=OpenSpatial
bundle_id=io.github.dortanes.openspatial.driver
# The app replaces an installed driver whose build differs from the one it carries; raise it with every driver change.
build=1
# A factory UUID of its own, so the driver loads alongside a stock BlackHole.
factory=6eb80adc-1b64-4210-92f0-8c373371c118
driver=$name.driver
rm -rf "$driver"
mkdir -p "$driver/Contents/MacOS" "$driver/Contents/Resources"
sed -e "s/\${EXECUTABLE_NAME}/$name/" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$bundle_id/" \
    -e "s/\${PRODUCT_NAME}/$name/" \
    -e "s/\$(MARKETING_VERSION)/0.7.1/" \
    -e "s/e395c745-4eea-4d94-bb92-46224221047c/$factory/g" \
    "$src/BlackHole.plist" > "$driver/Contents/Info.plist"
# BlackHole passes the channel count to its name formats even when the names carry no count.
xcrun clang -O2 -arch arm64 -mmacosx-version-min=12.0 -bundle -Wno-deprecated-declarations -Wno-format-extra-args \
    -DkNumber_Of_Channels=8 \
    "-DkDriver_Name=\"$name\"" "-DkDevice_Name=\"$name\"" "-DkManufacturer_Name=\"$name\"" \
    -DkHas_Driver_Name_Format=false "-DkPlugIn_BundleID=\"$bundle_id\"" \
    -DkVolume_Control_Only=true \
    "$src/BlackHole.c" -o "$driver/Contents/MacOS/$name" \
    -framework CoreAudio -framework CoreFoundation -framework Accelerate
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$driver/Contents/Info.plist"
codesign --force --sign - "$driver"
echo "$driver"
