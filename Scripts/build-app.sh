#!/bin/bash
# Assemble Airbag.app from SwiftPM products using Command Line Tools only.
#
#   Scripts/build-app.sh                  # release, host arch, ad-hoc signed → build/Airbag.app
#   ARCHS="arm64 x86_64" Scripts/build-app.sh   # universal binaries via --triple + lipo
#   SIGN_IDENTITY="Developer ID Application: …" Scripts/build-app.sh   # hardened runtime + timestamp
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${CONFIG:-release}"
ARCHS="${ARCHS:-$(uname -m)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
OUT="${OUT:-$ROOT/build}"
APP="$OUT/Airbag.app"
BUNDLE_ID="dev.airbag.Airbag"
MIN_MACOS="14.0"

VERSION="$(sed -n 's/.*marketing = "\(.*\)".*/\1/p' Sources/AirbagCore/Support/Version.swift)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

bin_paths=()
for arch in $ARCHS; do
    triple="${arch}-apple-macosx${MIN_MACOS}"
    log "swift build -c $CONFIG --triple $triple"
    swift build -c "$CONFIG" --triple "$triple" --product airbag
    swift build -c "$CONFIG" --triple "$triple" --product AirbagApp
    bin_paths+=("$(swift build -c "$CONFIG" --triple "$triple" --show-bin-path)")
done

log "assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

lipo_or_copy() { # $1 = product name in bin dir, $2 = destination
    local inputs=()
    for p in "${bin_paths[@]}"; do inputs+=("$p/$1"); done
    if [ "${#inputs[@]}" -gt 1 ]; then lipo -create "${inputs[@]}" -output "$2"; else cp "${inputs[0]}" "$2"; fi
}
lipo_or_copy AirbagApp "$APP/Contents/MacOS/Airbag"
lipo_or_copy airbag "$APP/Contents/Helpers/airbag"

cp -R Sources/AirbagApp/Resources/*.lproj "$APP/Contents/Resources/"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>Airbag</string>
    <key>CFBundleExecutable</key><string>Airbag</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
    <key>CFBundleName</key><string>Airbag</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

log "codesign (identity: $SIGN_IDENTITY)"
sign_args=(--force --options runtime --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then sign_args+=(--timestamp); fi
codesign "${sign_args[@]}" --identifier "${BUNDLE_ID}.cli" "$APP/Contents/Helpers/airbag"
codesign "${sign_args[@]}" "$APP"
codesign --verify --strict --deep "$APP"

log "done: $APP ($VERSION build $BUILD_NUMBER, archs: $(lipo -archs "$APP/Contents/MacOS/Airbag"))"
