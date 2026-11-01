cbuffer _32_34 : register(b0)
{
    float4 _34_m0 : packoffset(c0);
};


static float4 gl_Position;
static float2 _9;
static float2 _11;
static float4 _15;
static float4 _17;
static float2 _27;

struct SPIRV_Cross_Input
{
    float2 _27 : TEXCOORD0;
    float2 _11 : TEXCOORD1;
    float4 _17 : TEXCOORD2;
};

struct SPIRV_Cross_Output
{
    float2 _9 : TEXCOORD0;
    float4 _15 : TEXCOORD1;
    float4 gl_Position : SV_Position;
};

void vert_main()
{
    _9 = _11;
    _15 = _17;
    gl_Position = float4(((_27.x / _34_m0.x) * 2.0f) - 1.0f, 1.0f - ((_27.y / _34_m0.y) * 2.0f), 0.0f, 1.0f);
}

SPIRV_Cross_Output main(SPIRV_Cross_Input stage_input)
{
    _11 = stage_input._11;
    _17 = stage_input._17;
    _27 = stage_input._27;
    vert_main();
    SPIRV_Cross_Output stage_output;
    stage_output.gl_Position = gl_Position;
    stage_output._9 = _9;
    stage_output._15 = _15;
    return stage_output;
}
