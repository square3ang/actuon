#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _32
{
    float4 _m0;
};

struct main0_out
{
    float2 m_9 [[user(locn0)]];
    float4 m_15 [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float2 m_27 [[attribute(0)]];
    float2 m_11 [[attribute(1)]];
    float4 m_17 [[attribute(2)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _32& _34 [[buffer(0)]])
{
    main0_out out = {};
    out.m_9 = in.m_11;
    out.m_15 = in.m_17;
    out.gl_Position = float4(((in.m_27.x / _34._m0.x) * 2.0) - 1.0, 1.0 - ((in.m_27.y / _34._m0.y) * 2.0), 0.0, 1.0);
    return out;
}

