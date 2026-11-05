#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
out="$root/zig-out/package"
app="$out/actuon.app"
cd "$root"
zig build -Doptimize=ReleaseSafe -Dupdate-key="${ACTUON_UPDATE_KEY:-}"
rm -rf "$out"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
cp zig-out/bin/actuon "$app/Contents/MacOS/actuon"
cp packaging/macos/Info.plist "$app/Contents/Info.plist"
dylibbundler -od -b -x "$app/Contents/MacOS/actuon" -d "$app/Contents/Frameworks" -p @executable_path/../Frameworks/
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --deep --options runtime --timestamp --entitlements packaging/macos/entitlements.plist --sign "$CODESIGN_IDENTITY" "$app"
fi
# The game updates itself from this zip; --norsrc keeps AppleDouble files out of the bundle.
ditto -c -k --norsrc --keepParent "$app" "$out/actuon-macos.zip"
hdiutil create -volname actuon -srcfolder "$app" -ov -format UDZO "$out/actuon.dmg"
if [ -n "${CODESIGN_IDENTITY:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$out/actuon.dmg"
    xcrun notarytool submit "$out/actuon.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$out/actuon.dmg"
fi
