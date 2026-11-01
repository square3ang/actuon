#!/bin/sh
# Regenerates every checked-in shader from its GLSL, so building needs no shader tools.
# Needs glslc and spirv-cross.
set -e
cd "$(dirname "$0")"
for f in *.glsl; do
    s=${f%.glsl}
    glslc -fshader-stage="${s##*.}" -I../../../third_party/ffx -O -o "$s.spv" "$f"
    spirv-cross "$s.spv" --hlsl --shader-model 50 --output "$s.hlsl"
    spirv-cross "$s.spv" --msl --msl-version 20000 --msl-decoration-binding --output "$s.metal"
done
