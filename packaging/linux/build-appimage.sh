#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
appdir=$(mktemp -d)/AppDir
cd "$root"
zig build -Doptimize=ReleaseSafe -Dupdate-key="${ACTUON_UPDATE_KEY:-}" --prefix "$appdir/usr"
install -Dm644 packaging/linux/io.github.square3ang.actuon.desktop "$appdir/usr/share/applications/io.github.square3ang.actuon.desktop"
install -Dm644 packaging/linux/io.github.square3ang.actuon.svg "$appdir/usr/share/icons/hicolor/scalable/apps/io.github.square3ang.actuon.svg"
install -Dm644 LICENSE "$appdir/usr/share/licenses/actuon/LICENSE"
# linuxdeploy's bundled strip cannot read .relr.dyn, and its patchelf 0.15 breaks libleancrypto (ld.so crash).
PATCHELF=$(command -v patchelf) NO_STRIP=1 linuxdeploy --appdir "$appdir" --output appimage
# Catches a bundled library that crashes the loader before release.
APPIMAGE_EXTRACT_AND_RUN=1 ./actuon-x86_64.AppImage --version >/dev/null
