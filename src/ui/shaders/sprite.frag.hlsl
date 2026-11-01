Texture2D<float4> _31 : register(t0);
SamplerState _35 : register(s1);

static float4 _9;
static float2 _12;
static float4 _26;

struct SPIRV_Cross_Input
{
    float2 _12 : TEXCOORD0;
    float4 _26 : TEXCOORD1;
};

struct SPIRV_Cross_Output
{
    float4 _9 : SV_Target0;
};

void frag_main()
{
    float4 _44;
    if (_12.x < 0.0f)
    {
        _44 = _26;
    }
    else
    {
        _44 = _31.Sample(_35, _12) * _26;
    }
    _9 = _44;
}

SPIRV_Cross_Output main(SPIRV_Cross_Input stage_input)
{
    _12 = stage_input._12;
    _26 = stage_input._26;
    frag_main();
    SPIRV_Cross_Output stage_output;
    stage_output._9 = _9;
    return stage_output;
}
