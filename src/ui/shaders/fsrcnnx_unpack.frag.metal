#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 m_45 [[color(0)]];
};

fragment main0_out main0(texture2d<float> _22 [[texture(0)]], float4 gl_FragCoord [[position]])
{
    main0_out out = {};
    int2 _17 = int2(gl_FragCoord.xy);
    out.m_45 = float4(fast::clamp(_22.read(uint2((_17 / int2(2))), 0)[((_17.x & 1) * 2) + (_17.y & 1)], 0.0, 1.0), 0.0, 0.0, 1.0);
    return out;
}

