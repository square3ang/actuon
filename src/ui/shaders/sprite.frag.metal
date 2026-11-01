#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 m_9 [[color(0)]];
};

struct main0_in
{
    float2 m_12 [[user(locn0)]];
    float4 m_26 [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> _31 [[texture(0)]], sampler _35 [[sampler(1)]])
{
    main0_out out = {};
    float4 _44;
    if (in.m_12.x < 0.0)
    {
        _44 = in.m_26;
    }
    else
    {
        _44 = _31.sample(_35, in.m_12) * in.m_26;
    }
    out.m_9 = _44;
    return out;
}

