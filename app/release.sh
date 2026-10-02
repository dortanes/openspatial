#!/bin/sh
# Signs the app build.sh built, with its driver, notarizes it, packs it into a disk image and notarizes that:
# build/release/OpenSpatial-<version>-macos-arm64.dmg, both with their tickets stapled.
# IDENTITY picks the Developer ID Application identity, by name or by hash when the keychain holds it twice.
# NOTARY_ARGS are notarytool's credentials, by default a profile stored with
# `xcrun notarytool store-credentials openspatial`.
set -eu
cd "$(dirname "$0")"
identity="${IDENTITY:-Developer ID Application}"
notary_args="${NOTARY_ARGS:---keychain-profile openspatial}"
version="$(tr -d '[:space:]' < ../version.txt)"
out=build/release
image="$out/image"
app="$image/OpenSpatial.app"
dmg="$out/OpenSpatial-$version-macos-arm64.dmg"
rm -rf "$out"
mkdir -p "$image"
ditto build/OpenSpatial.app "$app"
# Inside out: the driver the app installs first, then the app around it.
codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/Resources/OpenSpatial.driver"
codesign --force --options runtime --timestamp --entitlements OpenSpatial.entitlements --sign "$identity" "$app"
codesign --verify --deep --strict "$app"

notarize() {
	# shellcheck disable=SC2086 # notary_args holds several arguments.
	xcrun notarytool submit "$1" $notary_args --wait
}

# The app carries its own ticket, so a copy taken out of the disk image opens offline too.
zip="$out/OpenSpatial.zip"
ditto -c -k --keepParent "$app" "$zip"
notarize "$zip"
rm "$zip"
xcrun stapler staple "$app"
ln -s /Applications "$image/Applications"
hdiutil create -volname OpenSpatial -srcfolder "$image" -fs HFS+ -format UDZO -ov "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
echo "$dmg"
