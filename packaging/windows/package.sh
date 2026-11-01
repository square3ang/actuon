#!/bin/sh
# Builds zig-out/actuon-windows.zip from an MSYS2 UCRT64 shell with zig 0.17 and the libraries from README.md.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
zig build -Doptimize=ReleaseSafe
dir=zig-out/actuon-windows
rm -rf "$dir"
mkdir -p "$dir"
cp zig-out/bin/actuon.exe LICENSE "$dir/"
ldd zig-out/bin/actuon.exe | awk '$3 ~ /ucrt64/ { print $3 }' | sort -u | xargs -I{} cp {} "$dir/"
(cd zig-out && zip -r actuon-windows.zip actuon-windows)
