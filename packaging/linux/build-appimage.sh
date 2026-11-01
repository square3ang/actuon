#!/bin/sh
# Builds actuon-x86_64.AppImage. Needs zig 0.17 and linuxdeploy on PATH, plus the libraries from README.md.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
appdir=$(mktemp -d)/AppDir
cd "$root"
zig build -Doptimize=ReleaseSafe --prefix "$appdir/usr"
install -Dm644 packaging/linux/io.github.square3ang.actuon.desktop "$appdir/usr/share/applications/io.github.square3ang.actuon.desktop"
install -Dm644 packaging/linux/io.github.square3ang.actuon.svg "$appdir/usr/share/icons/hicolor/scalable/apps/io.github.square3ang.actuon.svg"
install -Dm644 LICENSE "$appdir/usr/share/licenses/actuon/LICENSE"
# linuxdeploy's bundled strip cannot read the .relr.dyn sections of current distro libraries.
NO_STRIP=1 linuxdeploy --appdir "$appdir" --output appimage
