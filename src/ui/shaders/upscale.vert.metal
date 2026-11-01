#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 gl_Position [[position]];
};

vertex main0_out main0(uint gl_VertexIndex [[vertex_id]])
{
    main0_out out = {};
    out.gl_Position = float4((float((int(gl_VertexIndex) << 1) & 2) * 2.0) - 1.0, 1.0 - (float(int(gl_VertexIndex) & 2) * 2.0), 0.0, 1.0);
    return out;
}

