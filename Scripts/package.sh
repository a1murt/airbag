#!/bin/bash
# Release packaging: universal build → sign → (notarize + staple) → zip + dmg + sha256.
#
#   Scripts/package.sh                         # ad-hoc signed, not notarized (local testing)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=airbag-notary Scripts/package.sh
#
# NOTARY_PROFILE is a keychain profile created once with:
#   xcrun notarytool store-credentials airbag-notary --apple-id you@example.com --team-id TEAMID --password <app-specific>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(sed -n 's/.*marketing = "\(.*\)".*/\1/p' Sources/AirbagCore/Support/Version.swift)"
OUT=build
ARCHS="${ARCHS:-arm64 x86_64}" Scripts/build-app.sh
APP="$OUT/Airbag.app"
ZIP="$OUT/Airbag-$VERSION.zip"
DMG="$OUT/Airbag-$VERSION.dmg"
rm -f "$ZIP" "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    [ "${SIGN_IDENTITY:--}" != "-" ] || { echo "notarization needs SIGN_IDENTITY (Developer ID Application)"; exit 1; }
    echo "==> notarize app"
    ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
    xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$OUT/notarize.zip"
fi

echo "==> zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Airbag $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"
if [ "${SIGN_IDENTITY:--}" != "-" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

echo "==> checksums"
( cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" | tee "Airbag-$VERSION.sha256" )
if [ "${SIGN_IDENTITY:--}" != "-" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    spctl --assess --type execute --verbose "$APP"
else
    echo "note: ad-hoc build — Gatekeeper will reject it on other Macs; use for local testing only"
fi
