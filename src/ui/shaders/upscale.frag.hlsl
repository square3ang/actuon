Texture2D<float4> _23 : register(t1);
SamplerState _27 : register(s2);
Texture2D<float4> _33 : register(t0);

static float4 gl_FragCoord;
static float4 _57;

struct SPIRV_Cross_Input
{
    float4 gl_FragCoord : SV_Position;
};

struct SPIRV_Cross_Output
{
    float4 _57 : SV_Target0;
};

uint2 spvTextureSize(Texture2D<float4> Tex, uint Level, out uint Param)
{
    uint2 ret;
    Tex.GetDimensions(Level, ret.x, ret.y, Param);
    return ret;
}

void frag_main()
{
    uint _36_dummy_parameter;
    float3 _40 = _23.Sample(_27, gl_FragCoord.xy / float2(int2(spvTextureSize(_33, uint(0), _36_dummy_parameter)))).xyz;
    _57 = float4(clamp(_40 + (_33.Load(int3(int2(gl_FragCoord.xy), 0)).x - dot(_40, float3(0.2125999927520751953125f, 0.715200006961822509765625f, 0.072200000286102294921875f))).xxx, 0.0f.xxx, 1.0f.xxx), 1.0f);
}

SPIRV_Cross_Output main(SPIRV_Cross_Input stage_input)
{
    gl_FragCoord = stage_input.gl_FragCoord;
    gl_FragCoord.w = 1.0 / gl_FragCoord.w;
    frag_main();
    SPIRV_Cross_Output stage_output;
    stage_output._57 = _57;
    return stage_output;
}
