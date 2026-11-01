Texture2D<float4> _22 : register(t0);

static float4 gl_FragCoord;
static float4 _45;

struct SPIRV_Cross_Input
{
    float4 gl_FragCoord : SV_Position;
};

struct SPIRV_Cross_Output
{
    float4 _45 : SV_Target0;
};

void frag_main()
{
    int2 _17 = int2(gl_FragCoord.xy);
    _45 = float4(clamp(_22.Load(int3(_17 / int2(2, 2), 0))[((_17.x & 1) * 2) + (_17.y & 1)], 0.0f, 1.0f), 0.0f, 0.0f, 1.0f);
}

SPIRV_Cross_Output main(SPIRV_Cross_Input stage_input)
{
    gl_FragCoord = stage_input.gl_FragCoord;
    gl_FragCoord.w = 1.0 / gl_FragCoord.w;
    frag_main();
    SPIRV_Cross_Output stage_output;
    stage_output._45 = _45;
    return stage_output;
}
