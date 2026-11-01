#!/bin/sh
# Builds actuon.app and actuon.dmg. Needs zig 0.17, dylibbundler, and the libraries from README.md (Homebrew).
# Signing and notarization run when these are set:
#   CODESIGN_IDENTITY  e.g. "Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE     a profile stored with `xcrun notarytool store-credentials`
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
out="$root/zig-out/package"
app="$out/actuon.app"
cd "$root"
zig build -Doptimize=ReleaseSafe
rm -rf "$out"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
cp zig-out/bin/actuon "$app/Contents/MacOS/actuon"
cp packaging/macos/Info.plist "$app/Contents/Info.plist"
dylibbundler -od -b -x "$app/Contents/MacOS/actuon" -d "$app/Contents/Frameworks" -p @executable_path/../Frameworks/
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --deep --options runtime --timestamp --entitlements packaging/macos/entitlements.plist --sign "$CODESIGN_IDENTITY" "$app"
fi
hdiutil create -volname actuon -srcfolder "$app" -ov -format UDZO "$out/actuon.dmg"
if [ -n "${CODESIGN_IDENTITY:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$out/actuon.dmg"
    xcrun notarytool submit "$out/actuon.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$out/actuon.dmg"
fi
