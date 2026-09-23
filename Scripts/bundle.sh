#!/bin/bash
# Builds Usher.app. SwiftPM makes a bare executable; a menubar app needs
# a bundle with LSUIElement so it stays out of the Dock and the app switcher.
#
#   ./Scripts/bundle.sh            # release build for this Mac
#   UNIVERSAL=1 ./Scripts/bundle.sh   # arm64 + x86_64, as shipped
#
# Signing: with a "Developer ID Application" certificate in the keychain the
# app is signed with it and the hardened runtime — one identity across builds,
# so keychain "Always Allow" holds and a notarized release is possible. Set
# SIGN_IDENTITY to choose a certificate, or SIGN_IDENTITY=- for ad-hoc.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Usher.app"
cd "$ROOT"

# Version from the latest tag (v0.2.0 -> 0.2.0), build number from history, so
# what Finder shows is always something git can point at.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

if [ "${UNIVERSAL:-0}" = "1" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BINARY="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Usher"
else
    swift build -c release
    BINARY="$(swift build -c release --show-bin-path)/Usher"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Usher"

# App icon. Regenerate with: swift Scripts/make-icon.swift <out.iconset>
if [ -f "$ROOT/Resources/Usher.icns" ]; then
    cp "$ROOT/Resources/Usher.icns" "$APP/Contents/Resources/Usher.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Usher</string>
    <key>CFBundleDisplayName</key>     <string>Usher</string>
    <key>CFBundleIdentifier</key>      <string>com.sriinnu.usher</string>
    <key>CFBundleExecutable</key>      <string>Usher</string>
    <key>CFBundleIconFile</key>        <string>Usher</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <!-- Menubar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>             <true/>
    <!-- Lets you drop files onto the app in Finder, or onto a Dock alias, and have
         them classified without opening the menubar panel. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>     <string>Any file</string>
            <key>CFBundleTypeRole</key>     <string>Viewer</string>
            <key>LSHandlerRank</key>        <string>None</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.item</string>
            </array>
        </dict>
    </array>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Watches your Desktop for newly downloaded files so it can file them.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Watches your Downloads folder for newly downloaded files so it can file them.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Moves classified files into your Documents folders.</string>
</dict>
</plist>
PLIST

# Pick the identity: explicit, else the first Developer ID Application
# certificate, else ad-hoc. The certificate's name is not printed.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"

if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP"
    echo "signed: ad-hoc (keychain prompts will repeat after each build)"
else
    # Hardened runtime: no injected libraries inheriting Usher's keychain
    # grants. Secure timestamp: required for notarization.
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    codesign --verify --strict "$APP"
    echo "signed: Developer ID, hardened runtime"
fi

echo "built $APP  ($VERSION, build $BUILD, $(lipo -archs "$APP/Contents/MacOS/Usher"))"
