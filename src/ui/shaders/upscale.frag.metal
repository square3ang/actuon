#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 m_57 [[color(0)]];
};

fragment main0_out main0(texture2d<float> _33 [[texture(0)]], texture2d<float> _23 [[texture(1)]], sampler _27 [[sampler(2)]], float4 gl_FragCoord [[position]])
{
    main0_out out = {};
    float3 _40 = _23.sample(_27, (gl_FragCoord.xy / float2(int2(_33.get_width(), _33.get_height())))).xyz;
    out.m_57 = float4(fast::clamp(_40 + float3(_33.read(uint2(int2(gl_FragCoord.xy)), 0).x - dot(_40, float3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875))), float3(0.0), float3(1.0)), 1.0);
    return out;
}

